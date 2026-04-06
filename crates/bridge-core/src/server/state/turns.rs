use super::*;

impl BridgeAppState {
    async fn set_workflow_state(&self, thread_id: &str, workflow_state: Option<ThreadWorkflow>) {
        let workflow_state = workflow_state.map(ThreadWorkflow::into_dto);
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-workflow-{}", Utc::now().timestamp_millis()),
            bridge_seq: None,
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::ThreadMetadataChanged,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "workflow_state": workflow_state,
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    async fn current_plan_workflow_prompt(&self, thread_id: &str) -> Option<String> {
        ThreadWorkflow::current_plan_prompt(
            self.projections()
                .snapshot(thread_id)
                .await
                .and_then(|snapshot| snapshot.workflow_state),
        )
    }

    pub(super) async fn restore_pending_user_input_sessions_from_projection(&self) {
        let pending_inputs = self.projections().list_pending_user_inputs().await;

        for (thread_id, pending_user_input) in pending_inputs {
            match pending_user_input.workflow_kind.as_deref() {
                Some("plan_questionnaire") => {
                    self.publish_user_input_resolution_event(
                        &thread_id,
                        &pending_user_input.request_id,
                    )
                    .await;
                    self.set_workflow_state(
                        &thread_id,
                        Some(ThreadWorkflow::expired_plan_questionnaire(
                            pending_user_input
                                .original_prompt
                                .as_deref()
                                .unwrap_or_default(),
                            Some(pending_user_input.request_id.as_str()),
                            pending_user_input.provider_request_id.as_deref(),
                        )),
                    )
                    .await;
                }
                Some("provider_approval") => {
                    self.publish_user_input_resolution_event(
                        &thread_id,
                        &pending_user_input.request_id,
                    )
                    .await;
                    self.set_workflow_state(
                        &thread_id,
                        Some(ThreadWorkflow::expired_provider_approval(
                            &pending_user_input.request_id,
                            pending_user_input.provider_request_id.as_deref(),
                        )),
                    )
                    .await;
                }
                _ => {}
            }
        }
    }

    pub async fn start_turn(
        &self,
        request_id: &str,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        mode: TurnMode,
        client_message_id: Option<&str>,
        client_turn_intent_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let provider = provider_from_thread_id(thread_id).unwrap_or(ProviderKind::Codex);
        if provider == ProviderKind::ClaudeCode && mode == TurnMode::Plan {
            return Err("plan mode is not implemented for Claude Code threads yet".to_string());
        }
        match mode {
            TurnMode::Act => {
                self.clear_pending_user_input(thread_id).await;
                self.start_turn_with_visible_prompt(
                    request_id,
                    thread_id,
                    prompt,
                    prompt,
                    images,
                    model,
                    effort,
                    TurnMode::Act,
                    client_message_id,
                    client_turn_intent_id,
                )
                .await
            }
            TurnMode::Plan => {
                self.start_plan_turn(
                    thread_id,
                    prompt,
                    images,
                    model,
                    effort,
                    client_message_id,
                    client_turn_intent_id,
                )
                .await
            }
        }
    }

    pub async fn start_commit_action(
        &self,
        thread_id: &str,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        if !is_provider_thread_id(thread_id, shared_contracts::ProviderKind::Codex) {
            return Err(format!(
                "thread {thread_id} belongs to a read-only provider; commit actions are only implemented for codex threads"
            ));
        }
        self.start_turn_with_visible_prompt(
            "commit-action",
            thread_id,
            "Commit",
            &build_hidden_commit_prompt(),
            &[],
            model,
            effort,
            TurnMode::Act,
            None,
            None,
        )
        .await
    }

    async fn start_turn_with_visible_prompt(
        &self,
        request_id: &str,
        thread_id: &str,
        visible_prompt: &str,
        upstream_prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        mode: TurnMode,
        client_message_id: Option<&str>,
        client_turn_intent_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let normalized_images = images
            .iter()
            .map(|image| image.trim())
            .filter(|image| !image.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        eprintln!(
            "bridge turn start requested request_id={request_id} thread_id={thread_id} visible_prompt_chars={} upstream_prompt_chars={} images={} model={} effort={}",
            visible_prompt.trim().chars().count(),
            upstream_prompt.chars().count(),
            normalized_images.len(),
            model.unwrap_or("<default>"),
            effort.unwrap_or("<default>")
        );
        self.clear_interrupted_thread_state(thread_id).await;
        if !normalized_images.is_empty() {
            self.update_thread_runtime(thread_id, |runtime| {
                runtime.pending_user_message_images = normalized_images.clone();
            })
            .await;
        }
        let visible_prompt = visible_prompt.trim();
        let synthesizes_visible_prompt =
            should_synthesize_visible_user_prompt(visible_prompt, upstream_prompt);
        let normalized_client_message_id = client_message_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let normalized_client_turn_intent_id = client_turn_intent_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let completion_handle = handle.clone();
        let stream_finish_handle = completion_handle.clone();
        let compactor = Arc::new(std::sync::Mutex::new(LiveDeltaCompactor::default()));
        let completion_state = self.clone();
        let stream_finish_state = self.clone();
        let control_state = self.clone();
        let control_handle = handle.clone();
        let control_thread_id = thread_id.to_string();
        let mut result = match self.inner.gateway.start_turn_streaming(
            thread_id,
            TurnStartRequest {
                request_id: Some(request_id.to_string()),
                prompt: upstream_prompt.to_string(),
                images: images.to_vec(),
                model: model.map(str::to_string),
                effort: effort.map(str::to_string),
                mode,
                permission_mode: Some(claude_permission_mode_for_access_mode(
                    self.access_mode().await,
                )),
                client_turn_intent_id: normalized_client_turn_intent_id.clone(),
            },
            move |event| {
                let mut normalized = compactor
                    .lock()
                    .expect("turn stream compactor lock should not be poisoned")
                    .compact(event);
                if !should_publish_compacted_event(&normalized) {
                    return;
                }
                if should_suppress_live_event(&normalized) {
                    return;
                }
                let state = state.clone();
                handle.block_on(async {
                    state
                        .rewrite_interrupted_thread_status_event(&mut normalized)
                        .await;
                });
                handle.block_on(async move {
                    state
                        .inject_pending_turn_client_message_id(&mut normalized)
                        .await;
                    if normalized.kind != BridgeEventKind::ThreadStatusChanged {
                        state
                            .merge_pending_user_message_images(&mut normalized)
                            .await;
                    }
                    state.projections().apply_live_event(&normalized).await;
                    state.event_hub().publish(normalized);
                });
            },
            move |control_request| {
                let state = control_state.clone();
                let thread_id = control_thread_id.clone();
                control_handle.block_on(async move {
                    state
                        .handle_turn_control_request(&thread_id, control_request)
                        .await
                })
            },
            move |completed_thread_id| {
                let state = completion_state.clone();
                completion_handle.block_on(async move {
                    state.finalize_bridge_owned_turn(&completed_thread_id).await;
                });
            },
            move |finished_thread_id, activity| {
                let state = stream_finish_state.clone();
                stream_finish_handle.block_on(async move {
                    state
                        .refresh_snapshot_after_bridge_turn_completion(
                            &finished_thread_id,
                            activity,
                        )
                        .await;
                });
            },
        ) {
            Ok(result) => result,
            Err(error) => {
                eprintln!(
                    "bridge turn start stream failed request_id={request_id} thread_id={thread_id}: {error}"
                );
                self.clear_transient_thread_state(thread_id).await;
                return Err(error);
            }
        };
        result.response.client_message_id = normalized_client_message_id.clone();
        result.response.client_turn_intent_id = normalized_client_turn_intent_id;
        eprintln!(
            "bridge turn start accepted request_id={request_id} thread_id={thread_id} turn_id={} thread_status={:?}",
            result.response.turn_id.as_deref().unwrap_or("<none>"),
            result.response.thread_status
        );
        if result.turn_id.is_none() {
            self.update_thread_runtime(thread_id, |runtime| {
                runtime.pending_user_message_images.clear();
            })
            .await;
        }
        if let Some(turn_id) = result.turn_id {
            self.update_thread_runtime(thread_id, |runtime| {
                runtime.active_turn_id = Some(turn_id);
            })
            .await;
            self.schedule_bridge_owned_turn_watchdog(thread_id);
        }
        if let Some(client_message_id) = normalized_client_message_id.as_ref() {
            self.update_thread_runtime(thread_id, |runtime| {
                runtime.pending_client_message = Some(PendingTurnClientMessage {
                    client_message_id: client_message_id.clone(),
                    turn_id: result.response.turn_id.clone(),
                    prompt_text: visible_prompt.to_string(),
                });
            })
            .await;
        }
        let occurred_at = Utc::now().to_rfc3339();
        self.projections()
            .mark_thread_running(thread_id, &occurred_at, result.response.turn_id.as_deref())
            .await;
        let turn_started_event = build_turn_started_history_event(
            thread_id,
            &occurred_at,
            result.response.turn_id.as_deref(),
            model,
            effort,
        );
        self.record_bridge_turn_metadata(&turn_started_event).await;
        self.projections()
            .apply_live_event(&turn_started_event)
            .await;
        self.event_hub().publish(turn_started_event);
        if synthesizes_visible_prompt {
            let mut visible_prompt_event = build_visible_user_message_event(
                thread_id,
                &occurred_at,
                result.response.turn_id.as_deref(),
                visible_prompt,
                normalized_client_message_id.as_deref(),
            );
            self.merge_pending_user_message_images(&mut visible_prompt_event)
                .await;
            self.record_bridge_turn_metadata(&visible_prompt_event)
                .await;
            self.projections()
                .apply_live_event(&visible_prompt_event)
                .await;
            self.event_hub().publish(visible_prompt_event);
        }
        if !visible_prompt.is_empty() {
            let workspace = self
                .projections()
                .snapshot(thread_id)
                .await
                .map(|snapshot| snapshot.thread.workspace)
                .unwrap_or_default();
            self.schedule_thread_title_generation_from_prompt(
                thread_id,
                visible_prompt,
                &workspace,
                model,
            )
            .await;
        }
        Ok(result.response)
    }

    async fn start_plan_turn(
        &self,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        client_message_id: Option<&str>,
        client_turn_intent_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        self.clear_pending_user_input(thread_id).await;
        self.ensure_snapshot(thread_id).await?;
        self.set_workflow_state(
            thread_id,
            Some(ThreadWorkflow::plan_awaiting_questions(prompt)),
        )
        .await;
        let result = self
            .start_turn_with_visible_prompt(
                "plan-turn",
                thread_id,
                prompt,
                prompt,
                images,
                model,
                effort,
                TurnMode::Plan,
                client_message_id,
                client_turn_intent_id,
            )
            .await;
        if result.is_err() {
            self.set_workflow_state(thread_id, None).await;
        }
        result
    }

    pub async fn respond_to_user_input(
        &self,
        thread_id: &str,
        request_id: &str,
        answers: &[UserInputAnswerDto],
        free_text: Option<&str>,
        _model: Option<&str>,
        _effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let free_text = free_text.map(str::trim).filter(|value| !value.is_empty());
        if self
            .read_thread_runtime(thread_id, |runtime| {
                runtime.is_some_and(|runtime| runtime.pending_user_input.is_some())
            })
            .await
            == false
        {
            if self
                .projections()
                .snapshot(thread_id)
                .await
                .and_then(|snapshot| snapshot.pending_user_input)
                .is_some_and(|pending| {
                    pending.request_id == request_id
                        && pending.workflow_kind.as_deref() == Some("provider_approval")
                })
            {
                return Err(
                    "This approval request expired when the bridge restarted. Re-run the action if you still want to approve it."
                        .to_string(),
                );
            } else if self
                .projections()
                .snapshot(thread_id)
                .await
                .map(|snapshot| {
                    ThreadWorkflow::is_expired_plan_request(snapshot.workflow_state, request_id)
                })
                .unwrap_or(false)
            {
                return Err(
                    "This plan questionnaire expired when the bridge restarted. Re-run plan mode if you still want Codex to continue with the clarification flow."
                        .to_string(),
                );
            }
        }
        let session = {
            let Some(existing_request_id) = self
                .read_thread_runtime(thread_id, |runtime| {
                    runtime
                        .and_then(|runtime| runtime.pending_user_input.as_ref())
                        .map(|session| match session {
                            PendingUserInputSession::NativeCodexRequestUserInput(session) => {
                                session.questionnaire.request_id.clone()
                            }
                            PendingUserInputSession::ProviderApproval(session) => {
                                session.questionnaire.request_id.clone()
                            }
                        })
                })
                .await
            else {
                return Err("There is no pending user input for this thread.".to_string());
            };
            if existing_request_id != request_id {
                return Err(
                    "The pending question set is no longer current. Refresh and try again."
                        .to_string(),
                );
            }
            self.take_pending_user_input(thread_id)
                .await
                .expect("pending user input should exist after id check")
        };

        match session {
            PendingUserInputSession::NativeCodexRequestUserInput(session) => {
                if answers.is_empty() && free_text.is_none() {
                    self.update_thread_runtime(thread_id, |runtime| {
                        runtime.pending_user_input = Some(
                            PendingUserInputSession::NativeCodexRequestUserInput(session),
                        );
                    })
                    .await;
                    return Err(
                        "Pick at least one answer or write your own clarification.".to_string()
                    );
                }

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
                self.set_workflow_state(thread_id, None).await;
                self.publish_user_input_resolution_event(thread_id, request_id)
                    .await;

                let response = build_codex_request_user_input_response(
                    &session.questionnaire,
                    answers,
                    free_text,
                );
                if session.resolution_tx.send(response).is_err() {
                    return Err("The user-input request is no longer active.".to_string());
                }

                let active_turn_id = self.active_turn_id(thread_id).await;
                Ok(TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.to_string(),
                    thread_status: ThreadStatus::Running,
                    message: "user input submitted".to_string(),
                    turn_id: active_turn_id,
                    client_message_id: None,
                    client_turn_intent_id: None,
                })
            }
            PendingUserInputSession::ProviderApproval(provider_session) => {
                let Some(selection) = parse_provider_approval_selection(answers) else {
                    self.update_thread_runtime(thread_id, |runtime| {
                        runtime.pending_user_input =
                            Some(PendingUserInputSession::ProviderApproval(provider_session));
                    })
                    .await;
                    return Err("Choose Allow once, Allow for session, or Deny.".to_string());
                };

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
                self.set_workflow_state(thread_id, None).await;
                self.publish_user_input_resolution_event(thread_id, request_id)
                    .await;

                let should_interrupt_after_response = matches!(
                    provider_session.context,
                    ProviderApprovalContext::CodexPermissions { .. }
                ) && selection
                    == ProviderApprovalSelection::Deny;
                let interrupt_turn_id = match &provider_session.context {
                    ProviderApprovalContext::CodexPermissions { turn_id, .. } => Some(turn_id),
                    _ => None,
                };

                if provider_session.resolution_tx.send(selection).is_err() {
                    return Err("The provider approval request is no longer active.".to_string());
                }

                if should_interrupt_after_response && let Some(turn_id) = interrupt_turn_id {
                    let _ = self.inner.gateway.interrupt_turn(thread_id, turn_id).await;
                }

                let active_turn_id = self.active_turn_id(thread_id).await;
                Ok(TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.to_string(),
                    thread_status: ThreadStatus::Running,
                    message: "approval response submitted".to_string(),
                    turn_id: active_turn_id,
                    client_message_id: None,
                    client_turn_intent_id: None,
                })
            }
        }
    }

