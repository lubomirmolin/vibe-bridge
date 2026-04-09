use super::*;

impl BridgeAppState {
    pub async fn start_turn(
        &self,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        mode: TurnMode,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let provider = provider_from_thread_id(thread_id).unwrap_or(ProviderKind::Codex);
        if provider == ProviderKind::ClaudeCode && mode == TurnMode::Plan {
            return Err("plan mode is not implemented for Claude Code threads yet".to_string());
        }
        match mode {
            TurnMode::Act => {
                self.clear_pending_user_input(thread_id).await;
                self.start_turn_with_visible_prompt(
                    thread_id, prompt, prompt, images, model, effort,
                )
                .await
            }
            TurnMode::Plan => {
                self.start_plan_turn(thread_id, prompt, images, model, effort)
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
            thread_id,
            "Commit",
            &build_hidden_commit_prompt(),
            &[],
            model,
            effort,
        )
        .await
    }

    async fn start_turn_with_visible_prompt(
        &self,
        thread_id: &str,
        visible_prompt: &str,
        upstream_prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let normalized_images = images
            .iter()
            .map(|image| image.trim())
            .filter(|image| !image.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        self.clear_interrupted_thread_state(thread_id).await;
        if !normalized_images.is_empty() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .insert(thread_id.to_string(), normalized_images.clone());
        }
        let visible_prompt = visible_prompt.trim();
        enum TurnStreamDispatch {
            Event(BridgeEventEnvelope<Value>),
            Control {
                request: GatewayTurnControlRequest,
                reply: mpsc::SyncSender<Result<Option<Value>, String>>,
            },
            Completed(String),
            Finished(String),
        }

        let (dispatch_tx, mut dispatch_rx) = tokio_mpsc::unbounded_channel::<TurnStreamDispatch>();
        let processor_state = self.clone();
        let processor_thread_id = thread_id.to_string();
        tokio::spawn(async move {
            let mut compactor = LiveDeltaCompactor::default();
            while let Some(message) = dispatch_rx.recv().await {
                match message {
                    TurnStreamDispatch::Event(event) => {
                        if let Some(user_input_event) = processor_state
                            .build_pending_user_input_event_from_live_message(&event)
                            .await
                        {
                            processor_state
                                .dispatch_thread_event(RawThreadEvent {
                                    source: RawThreadEventSource::BridgeLocal,
                                    thread_id: user_input_event.thread_id.clone(),
                                    turn_id: None,
                                    item_id: None,
                                    phase: RawThreadEventPhase::UserInput,
                                    event: user_input_event,
                                })
                                .await;
                            continue;
                        }

                        let mut normalized = compactor.compact(event);
                        if !should_publish_compacted_event(&normalized) {
                            continue;
                        }
                        if should_suppress_live_event(&normalized) {
                            continue;
                        }

                        processor_state
                            .rewrite_interrupted_thread_status_event(&mut normalized)
                            .await;
                        if normalized.kind != BridgeEventKind::ThreadStatusChanged {
                            processor_state
                                .merge_pending_user_message_images(&mut normalized)
                                .await;
                        }
                        processor_state
                            .dispatch_thread_event(build_raw_thread_event(
                                RawThreadEventSource::AppServerLive,
                                normalized,
                            ))
                            .await;
                    }
                    TurnStreamDispatch::Control { request, reply } => {
                        let result = processor_state
                            .handle_turn_control_request(&processor_thread_id, request)
                            .await;
                        let _ = reply.send(result);
                    }
                    TurnStreamDispatch::Completed(completed_thread_id) => {
                        processor_state
                            .finalize_bridge_owned_turn(&completed_thread_id)
                            .await;
                    }
                    TurnStreamDispatch::Finished(finished_thread_id) => {
                        processor_state
                            .mark_bridge_turn_stream_finished(&finished_thread_id)
                            .await;
                        processor_state
                            .refresh_snapshot_after_bridge_turn_completion(&finished_thread_id)
                            .await;
                    }
                }
            }
        });
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .insert(thread_id.to_string());
        self.mark_outgoing_turn_phase(thread_id, OutgoingTurnPhase::Queued, None, None)
            .await;
        self.mark_bridge_turn_stream_started(thread_id).await;
        let event_dispatch_tx = dispatch_tx.clone();
        let control_dispatch_tx = dispatch_tx.clone();
        let completed_dispatch_tx = dispatch_tx.clone();
        let finished_dispatch_tx = dispatch_tx.clone();
        let result = match self.inner.gateway.start_turn_streaming(
            thread_id,
            TurnStartRequest {
                prompt: upstream_prompt.to_string(),
                images: images.to_vec(),
                model: model.map(str::to_string),
                effort: effort.map(str::to_string),
                permission_mode: Some(claude_permission_mode_for_access_mode(
                    self.access_mode().await,
                )),
            },
            {
                move |event| {
                    let _ = event_dispatch_tx.send(TurnStreamDispatch::Event(event));
                }
            },
            move |control_request| {
                let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                let _ = control_dispatch_tx.send(TurnStreamDispatch::Control {
                    request: control_request,
                    reply: reply_tx,
                });
                reply_rx
                    .recv()
                    .unwrap_or_else(|error| Err(format!("turn control processor failed: {error}")))
            },
            {
                move |completed_thread_id| {
                    let _ = completed_dispatch_tx
                        .send(TurnStreamDispatch::Completed(completed_thread_id));
                }
            },
            move |finished_thread_id| {
                let _ = finished_dispatch_tx.send(TurnStreamDispatch::Finished(finished_thread_id));
            },
        ) {
            Ok(result) => result,
            Err(error) => {
                self.mark_bridge_turn_stream_finished(thread_id).await;
                self.clear_transient_thread_state(thread_id).await;
                self.mark_outgoing_turn_phase(
                    thread_id,
                    OutgoingTurnPhase::Failed,
                    None,
                    Some("turn_start_failed".to_string()),
                )
                .await;
                return Err(error);
            }
        };
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .remove(thread_id);
        if result.turn_id.is_none() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .remove(thread_id);
        }
        if let Some(turn_id) = result.turn_id {
            self.inner
                .active_turn_ids
                .write()
                .await
                .insert(thread_id.to_string(), turn_id);
            self.mark_outgoing_turn_phase(
                thread_id,
                OutgoingTurnPhase::TurnStartAcked,
                result.response.turn_id.clone(),
                None,
            )
            .await;
            self.schedule_bridge_owned_turn_watchdog(thread_id);
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
        self.dispatch_thread_event(build_raw_thread_event(
            RawThreadEventSource::BridgeLocal,
            turn_started_event,
        ))
        .await;
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
    ) -> Result<TurnMutationAcceptedDto, String> {
        self.clear_pending_user_input(thread_id).await;
        self.inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .insert(thread_id.to_string(), prompt.trim().to_string());
        self.start_turn_with_visible_prompt(
            thread_id,
            prompt,
            &build_hidden_plan_question_prompt(prompt),
            images,
            model,
            effort,
        )
        .await
    }

    pub async fn respond_to_user_input(
        &self,
        thread_id: &str,
        request_id: &str,
        answers: &[UserInputAnswerDto],
        free_text: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let free_text = free_text.map(str::trim).filter(|value| !value.is_empty());
        let session = {
            let mut pending = self.inner.pending_user_inputs.write().await;
            let Some(existing_request_id) = pending.get(thread_id).map(|session| match session {
                PendingUserInputSession::PlanQuestionnaire { questionnaire, .. } => {
                    questionnaire.request_id.as_str()
                }
                PendingUserInputSession::ProviderApproval(session) => {
                    session.questionnaire.request_id.as_str()
                }
            }) else {
                return Err("There is no pending user input for this thread.".to_string());
            };
            if existing_request_id != request_id {
                return Err(
                    "The pending question set is no longer current. Refresh and try again."
                        .to_string(),
                );
            }
            pending
                .remove(thread_id)
                .expect("pending user input should exist after id check")
        };

        match session {
            PendingUserInputSession::PlanQuestionnaire {
                questionnaire,
                original_prompt,
            } => {
                if answers.is_empty() && free_text.is_none() {
                    self.inner.pending_user_inputs.write().await.insert(
                        thread_id.to_string(),
                        PendingUserInputSession::PlanQuestionnaire {
                            questionnaire,
                            original_prompt,
                        },
                    );
                    return Err(
                        "Pick at least one answer or write your own clarification.".to_string()
                    );
                }

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
                self.publish_user_input_resolution_event(thread_id, request_id)
                    .await;

                self.start_turn_with_visible_prompt(
                    thread_id,
                    &render_user_input_response_summary(&questionnaire, answers, free_text),
                    &build_hidden_plan_followup_prompt(
                        &original_prompt,
                        &questionnaire,
                        answers,
                        free_text,
                    ),
                    &[],
                    model,
                    effort,
                )
                .await
            }
            PendingUserInputSession::ProviderApproval(provider_session) => {
                let Some(selection) = parse_provider_approval_selection(answers) else {
                    self.inner.pending_user_inputs.write().await.insert(
                        thread_id.to_string(),
                        PendingUserInputSession::ProviderApproval(provider_session),
                    );
                    return Err("Choose Allow once, Allow for session, or Deny.".to_string());
                };

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
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

                let active_turn_id = self
                    .inner
                    .active_turn_ids
                    .read()
                    .await
                    .get(thread_id)
                    .cloned();
                Ok(TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.to_string(),
                    thread_status: ThreadStatus::Running,
                    message: "approval response submitted".to_string(),
                    turn_id: active_turn_id,
                })
            }
        }
    }

