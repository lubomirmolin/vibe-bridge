use super::*;
use std::fmt::Write as _;
use std::time::{Duration as StdDuration, Instant};

use crate::server::gateway::GatewayTurnStreamActivity;

#[cfg(test)]
const STALE_NOTIFICATION_RESUME_COOLDOWN: StdDuration = StdDuration::from_millis(200);
#[cfg(not(test))]
const STALE_NOTIFICATION_RESUME_COOLDOWN: StdDuration = StdDuration::from_secs(10);

impl BridgeAppState {
    pub(super) async fn request_notification_thread_resume(&self, thread_id: &str) {
        let normalized_thread_id = thread_id.trim();
        if normalized_thread_id.is_empty()
            || !is_provider_thread_id(normalized_thread_id, shared_contracts::ProviderKind::Codex)
        {
            return;
        }

        let next_thread_id = normalized_thread_id.to_string();
        let now = Instant::now();
        let should_request = self
            .update_thread_runtime(&next_thread_id, |runtime| {
                if let Some(stale_until) = runtime.resumable_notifications_stale_until {
                    if stale_until > now {
                        return false;
                    }
                    runtime.resumable_notifications_stale_until = None;
                }
                if runtime.resumable_notifications {
                    return false;
                }
                runtime.resumable_notifications = true;
                true
            })
            .await;
        if !should_request {
            return;
        }
        eprintln!("bridge notification resume requested thread_id={next_thread_id}");
        self.ensure_actor_owned_notification_stream(next_thread_id.clone());
        let desktop_sender = self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned")
            .clone();
        if let Some(sender) = desktop_sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(next_thread_id));
        }
    }

    async fn apply_resumable_notification_event(&self, mut normalized: BridgeEventEnvelope<Value>) {
        let has_live_turn_stream = self
            .has_bridge_turn_stream_active(&normalized.thread_id)
            .await;
        if has_live_turn_stream && should_skip_background_notification_event(&normalized) {
            return;
        }
        let should_suppress_for_bridge_owned_turn =
            should_suppress_notification_event_for_bridge_active_turn(
                &normalized,
                self.has_bridge_owned_active_turn(&normalized.thread_id)
                    .await,
            );
        if should_suppress_for_bridge_owned_turn {
            return;
        }
        if should_clear_transient_thread_state(&normalized) {
            self.clear_transient_thread_state(&normalized.thread_id)
                .await;
        }
        if normalized.kind != BridgeEventKind::ThreadStatusChanged {
            self.merge_pending_user_message_images(&mut normalized)
                .await;
        }
        self.projections().apply_live_event(&normalized).await;
        self.event_hub().publish(normalized);
    }

    pub(super) async fn forget_resumable_notification_thread(&self, thread_id: &str) {
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.resumable_notifications = false;
            runtime.resumable_notifications_stale_until = None;
        })
        .await;
    }

    pub(super) async fn backoff_resumable_notification_thread_after_stale_rollout(
        &self,
        thread_id: &str,
    ) {
        let stale_until = Instant::now() + STALE_NOTIFICATION_RESUME_COOLDOWN;
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.resumable_notifications = false;
            runtime.resumable_notifications_stale_until = Some(stale_until);
        })
        .await;
    }

    pub(super) async fn forget_resumable_notification_threads<I>(&self, thread_ids: I)
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        for thread_id in thread_ids {
            self.forget_resumable_notification_thread(thread_id.as_ref())
                .await;
        }
    }

    pub(super) async fn clear_transient_thread_state(&self, thread_id: &str) {
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.active_turn_id = None;
            runtime.pending_user_message_images.clear();
        })
        .await;
    }

    pub(super) async fn clear_pending_turn_client_message(&self, thread_id: &str) {
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.pending_client_message = None;
        })
        .await;
    }

    pub(super) async fn clear_interrupted_thread_state(&self, thread_id: &str) {
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.interrupted = false;
        })
        .await;
    }

    pub(super) async fn mark_thread_interrupt_requested(&self, thread_id: &str) {
        self.update_thread_runtime(thread_id, |runtime| {
            runtime.interrupted = true;
        })
        .await;
    }

    async fn should_preserve_interrupted_thread_state(&self, thread_id: &str) -> bool {
        self.read_thread_runtime(thread_id, |runtime| {
            runtime.is_some_and(|runtime| runtime.interrupted)
        })
        .await
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
        eprintln!("bridge turn finalize thread_id={thread_id}");
        self.clear_transient_thread_state(thread_id).await;
    }

    async fn has_bridge_turn_stream_active(&self, thread_id: &str) -> bool {
        self.inner
            .gateway
            .thread_lifecycle_state(thread_id)
            .await
            .map(|state| state.stream_active)
            .unwrap_or(false)
    }

    pub(super) fn schedule_bridge_owned_turn_watchdog(&self, _thread_id: &str) {}

    pub(super) async fn refresh_snapshot_after_bridge_turn_completion(
        &self,
        thread_id: &str,
        activity: GatewayTurnStreamActivity,
    ) {
        if !activity.requires_completion_snapshot_refresh() {
            eprintln!(
                "bridge completion snapshot refresh skipped thread_id={thread_id} reason=stream_was_self_sufficient activity=user:{} assistant:{} workflow:{} completed:{}",
                activity.saw_user_message,
                activity.saw_assistant_message,
                activity.saw_workflow_event,
                activity.saw_turn_completed
            );
            return;
        }
        let refresh_started_at = Instant::now();
        eprintln!("bridge completion snapshot refresh start thread_id={thread_id}");
        let snapshot = match self.inner.gateway.fetch_thread_snapshot(thread_id).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                eprintln!(
                    "bridge thread snapshot refresh after turn completion failed for {thread_id}: {error}"
                );
                return;
            }
        };
        eprintln!(
            "bridge completion snapshot refresh fetched thread_id={thread_id} elapsed_ms={} snapshot={}",
            refresh_started_at.elapsed().as_millis(),
            summarize_snapshot_for_debug(&snapshot)
        );
        self.apply_bridge_turn_completion_snapshot(thread_id, snapshot)
            .await;
    }

    pub(super) async fn apply_bridge_turn_completion_snapshot(
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

        eprintln!(
            "bridge completion snapshot apply thread_id={thread_id} previous={} next={} published_status_events={}",
            previous_snapshot
                .as_ref()
                .map(summarize_snapshot_for_debug)
                .unwrap_or_else(|| "<none>".to_string()),
            summarize_snapshot_for_debug(&snapshot),
            events.len()
        );

        self.apply_external_snapshot_update(snapshot, events).await;
    }
}