    pub(super) async fn handle_turn_control_request(
        &self,
        thread_id: &str,
        control_request: GatewayTurnControlRequest,
    ) -> Result<Option<Value>, String> {
        match control_request {
            GatewayTurnControlRequest::CodexApproval {
                request_id,
                method,
                params,
            } => {
                let Some(prompt) = build_pending_provider_approval_from_codex(
                    thread_id,
                    &request_id,
                    &method,
                    &params,
                )?
                else {
                    return Ok(None);
                };
                let selection = self
                    .register_provider_approval_session(thread_id, prompt)
                    .await?;
                Ok(Some(build_codex_approval_response(
                    &method, &params, selection,
                )?))
            }
            GatewayTurnControlRequest::CodexRequestUserInput { request_id, params } => {
                let Some(original_prompt) = self.current_plan_workflow_prompt(thread_id).await
                else {
                    return Ok(None);
                };
                let Some(questionnaire) = build_pending_plan_questionnaire_from_codex_request(
                    &request_id,
                    &params,
                    &original_prompt,
                ) else {
                    return Ok(None);
                };
                let response = self
                    .register_native_codex_user_input_session(
                        thread_id,
                        questionnaire,
                        &original_prompt,
                    )
                    .await?;
                Ok(Some(response))
            }
            GatewayTurnControlRequest::ClaudeCanUseTool {
                request_id,
                request,
            } => {
                let request_copy = request.clone();
                let prompt =
                    build_pending_provider_approval_from_claude(thread_id, request_id, request)?;
                let selection = self
                    .register_provider_approval_session(thread_id, prompt)
                    .await?;
                Ok(Some(build_claude_tool_approval_response(
                    selection,
                    &request_copy,
                )))
            }
            GatewayTurnControlRequest::ClaudeControlCancel { request_id } => {
                self.cancel_provider_approval_request(thread_id, &request_id)
                    .await;
                Ok(None)
            }
        }
    }

