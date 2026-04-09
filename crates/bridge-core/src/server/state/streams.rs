use super::*;

impl BridgeAppState {
    pub(super) async fn request_notification_thread_resume(&self, thread_id: &str) {
        let normalized_thread_id = thread_id.trim();
        if normalized_thread_id.is_empty()
            || !is_provider_thread_id(normalized_thread_id, shared_contracts::ProviderKind::Codex)
        {
            return;
        }

        let next_thread_id = normalized_thread_id.to_string();
        let is_new = self
            .inner
            .resumed_notification_threads
            .write()
            .await
            .insert(next_thread_id.clone());
        if !is_new {
            return;
        }

        self.dispatch_notification_thread_resume(next_thread_id);
    }

    fn dispatch_notification_thread_resume(&self, thread_id: String) {
        let sender = self
            .inner
            .notification_control_tx
            .lock()
            .expect("notification control lock should not be poisoned")
            .clone();
        if let Some(sender) = sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(thread_id.clone()));
        }
        let desktop_sender = self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned")
            .clone();
        if let Some(sender) = desktop_sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(thread_id));
        }
    }

    pub(super) async fn resumable_notification_threads(&self) -> HashSet<String> {
        self.inner.resumed_notification_threads.read().await.clone()
    }

    pub(super) async fn forget_resumable_notification_thread(&self, thread_id: &str) {
        self.inner
            .resumed_notification_threads
            .write()
            .await
            .remove(thread_id);
    }

    pub(super) async fn forget_resumable_notification_threads<I>(&self, thread_ids: I)
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let mut tracked = self.inner.resumed_notification_threads.write().await;
        for thread_id in thread_ids {
            tracked.remove(thread_id.as_ref());
        }
    }

    pub(super) async fn clear_transient_thread_state(&self, thread_id: &str) {
        self.inner.active_turn_ids.write().await.remove(thread_id);
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .remove(thread_id);
        self.inner
            .pending_user_message_images
            .write()
            .await
            .remove(thread_id);
    }

    pub(super) async fn clear_interrupted_thread_state(&self, thread_id: &str) {
        self.inner
            .interrupted_threads
            .write()
            .await
            .remove(thread_id);
    }

    pub(super) async fn mark_thread_interrupt_requested(&self, thread_id: &str) {
        self.inner
            .interrupted_threads
            .write()
            .await
            .insert(thread_id.to_string());
    }

    async fn should_preserve_interrupted_thread_state(&self, thread_id: &str) -> bool {
        self.inner
            .interrupted_threads
            .read()
            .await
            .contains(thread_id)
    }

    pub(super) async fn rewrite_interrupted_thread_status_event(
        &self,
        event: &mut BridgeEventEnvelope<Value>,
    ) {
        if event.kind != BridgeEventKind::ThreadStatusChanged {
            return;
        }

        let Some(status) = event.payload.get("status").and_then(Value::as_str) else {
            return;
        };

        if status == "running" {
            self.clear_interrupted_thread_state(&event.thread_id).await;
            return;
        }

        if !self
            .should_preserve_interrupted_thread_state(&event.thread_id)
            .await
        {
            return;
        }

        if let Some(payload) = event.payload.as_object_mut() {
            payload.insert(
                "status".to_string(),
                Value::String("interrupted".to_string()),
            );
            payload.insert(
                "reason".to_string(),
                Value::String("interrupt_requested".to_string()),
            );
        }
    }

    pub(super) async fn finalize_bridge_owned_turn(&self, thread_id: &str) {
        self.clear_transient_thread_state(thread_id).await;
    }

    pub(super) async fn mark_bridge_turn_stream_started(&self, thread_id: &str) {
        self.inner
            .active_turn_stream_threads
            .write()
            .await
            .insert(thread_id.to_string());
    }

    pub(super) async fn mark_bridge_turn_stream_finished(&self, thread_id: &str) {
        self.inner
            .active_turn_stream_threads
            .write()
            .await
            .remove(thread_id);
    }

    pub(super) async fn has_bridge_turn_stream_active(&self, thread_id: &str) -> bool {
        self.inner
            .active_turn_stream_threads
            .read()
            .await
            .contains(thread_id)
    }

    pub(super) fn schedule_bridge_owned_turn_watchdog(&self, thread_id: &str) {
        let state = self.clone();
        let thread_id = thread_id.to_string();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_secs(5)).await;
                let Some(tracker) = state
                    .inner
                    .outgoing_turns
                    .read()
                    .await
                    .get(&thread_id)
                    .cloned()
                else {
                    break;
                };

                let (timeout_after, timeout_reason) = match tracker.phase {
                    OutgoingTurnPhase::Queued => {
                        (Duration::from_secs(10), "waiting_for_turn_start_ack")
                    }
                    OutgoingTurnPhase::TurnStartAcked => {
                        (Duration::from_secs(15), "waiting_for_user_item")
                    }
                    OutgoingTurnPhase::UserItemSeen => (
                        Duration::from_secs(20),
                        "waiting_for_first_assistant_signal",
                    ),
                    OutgoingTurnPhase::FirstAssistantSignal
                    | OutgoingTurnPhase::Completed
                    | OutgoingTurnPhase::Failed
                    | OutgoingTurnPhase::Timeout => break,
                };

                let Some(last_transition_at) =
                    chrono::DateTime::parse_from_rfc3339(&tracker.last_transition_at)
                        .ok()
                        .map(|timestamp| timestamp.with_timezone(&Utc))
                else {
                    continue;
                };
                let Ok(timeout_window) = chrono::Duration::from_std(timeout_after) else {
                    continue;
                };
                if Utc::now().signed_duration_since(last_transition_at) < timeout_window {
                    continue;
                }

                state
                    .mark_outgoing_turn_phase(
                        &thread_id,
                        OutgoingTurnPhase::Timeout,
                        tracker.turn_id.clone(),
                        Some(timeout_reason.to_string()),
                    )
                    .await;
                let mut payload = json!({
                    "status": "running",
                    "reason": "turn_timeout",
                    "turn_phase": "timeout",
                    "timeout_reason": timeout_reason,
                    "observed_phase": outgoing_turn_phase_wire_value(tracker.phase),
                });
                if let Some(turn_id) = tracker.turn_id.filter(|value| !value.trim().is_empty()) {
                    payload["turn_id"] = Value::String(turn_id);
                }
                state
                    .dispatch_thread_event(build_raw_thread_event(
                        RawThreadEventSource::BridgeLocal,
                        BridgeEventEnvelope {
                            contract_version: CONTRACT_VERSION.to_string(),
                            event_id: format!(
                                "{thread_id}-status-turn-timeout-{}",
                                Utc::now().timestamp_millis()
                            ),
                            thread_id: thread_id.clone(),
                            kind: BridgeEventKind::ThreadStatusChanged,
                            occurred_at: Utc::now().to_rfc3339(),
                            payload,
                            annotations: None,
                            bridge_seq: None,
                        },
                    ))
                    .await;
                state
                    .refresh_snapshot_after_bridge_turn_completion(&thread_id)
                    .await;
                break;
            }
        });
    }

    pub(super) async fn refresh_snapshot_after_bridge_turn_completion(&self, thread_id: &str) {
        let snapshot = match self.inner.gateway.fetch_thread_snapshot(thread_id).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                eprintln!(
                    "bridge thread snapshot refresh after turn completion failed for {thread_id}: {error}"
                );
                return;
            }
        };
        self.apply_bridge_turn_completion_snapshot(thread_id, snapshot)
            .await;
    }

    async fn apply_bridge_turn_completion_snapshot(
        &self,
        thread_id: &str,
        mut snapshot: ThreadSnapshotDto,
    ) {
        let previous_snapshot = self.projections().snapshot(thread_id).await;
        snapshot.thread.access_mode = self.access_mode().await;
        if self
            .should_preserve_interrupted_thread_state(thread_id)
            .await
            && snapshot.thread.status != ThreadStatus::Running
        {
            snapshot.thread.status = ThreadStatus::Interrupted;
            snapshot.thread.active_turn_id = None;
        }

        let mut compactor = LiveDeltaCompactor::default();
        let events = diff_thread_snapshots(previous_snapshot.as_ref(), &snapshot)
            .into_iter()
            .filter_map(|event| {
                let normalized = compactor.compact(event);
                (normalized.kind == BridgeEventKind::ThreadStatusChanged
                    && should_publish_compacted_event(&normalized)
                    && !should_suppress_live_event(&normalized))
                .then_some(normalized)
            })
            .collect::<Vec<_>>();

        self.apply_external_snapshot_update(RawThreadEventSource::SnapshotRepair, snapshot, events)
            .await;
    }

    pub fn start_notification_forwarder(&self) {
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        enum NotificationDispatch {
            Health(ServiceHealthDto),
            ForgetThread(String),
            ForgetThreads(Vec<String>),
            Event(BridgeEventEnvelope<Value>),
        }

        let (dispatch_tx, mut dispatch_rx) =
            tokio_mpsc::unbounded_channel::<NotificationDispatch>();
        let processor_state = self.clone();
        handle.spawn(async move {
            let mut compactor = LiveDeltaCompactor::default();
            while let Some(message) = dispatch_rx.recv().await {
                match message {
                    NotificationDispatch::Health(health) => {
                        processor_state.set_codex_health(health).await;
                    }
                    NotificationDispatch::ForgetThread(thread_id) => {
                        processor_state
                            .forget_resumable_notification_thread(&thread_id)
                            .await;
                    }
                    NotificationDispatch::ForgetThreads(thread_ids) => {
                        processor_state
                            .forget_resumable_notification_threads(thread_ids)
                            .await;
                    }
                    NotificationDispatch::Event(event) => {
                        let mut normalized = compactor.compact(event);
                        if !should_publish_compacted_event(&normalized) {
                            continue;
                        }
                        let has_live_turn_stream = processor_state
                            .has_bridge_turn_stream_active(&normalized.thread_id)
                            .await;
                        if has_live_turn_stream
                            && should_skip_background_notification_event(&normalized)
                        {
                            continue;
                        }
                        let should_suppress_for_bridge_owned_turn =
                            should_suppress_notification_event_for_bridge_active_turn(
                                &normalized,
                                processor_state
                                    .has_bridge_owned_active_turn(&normalized.thread_id)
                                    .await,
                            );
                        if should_suppress_for_bridge_owned_turn {
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
                                RawThreadEventSource::AppServerNotification,
                                normalized,
                            ))
                            .await;
                    }
                }
            }
        });
        let (control_tx, control_rx) = mpsc::channel();
        *self
            .inner
            .notification_control_tx
            .lock()
            .expect("notification control lock should not be poisoned") = Some(control_tx);
        std::thread::spawn(move || {
            loop {
                let mut notifications = match state.inner.gateway.notification_stream() {
                    Ok(stream) => {
                        let _ = dispatch_tx.send(NotificationDispatch::Health(ServiceHealthDto {
                            status: ServiceHealthStatus::Healthy,
                            message: None,
                        }));
                        stream
                    }
                    Err(error) => {
                        eprintln!("bridge notification stream failed to start: {error}");
                        let _ = dispatch_tx.send(NotificationDispatch::Health(ServiceHealthDto {
                            status: ServiceHealthStatus::Degraded,
                            message: Some(format!("notification stream unavailable: {error}")),
                        }));
                        std::thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };

                let resumed_threads = {
                    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                    let state = state.clone();
                    handle.spawn(async move {
                        let _ = reply_tx.send(state.resumable_notification_threads().await);
                    });
                    reply_rx.recv().unwrap_or_default()
                };
                let dropped_threads =
                    match resume_notification_threads(resumed_threads.iter(), |thread_id| {
                        notifications.resume_thread(thread_id)
                    }) {
                        Ok(dropped_threads) => dropped_threads,
                        Err(error) => {
                            eprintln!("bridge notification resume sync failed: {error}");
                            std::thread::sleep(std::time::Duration::from_secs(1));
                            continue;
                        }
                    };
                if !dropped_threads.is_empty() {
                    let _ = dispatch_tx.send(NotificationDispatch::ForgetThreads(dropped_threads));
                }

                loop {
                    if let Err(error) =
                        drain_notification_control_messages(&control_rx, |message| match message {
                            NotificationControlMessage::ResumeThread(thread_id) => {
                                match resume_notification_thread_until_rollout_exists(
                                    &thread_id,
                                    |thread_id| notifications.resume_thread(thread_id),
                                ) {
                                    Ok(()) => Ok(()),
                                    Err(error) if is_stale_rollout_resume_error(&error) => {
                                        let _ = dispatch_tx
                                            .send(NotificationDispatch::ForgetThread(thread_id));
                                        Ok(())
                                    }
                                    Err(error) => Err(error),
                                }
                            }
                        })
                    {
                        eprintln!("bridge notification control failed: {error}");
                        break;
                    }

                    match notifications.next_event() {
                        Ok(Some(event)) => {
                            let _ = dispatch_tx.send(NotificationDispatch::Event(event));
                        }
                        Ok(None) => {
                            let _ =
                                dispatch_tx.send(NotificationDispatch::Health(ServiceHealthDto {
                                    status: ServiceHealthStatus::Degraded,
                                    message: Some(
                                        "notification stream closed; reconnecting".to_string(),
                                    ),
                                }));
                            break;
                        }
                        Err(error) => {
                            eprintln!("bridge notification stream failed: {error}");
                            let _ =
                                dispatch_tx.send(NotificationDispatch::Health(ServiceHealthDto {
                                    status: ServiceHealthStatus::Degraded,
                                    message: Some(format!("notification stream failed: {error}")),
                                }));
                            break;
                        }
                    }
                }

                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
    }
}

fn outgoing_turn_phase_wire_value(phase: OutgoingTurnPhase) -> &'static str {
    match phase {
        OutgoingTurnPhase::Queued => "queued",
        OutgoingTurnPhase::TurnStartAcked => "turn_start_acked",
        OutgoingTurnPhase::UserItemSeen => "user_item_seen",
        OutgoingTurnPhase::FirstAssistantSignal => "first_assistant_signal",
        OutgoingTurnPhase::Completed => "completed",
        OutgoingTurnPhase::Timeout => "timeout",
        OutgoingTurnPhase::Failed => "failed",
    }
}