impl BridgeAppState {
    fn ensure_actor_owned_notification_stream(&self, thread_id: String) {
        let handle = tokio::runtime::Handle::current();
        let state = self.clone();
        let thread_id_for_error = thread_id.clone();
        let compactor = Arc::new(std::sync::Mutex::new(LiveDeltaCompactor::default()));
        let event_state = state.clone();
        let event_handle = handle.clone();
        let stale_state = state.clone();
        let stale_handle = handle.clone();
        let result = self.inner.gateway.ensure_notification_stream(
            &thread_id,
            move |event| {
                let normalized = compactor
                    .lock()
                    .expect("notification compactor lock should not be poisoned")
                    .compact(event);
                if !should_publish_compacted_event(&normalized) {
                    return;
                }
                if should_suppress_live_event(&normalized) {
                    return;
                }
                let state = event_state.clone();
                event_handle.block_on(async move {
                    state.apply_resumable_notification_event(normalized).await;
                });
            },
            move |thread_id| {
                let state = stale_state.clone();
                stale_handle.block_on(async move {
                    state
                        .backoff_resumable_notification_thread_after_stale_rollout(&thread_id)
                        .await;
                });
            },
        );
        if let Err(error) = result {
            eprintln!(
                "bridge actor notification stream dispatch failed thread_id={thread_id_for_error}: {error}"
            );
        }
    }
}

fn summarize_snapshot_for_debug(snapshot: &ThreadSnapshotDto) -> String {
    let mut buffer = String::new();
    let message_count = snapshot
        .entries
        .iter()
        .filter(|entry| entry.kind == BridgeEventKind::MessageDelta)
        .count();
    let status_count = snapshot
        .entries
        .iter()
        .filter(|entry| entry.kind == BridgeEventKind::ThreadStatusChanged)
        .count();
    let recent_entries = snapshot
        .entries
        .iter()
        .rev()
        .take(5)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(|entry| {
            format!(
                "{}:{:?}:{}",
                entry.event_id,
                entry.kind,
                entry
                    .payload
                    .get("type")
                    .and_then(Value::as_str)
                    .or_else(|| entry.payload.get("status").and_then(Value::as_str))
                    .unwrap_or("-")
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let latest_message = snapshot
        .entries
        .iter()
        .rev()
        .find(|entry| entry.kind == BridgeEventKind::MessageDelta)
        .and_then(|entry| {
            entry
                .payload
                .get("text")
                .and_then(Value::as_str)
                .or_else(|| entry.payload.get("delta").and_then(Value::as_str))
                .map(|text| truncate_for_debug(text, 80))
        })
        .unwrap_or_else(|| "<none>".to_string());
    let _ = write!(
        buffer,
        "status={:?} updated_at={} entries={} messages={} statuses={} last_message={} recent=[{}]",
        snapshot.thread.status,
        snapshot.thread.updated_at,
        snapshot.entries.len(),
        message_count,
        status_count,
        latest_message,
        recent_entries
    );
    buffer
}

fn truncate_for_debug(value: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    let mut truncated = trimmed.chars().take(max_chars).collect::<String>();
    truncated.push_str("...");
    truncated
}