    pub(super) async fn register_provider_approval_session(
        &self,
        thread_id: &str,
        prompt: ProviderApprovalPrompt,
    ) -> Result<ProviderApprovalSelection, String> {
        let questionnaire = prompt.questionnaire.clone();
        let request_id = questionnaire.request_id.clone();
        let provider_request_id = prompt.provider_request_id.clone();
        let (resolution_tx, resolution_rx) = oneshot::channel();
        let replaced = self
            .update_thread_runtime(thread_id, |runtime| {
                runtime
                    .pending_user_input
                    .replace(PendingUserInputSession::ProviderApproval(
                        PendingProviderApprovalSession {
                            questionnaire: questionnaire.clone(),
                            provider_request_id: prompt.provider_request_id,
                            context: prompt.context,
                            resolution_tx,
                        },
                    ))
            })
            .await;
        if let Some(replaced) = replaced {
            self.try_abort_pending_provider_approval(replaced);
        }
        self.set_workflow_state(
            thread_id,
            Some(ThreadWorkflow::pending_provider_approval(
                &request_id,
                &provider_request_id,
            )),
        )
        .await;
        self.publish_user_input_pending_event(thread_id, &questionnaire)
            .await;
        resolution_rx
            .await
            .map_err(|_| format!("provider approval {request_id} was cancelled before completion"))
    }

