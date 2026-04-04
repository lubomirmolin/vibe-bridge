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
        eprintln!(
            "bridge turn start requested thread_id={thread_id} visible_prompt_chars={} upstream_prompt_chars={} images={} model={} effort={}",
            visible_prompt.trim().chars().count(),
            upstream_prompt.chars().count(),
            normalized_images.len(),
            model.unwrap_or("<default>"),
            effort.unwrap_or("<default>")
        );
        self.clear_interrupted_thread_state(thread_id).await;
        if !normalized_images.is_empty() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .insert(thread_id.to_string(), normalized_images.clone());
        }
        let visible_prompt = visible_prompt.trim();
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
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .insert(thread_id.to_string());
        self.mark_bridge_turn_stream_started(thread_id).await;
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
            move |event| {
                let state = state.clone();
                if let Some(user_input_event) = handle.block_on(async {
                    state
                        .build_pending_user_input_event_from_live_message(&event)
                        .await
                }) {
                    let state = state.clone();
                    handle.block_on(async move {
                        state
                            .projections()
                            .apply_live_event(&user_input_event)
                            .await;
                        state.event_hub().publish(user_input_event);
                    });
                    return;
                }
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
                    if should_clear_transient_thread_state(&normalized) {
                        state
                            .clear_transient_thread_state(&normalized.thread_id)
                            .await;
                    }
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
            move |finished_thread_id| {
                let state = stream_finish_state.clone();
                stream_finish_handle.block_on(async move {
                    state
                        .mark_bridge_turn_stream_finished(&finished_thread_id)
                        .await;
                    state
                        .refresh_snapshot_after_bridge_turn_completion(&finished_thread_id)
                        .await;
                });
            },
        ) {
            Ok(result) => result,
            Err(error) => {
                eprintln!("bridge turn start stream failed thread_id={thread_id}: {error}");
                self.mark_bridge_turn_stream_finished(thread_id).await;
                self.clear_transient_thread_state(thread_id).await;
                return Err(error);
            }
        };
        eprintln!(
            "bridge turn start accepted thread_id={thread_id} turn_id={} thread_status={:?}",
            result.response.turn_id.as_deref().unwrap_or("<none>"),
            result.response.thread_status
        );
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
        self.projections()
            .apply_live_event(&turn_started_event)
            .await;
        self.event_hub().publish(turn_started_event);
        if should_synthesize_visible_user_prompt(visible_prompt, upstream_prompt) {
            let mut visible_prompt_event = build_visible_user_message_event(
                thread_id,
                &occurred_at,
                result.response.turn_id.as_deref(),
                visible_prompt,
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
        if self
            .inner
            .pending_user_inputs
            .read()
            .await
            .get(thread_id)
            .is_none()
            && let Some(reconstructed) = self
                .reconstruct_plan_questionnaire_from_snapshot(thread_id, request_id)
                .await
        {
            self.inner
                .pending_user_inputs
                .write()
                .await
                .insert(thread_id.to_string(), reconstructed);
        }
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

    pub(super) async fn reconstruct_plan_questionnaire_from_snapshot(
        &self,
        thread_id: &str,
        request_id: &str,
    ) -> Option<PendingUserInputSession> {
        let snapshot = match self.projections().snapshot(thread_id).await {
            Some(snapshot) => snapshot,
            None => self.ensure_snapshot(thread_id).await.ok()?,
        };
        let questionnaire = snapshot.pending_user_input?;
        if questionnaire.request_id != request_id
            || looks_like_provider_approval_questionnaire(&questionnaire)
        {
            return None;
        }

        let original_prompt = snapshot
            .entries
            .iter()
            .rev()
            .filter(|entry| entry.kind == BridgeEventKind::MessageDelta)
            .filter(|entry| entry.payload.get("role").and_then(Value::as_str) == Some("user"))
            .filter_map(|entry| extract_text_from_payload(&entry.payload))
            .find(|text| !is_hidden_message(text))?;

        Some(PendingUserInputSession::PlanQuestionnaire {
            questionnaire,
            original_prompt,
        })
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
        self.projections()
            .mark_thread_status(thread_id, ThreadStatus::Interrupted, &occurred_at)
            .await;
        self.inner.active_turn_ids.write().await.remove(thread_id);
        self.event_hub().publish(BridgeEventEnvelope {
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
        });
        Ok(result.response)
    }
}
