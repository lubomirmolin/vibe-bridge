use super::*;

impl BridgeAppState {
    pub async fn ensure_snapshot(&self, thread_id: &str) -> Result<ThreadSnapshotDto, String> {
        if let Some(snapshot) = self.projections().snapshot(thread_id).await {
            self.apply_local_placeholder_thread_title_fallback(thread_id)
                .await;
            self.request_notification_thread_resume(thread_id).await;
            return Ok(self
                .projections()
                .snapshot(thread_id)
                .await
                .unwrap_or(snapshot));
        }

        let mut snapshot = self.inner.gateway.fetch_thread_snapshot(thread_id).await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        self.projections().put_snapshot(snapshot.clone()).await;
        self.apply_local_placeholder_thread_title_fallback(thread_id)
            .await;
        self.request_notification_thread_resume(thread_id).await;
        Ok(self
            .projections()
            .snapshot(thread_id)
            .await
            .unwrap_or(snapshot))
    }

    pub async fn list_thread_summaries(&self) -> Vec<ThreadSummaryDto> {
        let summaries = self.projections().list_summaries().await;
        let placeholder_thread_ids = summaries
            .iter()
            .filter(|summary| is_placeholder_thread_title(&summary.title))
            .map(|summary| summary.thread_id.clone())
            .collect::<Vec<_>>();
        if placeholder_thread_ids.is_empty() {
            return summaries;
        }

        let mut backfilled_any = false;
        for thread_id in placeholder_thread_ids {
            if self
                .apply_local_placeholder_thread_title_fallback(&thread_id)
                .await
                .is_some()
            {
                backfilled_any = true;
            }
        }

        if backfilled_any {
            return self.projections().list_summaries().await;
        }

        summaries
    }

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        let mut snapshot = self
            .inner
            .gateway
            .create_thread(provider, workspace, model)
            .await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        let mut summaries = self.projections().list_summaries().await;
        let next_summary = thread_summary_from_snapshot(&snapshot);
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot.clone()).await;
        self.projections().replace_summaries(summaries).await;
        Ok(snapshot)
    }

    pub async fn timeline_page(
        &self,
        thread_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<ThreadTimelinePageDto, String> {
        if self.projections().snapshot(thread_id).await.is_none() {
            self.ensure_snapshot(thread_id).await?;
        }

        let mut page = self
            .projections()
            .timeline_page(thread_id, before, limit)
            .await
            .ok_or_else(|| format!("thread {thread_id} not found"))?;
        page.thread.access_mode = self.access_mode().await;
        Ok(page)
    }

    pub async fn git_status(&self, thread_id: &str) -> Result<GitStatusResponse, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let git_state = read_git_state_for_status(&snapshot.thread.workspace, thread_id)?;
        self.projections()
            .update_git_state(
                thread_id,
                &git_state.response.repository,
                &git_state.response.status,
                None,
                None,
            )
            .await;
        Ok(git_state.response)
    }

    pub async fn git_diff(
        &self,
        thread_id: &str,
        mode: ThreadGitDiffMode,
        path: Option<&str>,
    ) -> Result<ThreadGitDiffDto, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let repository = match mode {
            ThreadGitDiffMode::Workspace => read_git_state(&snapshot.thread.workspace, thread_id)
                .map(|state| state.snapshot_status)?,
            ThreadGitDiffMode::LatestThreadChange => {
                snapshot.git_status.clone().unwrap_or(SharedGitStatusDto {
                    workspace: snapshot.thread.workspace.clone(),
                    repository: snapshot.thread.repository.clone(),
                    branch: snapshot.thread.branch.clone(),
                    remote: None,
                    dirty: false,
                    ahead_by: 0,
                    behind_by: 0,
                })
            }
        };
        let (unified_diff, revision) = match mode {
            ThreadGitDiffMode::Workspace => {
                resolve_workspace_diff(&snapshot.thread.workspace, path)?
            }
            ThreadGitDiffMode::LatestThreadChange => (
                resolve_latest_thread_change_diff(&snapshot.entries, path),
                None,
            ),
        };

        Ok(ThreadGitDiffDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: snapshot.thread,
            repository,
            mode,
            revision,
            files: parse_git_diff_file_summaries(&unified_diff),
            unified_diff,
            fetched_at: Utc::now().to_rfc3339(),
        })
    }

    pub async fn thread_usage(&self, thread_id: &str) -> Result<ThreadUsageDto, CodexUsageError> {
        let snapshot = self
            .ensure_snapshot(thread_id)
            .await
            .map_err(CodexUsageError::UpstreamUnavailable)?;

        if snapshot.thread.provider != ProviderKind::Codex {
            return Err(CodexUsageError::AuthUnavailable(
                "Usage bars are only available for Codex threads.".to_string(),
            ));
        }

        let usage = self
            .inner
            .codex_usage_client
            .read()
            .await
            .fetch_usage()
            .await?;
        Ok(ThreadUsageDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: snapshot.thread.thread_id,
            provider: ProviderKind::Codex,
            plan_type: usage.plan_type,
            primary_window: usage.primary_window,
            secondary_window: usage.secondary_window,
        })
    }

    pub(super) async fn set_codex_health(&self, health: ServiceHealthDto) {
        *self.inner.codex_health.write().await = health;
    }

    pub(super) async fn set_available_models(&self, models: Vec<ModelOptionDto>) {
        *self.inner.available_models.write().await = models;
    }

    fn upsert_timeline_entry_preserving_order(
        entries: &mut Vec<ThreadTimelineEntryDto>,
        next_entry: ThreadTimelineEntryDto,
    ) {
        if let Some(index) = entries
            .iter()
            .position(|existing| existing.event_id == next_entry.event_id)
        {
            entries.remove(index);
        }

        let insert_index = entries
            .iter()
            .rposition(|existing| existing.occurred_at <= next_entry.occurred_at)
            .map_or(0, |index| index + 1);
        entries.insert(insert_index, next_entry);
    }

    pub(super) async fn record_bridge_turn_metadata(&self, event: &BridgeEventEnvelope<Value>) {
        let mut metadata_by_thread = self.inner.bridge_turn_metadata.write().await;
        let entries = metadata_by_thread
            .entry(event.thread_id.clone())
            .or_insert_with(Vec::new);
        let next_entry = ThreadTimelineEntryDto {
            event_id: event.event_id.clone(),
            kind: event.kind,
            occurred_at: event.occurred_at.clone(),
            summary: String::new(),
            payload: event.payload.clone(),
            annotations: event.annotations.clone(),
        };
        Self::upsert_timeline_entry_preserving_order(entries, next_entry);
    }

    pub(super) async fn merge_bridge_turn_metadata(&self, snapshot: &mut ThreadSnapshotDto) {
        let metadata_entries = self
            .inner
            .bridge_turn_metadata
            .read()
            .await
            .get(&snapshot.thread.thread_id)
            .cloned()
            .unwrap_or_default();
        if metadata_entries.is_empty() {
            return;
        }

        for metadata_entry in metadata_entries {
            if snapshot
                .entries
                .iter()
                .any(|existing| existing.event_id == metadata_entry.event_id)
            {
                continue;
            }
            Self::upsert_timeline_entry_preserving_order(&mut snapshot.entries, metadata_entry);
        }
    }

    pub(super) async fn apply_external_snapshot_update(
        &self,
        mut snapshot: ThreadSnapshotDto,
        events: Vec<BridgeEventEnvelope<Value>>,
    ) {
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        if let Some(previous_snapshot) = self
            .projections()
            .snapshot(&snapshot.thread.thread_id)
            .await
        {
            preserve_generated_thread_title(&previous_snapshot, &mut snapshot);
        }
        let next_summary = thread_summary_from_snapshot(&snapshot);
        let mut summaries = self.projections().list_summaries().await;
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot).await;
        self.projections().replace_summaries(summaries).await;

        for event in events {
            if should_clear_transient_thread_state(&event) {
                self.clear_transient_thread_state(&event.thread_id).await;
            }
            self.event_hub().publish(event);
        }
    }
}
