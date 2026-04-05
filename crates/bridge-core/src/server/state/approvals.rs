use super::*;

impl BridgeAppState {
    pub async fn queue_git_approval(
        &self,
        action: PendingApprovalAction,
        reason: &str,
    ) -> Result<ApprovalGateResponse, String> {
        let thread_id = action.thread_id().to_string();
        let snapshot = self.ensure_snapshot(&thread_id).await?;
        let git_state = read_git_state(&snapshot.thread.workspace, &thread_id)?;
        let occurred_at = Utc::now().to_rfc3339();
        let approval = {
            let mut git_controls = self
                .inner
                .git_controls
                .lock()
                .expect("git controls lock should not be poisoned");
            git_controls.queue_approval(
                action,
                reason,
                git_state.response.repository.clone(),
                git_state.response.status.clone(),
                &occurred_at,
            )
        };

        self.projections()
            .upsert_approval_record(approval.clone())
            .await;
        let event = BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("evt-{}", approval.approval_id),
            bridge_seq: None,
            thread_id: approval.thread_id.clone(),
            kind: BridgeEventKind::ApprovalRequested,
            occurred_at: approval.requested_at.clone(),
            payload: serde_json::to_value(&approval)
                .expect("approval event payload should serialize"),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);

        Ok(ApprovalGateResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            operation: approval.action.clone(),
            outcome: "approval_required".to_string(),
            message: "Dangerous action was gated pending explicit approval".to_string(),
            approval,
        })
    }

    pub async fn resolve_approval(
        &self,
        approval_id: &str,
        approved: bool,
    ) -> Result<ApprovalResolutionResponse, ResolveApprovalError> {
        let occurred_at = Utc::now().to_rfc3339();
        let record = {
            let mut git_controls = self
                .inner
                .git_controls
                .lock()
                .expect("git controls lock should not be poisoned");
            git_controls.resolve_approval(approval_id, approved, &occurred_at)?
        };

        if !approved {
            self.projections()
                .upsert_approval_record(record.approval.clone())
                .await;
            return Ok(ApprovalResolutionResponse {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                approval: record.approval,
                mutation_result: None,
            });
        }

        let result = self
            .execute_pending_approval_action(&record, &occurred_at)
            .await;
        match result {
            Ok(mutation_result) => {
                self.projections()
                    .upsert_approval_record(record.approval.clone())
                    .await;
                Ok(ApprovalResolutionResponse {
                    contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                    approval: record.approval,
                    mutation_result: Some(mutation_result),
                })
            }
            Err(error) => {
                let restored_approval = {
                    let mut git_controls = self
                        .inner
                        .git_controls
                        .lock()
                        .expect("git controls lock should not be poisoned");
                    git_controls.restore_pending(approval_id);
                    git_controls
                        .approvals
                        .get(approval_id)
                        .expect("approval should exist after restore")
                        .approval
                        .clone()
                };
                self.projections()
                    .upsert_approval_record(restored_approval)
                    .await;
                Err(error)
            }
        }
    }

    pub async fn execute_git_branch_switch(
        &self,
        thread_id: &str,
        branch: &str,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_branch_switch(workspace, thread_id, branch, status, occurred_at)
        })
        .await
    }

    pub async fn execute_git_pull(
        &self,
        thread_id: &str,
        remote: Option<&str>,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_pull(workspace, thread_id, remote, status, occurred_at)
        })
        .await
    }

    pub async fn execute_git_push(
        &self,
        thread_id: &str,
        remote: Option<&str>,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_push(workspace, thread_id, remote, status, occurred_at)
        })
        .await
    }

    async fn execute_pending_approval_action(
        &self,
        record: &PendingApprovalRecord,
        occurred_at: &str,
    ) -> Result<MutationResultResponse, ResolveApprovalError> {
        let snapshot = self.projections().snapshot(record.action.thread_id()).await;
        let snapshot = match snapshot {
            Some(snapshot) => snapshot,
            None => self
                .ensure_snapshot(record.action.thread_id())
                .await
                .map_err(|_| ResolveApprovalError::TargetNotFound)?,
        };

        let executed = match &record.action {
            PendingApprovalAction::BranchSwitch { branch, .. } => execute_branch_switch(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                branch,
                snapshot.thread.status,
                occurred_at,
            ),
            PendingApprovalAction::Pull { remote, .. } => execute_pull(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                remote.as_deref(),
                snapshot.thread.status,
                occurred_at,
            ),
            PendingApprovalAction::Push { remote, .. } => execute_push(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                remote.as_deref(),
                snapshot.thread.status,
                occurred_at,
            ),
        }
        .map_err(ResolveApprovalError::MutationFailed)?;

        self.projections()
            .apply_live_event(&executed.command_event)
            .await;
        self.event_hub().publish(executed.command_event);
        self.projections()
            .update_git_state(
                record.action.thread_id(),
                &executed.mutation.repository,
                &executed.mutation.status,
                Some(occurred_at),
                Some(&executed.mutation.message),
            )
            .await;
        Ok(executed.mutation)
    }

    async fn execute_git_operation<F>(
        &self,
        thread_id: &str,
        operation: F,
    ) -> Result<MutationResultResponse, String>
    where
        F: FnOnce(&str, ThreadStatus, &str) -> Result<ExecutedGitMutation, String>,
    {
        let occurred_at = Utc::now().to_rfc3339();
        self.execute_git_operation_with_snapshot(thread_id, &occurred_at, operation)
            .await
    }

    async fn execute_git_operation_with_snapshot<F>(
        &self,
        thread_id: &str,
        occurred_at: &str,
        operation: F,
    ) -> Result<MutationResultResponse, String>
    where
        F: FnOnce(&str, ThreadStatus, &str) -> Result<ExecutedGitMutation, String>,
    {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let executed = operation(
            &snapshot.thread.workspace,
            snapshot.thread.status,
            occurred_at,
        )?;
        self.projections()
            .apply_live_event(&executed.command_event)
            .await;
        self.event_hub().publish(executed.command_event);
        self.projections()
            .update_git_state(
                thread_id,
                &executed.mutation.repository,
                &executed.mutation.status,
                Some(occurred_at),
                Some(&executed.mutation.message),
            )
            .await;
        Ok(executed.mutation)
    }
}