    async fn register_native_codex_user_input_session(
        &self,
        thread_id: &str,
        questionnaire: PendingUserInputDto,
        original_prompt: &str,
    ) -> Result<Value, String> {
        let request_id = questionnaire.request_id.clone();
        let provider_request_id = questionnaire.provider_request_id.clone();
        let (resolution_tx, resolution_rx) = oneshot::channel();
        let replaced = self
            .update_thread_runtime(thread_id, |runtime| {
                runtime.pending_user_input.replace(
                    PendingUserInputSession::NativeCodexRequestUserInput(
                        PendingNativeUserInputSession {
                            questionnaire: questionnaire.clone(),
                            resolution_tx,
                        },
                    ),
                )
            })
            .await;
        if let Some(replaced) = replaced {
            self.try_abort_pending_provider_approval(replaced);
        }
        self.set_workflow_state(
            thread_id,
            Some(ThreadWorkflow::plan_awaiting_response(
                original_prompt,
                &request_id,
                provider_request_id.as_deref(),
            )),
        )
        .await;
        self.publish_user_input_pending_event(thread_id, &questionnaire)
            .await;
        resolution_rx
            .await
            .map_err(|_| format!("request_user_input {request_id} was cancelled before completion"))
    }

    async fn cancel_provider_approval_request(&self, thread_id: &str, request_id: &str) {
        let removed = self
            .update_thread_runtime(thread_id, |runtime| {
                let should_remove = runtime.pending_user_input.as_ref().is_some_and(|session| {
                    matches!(
                        session,
                        PendingUserInputSession::ProviderApproval(provider_session)
                            if provider_session.provider_request_id == request_id
                    )
                });
                if should_remove {
                    runtime.pending_user_input.take()
                } else {
                    None
                }
            })
            .await;
        let Some(removed_session) = removed else {
            return;
        };
        let resolved_request_id = match &removed_session {
            PendingUserInputSession::NativeCodexRequestUserInput(session) => {
                session.questionnaire.request_id.clone()
            }
            PendingUserInputSession::ProviderApproval(provider_session) => {
                provider_session.questionnaire.request_id.clone()
            }
        };
        self.try_abort_pending_provider_approval(removed_session);
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
        self.set_workflow_state(thread_id, None).await;
        self.publish_user_input_resolution_event(thread_id, &resolved_request_id)
            .await;
    }