    async fn handle_turn_control_request(
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

    async fn register_provider_approval_session(
        &self,
        thread_id: &str,
        prompt: ProviderApprovalPrompt,
    ) -> Result<ProviderApprovalSelection, String> {
        let questionnaire = prompt.questionnaire.clone();
        let request_id = questionnaire.request_id.clone();
        let (resolution_tx, resolution_rx) = oneshot::channel();
        {
            let mut pending = self.inner.pending_user_inputs.write().await;
            if let Some(replaced) = pending.insert(
                thread_id.to_string(),
                PendingUserInputSession::ProviderApproval(PendingProviderApprovalSession {
                    questionnaire: questionnaire.clone(),
                    provider_request_id: prompt.provider_request_id,
                    context: prompt.context,
                    resolution_tx,
                }),
            ) {
                self.try_abort_pending_provider_approval(replaced);
            }
        }
        self.publish_user_input_pending_event(thread_id, &questionnaire)
            .await;
        resolution_rx
            .await
            .map_err(|_| format!("provider approval {request_id} was cancelled before completion"))
    }

    async fn cancel_provider_approval_request(&self, thread_id: &str, request_id: &str) {
        let removed = {
            let mut pending = self.inner.pending_user_inputs.write().await;
            let should_remove = pending.get(thread_id).is_some_and(|session| {
                matches!(
                    session,
                    PendingUserInputSession::ProviderApproval(provider_session)
                        if provider_session.provider_request_id == request_id
                )
            });
            if should_remove {
                pending.remove(thread_id)
            } else {
                None
            }
        };
        let Some(removed_session) = removed else {
            return;
        };
        let resolved_request_id = match &removed_session {
            PendingUserInputSession::ProviderApproval(provider_session) => {
                provider_session.questionnaire.request_id.clone()
            }
            PendingUserInputSession::PlanQuestionnaire { questionnaire, .. } => {
                questionnaire.request_id.clone()
            }
        };
        self.try_abort_pending_provider_approval(removed_session);
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
        self.publish_user_input_resolution_event(thread_id, &resolved_request_id)
            .await;
    }

    fn try_abort_pending_provider_approval(&self, session: PendingUserInputSession) {
        if let PendingUserInputSession::ProviderApproval(provider_session) = session {
            let _ = provider_session
                .resolution_tx
                .send(ProviderApprovalSelection::Deny);
        }
    }

    async fn clear_pending_user_input(&self, thread_id: &str) {
        self.inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .remove(thread_id);
        let removed = self
            .inner
            .pending_user_inputs
            .write()
            .await
            .remove(thread_id);
        if let Some(session) = removed {
            self.try_abort_pending_provider_approval(session);
        }
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
    }

    async fn build_pending_user_input_event_from_live_message(
        &self,
        event: &BridgeEventEnvelope<Value>,
    ) -> Option<BridgeEventEnvelope<Value>> {
        if event.kind != BridgeEventKind::MessageDelta {
            return None;
        }
        if event.payload.get("role").and_then(Value::as_str) != Some("assistant") {
            return None;
        }

        let original_prompt = self
            .inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .remove(&event.thread_id)?;
        let message_text = extract_text_from_payload(&event.payload)?;
        let questionnaire = parse_pending_user_input_payload(&message_text, &event.thread_id)?;
        let request_id = questionnaire.request_id.clone();

        if let Some(replaced) = self.inner.pending_user_inputs.write().await.insert(
            event.thread_id.clone(),
            PendingUserInputSession::PlanQuestionnaire {
                questionnaire: questionnaire.clone(),
                original_prompt,
            },
        ) {
            self.try_abort_pending_provider_approval(replaced);
        }

        Some(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{}-{}", event.thread_id, request_id),
            thread_id: event.thread_id.clone(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: event.occurred_at.clone(),
            payload: json!({
                "request_id": questionnaire.request_id,
                "title": questionnaire.title,
                "detail": questionnaire.detail,
                "questions": questionnaire.questions,
                "state": "pending",
            }),
            annotations: None,
            bridge_seq: None,
        })
    }

    async fn publish_user_input_resolution_event(&self, thread_id: &str, request_id: &str) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{request_id}-resolved"),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": request_id,
                "state": "resolved",
            }),
            annotations: None,
            bridge_seq: None,
        };
        self.dispatch_thread_event(build_raw_thread_event(
            RawThreadEventSource::BridgeLocal,
            event,
        ))
        .await;
    }

    async fn publish_user_input_pending_event(
        &self,
        thread_id: &str,
        pending_user_input: &PendingUserInputDto,
    ) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{}", pending_user_input.request_id),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": pending_user_input.request_id,
                "title": pending_user_input.title,
                "detail": pending_user_input.detail,
                "questions": pending_user_input.questions,
                "state": "pending",
            }),
            annotations: None,
            bridge_seq: None,
        };
        self.dispatch_thread_event(build_raw_thread_event(
            RawThreadEventSource::BridgeLocal,
            event,
        ))
        .await;
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

        let Some(pending_images) = self
            .inner
            .pending_user_message_images
            .write()
            .await
            .remove(&event.thread_id)
        else {
            return;
        };

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

    pub(super) async fn has_bridge_owned_active_turn(&self, thread_id: &str) -> bool {
        if self
            .inner
            .active_turn_ids
            .read()
            .await
            .contains_key(thread_id)
        {
            return true;
        }

        self.inner
            .pending_bridge_owned_turns
            .read()
            .await
            .contains(thread_id)
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let resolved_turn_id = if let Some(turn_id) = turn_id {
            turn_id.to_string()
        } else if let Some(turn_id) = self
            .inner
            .active_turn_ids
            .read()
            .await
            .get(thread_id)
            .cloned()
        {
            turn_id
        } else {
            let turn_id = self.inner.gateway.resolve_active_turn_id(thread_id).await?;
            self.inner
                .active_turn_ids
                .write()
                .await
                .insert(thread_id.to_string(), turn_id.clone());
            turn_id
        };
        let result = self
            .inner
            .gateway
            .interrupt_turn(thread_id, &resolved_turn_id)
            .await?;
        let occurred_at = Utc::now().to_rfc3339();
        self.mark_thread_interrupt_requested(thread_id).await;
        self.inner.active_turn_ids.write().await.remove(thread_id);
        self.dispatch_thread_event(build_raw_thread_event(
            RawThreadEventSource::BridgeLocal,
            BridgeEventEnvelope {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                event_id: format!("{thread_id}-status-{occurred_at}"),
                thread_id: thread_id.to_string(),
                kind: BridgeEventKind::ThreadStatusChanged,
                occurred_at,
                payload: json!({
                    "status": "interrupted",
                    "reason": "interrupt_requested",
                }),
                annotations: None,
                bridge_seq: None,
            },
        ))
        .await;
        Ok(result.response)
    }
}