    fn try_abort_pending_provider_approval(&self, session: PendingUserInputSession) {
        match session {
            PendingUserInputSession::ProviderApproval(provider_session) => {
                let _ = provider_session
                    .resolution_tx
                    .send(ProviderApprovalSelection::Deny);
            }
            PendingUserInputSession::NativeCodexRequestUserInput(session) => {
                let _ = session
                    .resolution_tx
                    .send(build_codex_request_user_input_response(
                        &session.questionnaire,
                        &[],
                        None,
                    ));
            }
        }
    }

    async fn clear_pending_user_input(&self, thread_id: &str) {
        let removed = self.take_pending_user_input(thread_id).await;
        if let Some(session) = removed {
            self.try_abort_pending_provider_approval(session);
        }
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
        self.set_workflow_state(thread_id, None).await;
    }

    async fn publish_user_input_resolution_event(&self, thread_id: &str, request_id: &str) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{request_id}-resolved"),
            bridge_seq: None,
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": request_id,
                "state": "resolved",
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    async fn publish_user_input_pending_event(
        &self,
        thread_id: &str,
        pending_user_input: &PendingUserInputDto,
    ) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{}", pending_user_input.request_id),
            bridge_seq: None,
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": pending_user_input.request_id,
                "title": pending_user_input.title,
                "detail": pending_user_input.detail,
                "workflow_kind": pending_user_input.workflow_kind,
                "original_prompt": pending_user_input.original_prompt,
                "provider_request_id": pending_user_input.provider_request_id,
                "questions": pending_user_input.questions,
                "state": "pending",
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    pub(super) async fn merge_pending_user_message_images(
        &self,
        event: &mut BridgeEventEnvelope<Value>,
    ) {
        if event.kind != BridgeEventKind::MessageDelta {
            return;
        }
        if event.payload.get("role").and_then(Value::as_str) != Some("user") {
            return;
        }

        let pending_images = self
            .take_pending_user_message_images(&event.thread_id)
            .await;
        if pending_images.is_empty() {
            return;
        }

        let has_images = event
            .payload
            .get("images")
            .and_then(Value::as_array)
            .is_some_and(|images| !images.is_empty());
        if has_images {
            return;
        }

        if let Some(object) = event.payload.as_object_mut() {
            object.insert(
                "images".to_string(),
                Value::Array(pending_images.into_iter().map(Value::String).collect()),
            );
        }
    }

    pub(super) async fn inject_pending_turn_client_message_id(
        &self,
        event: &mut BridgeEventEnvelope<Value>,
    ) {
        if event.kind != BridgeEventKind::MessageDelta {
            return;
        }
        if event.payload.get("role").and_then(Value::as_str) != Some("user") {
            return;
        }
        if event.payload.get("client_message_id").is_some() {
            self.clear_pending_turn_client_message(&event.thread_id)
                .await;
            return;
        }

        let Some(pending) = self.pending_turn_client_message(&event.thread_id).await else {
            return;
        };

        if let Some(expected_turn_id) = pending.turn_id.as_deref()
            && !event.event_id.starts_with(expected_turn_id)
        {
            return;
        }

        if let Some(object) = event.payload.as_object_mut() {
            object.insert(
                "client_message_id".to_string(),
                Value::String(pending.client_message_id),
            );
        }
        self.clear_pending_turn_client_message(&event.thread_id)
            .await;
    }

    pub(super) async fn has_bridge_owned_active_turn(&self, thread_id: &str) -> bool {
        self.inner
            .gateway
            .thread_lifecycle_state(thread_id)
            .await
            .map(|state| state.stream_active || state.active_turn_id.is_some())
            .unwrap_or(false)
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let resolved_turn_id = if let Some(turn_id) = turn_id {
            turn_id.to_string()
        } else if let Some(turn_id) = self.active_turn_id(thread_id).await {
            turn_id
        } else {
            let turn_id = self.inner.gateway.resolve_active_turn_id(thread_id).await?;
            self.update_thread_runtime(thread_id, |runtime| {
                runtime.active_turn_id = Some(turn_id.clone());
            })
            .await;
            turn_id
        };
        let result = self
            .inner
            .gateway
            .interrupt_turn(thread_id, &resolved_turn_id)
            .await?;
        let occurred_at = Utc::now().to_rfc3339();
        self.mark_thread_interrupt_requested(thread_id).await;
        self.projections()
            .mark_thread_status(thread_id, ThreadStatus::Interrupted, &occurred_at)
            .await;
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.active_turn_id = None;
        })
        .await;
        self.event_hub().publish(BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-status-{occurred_at}"),
            bridge_seq: None,
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at,
            payload: json!({
                "status": "interrupted",
                "reason": "interrupt_requested",
            }),
            annotations: None,
        });
        Ok(result.response)
    }
}
