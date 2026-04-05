use super::*;

#[derive(Debug, Default)]
pub(super) struct LiveDeltaCompactor {
    text_by_event_id: HashMap<String, String>,
    output_by_event_id: HashMap<String, String>,
    diff_by_event_id: HashMap<String, String>,
}

impl LiveDeltaCompactor {
    pub(super) fn compact(
        &mut self,
        event: BridgeEventEnvelope<Value>,
    ) -> BridgeEventEnvelope<Value> {
        match event.kind {
            BridgeEventKind::MessageDelta => {
                if event.payload.get("text").is_none()
                    && event.payload.get("delta").and_then(Value::as_str).is_some()
                {
                    return event;
                }
                let role = match event.payload.get("type").and_then(Value::as_str) {
                    Some("userMessage") => "user",
                    _ => "assistant",
                };
                let current_text = event
                    .payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.text_by_event_id,
                    &event.event_id,
                    current_text,
                );

                let mut payload = json!({
                    "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                    "type": "message",
                    "role": role,
                    "delta": delta,
                    "replace": replace,
                });
                if let Some(client_message_id) = event
                    .payload
                    .get("client_message_id")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    && let Some(object) = payload.as_object_mut()
                {
                    object.insert(
                        "client_message_id".to_string(),
                        Value::String(client_message_id.to_string()),
                    );
                }

                BridgeEventEnvelope { payload, ..event }
            }
            BridgeEventKind::PlanDelta => {
                if event.payload.get("text").is_none()
                    && event.payload.get("delta").and_then(Value::as_str).is_some()
                {
                    return event;
                }
                let current_text = event
                    .payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.text_by_event_id,
                    &event.event_id,
                    current_text,
                );

                let mut payload = json!({
                    "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                    "type": "plan",
                    "delta": delta,
                    "replace": replace,
                });
                if let Some(object) = payload.as_object_mut() {
                    if let Some(explanation) = event.payload.get("explanation") {
                        object.insert("explanation".to_string(), explanation.clone());
                    }
                    if let Some(steps) = event.payload.get("steps") {
                        object.insert("steps".to_string(), steps.clone());
                    }
                    if let Some(completed_count) = event.payload.get("completed_count") {
                        object.insert("completed_count".to_string(), completed_count.clone());
                    }
                    if let Some(total_count) = event.payload.get("total_count") {
                        object.insert("total_count".to_string(), total_count.clone());
                    }
                }

                BridgeEventEnvelope { payload, ..event }
            }
            BridgeEventKind::CommandDelta => {
                let current_output = event
                    .payload
                    .get("output")
                    .or_else(|| event.payload.get("aggregatedOutput"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.output_by_event_id,
                    &event.event_id,
                    current_output,
                );

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "command",
                        "command": event.payload.get("command").and_then(Value::as_str).unwrap_or_default(),
                        "cmd": event.payload.get("cmd").and_then(Value::as_str),
                        "workdir": event.payload.get("cwd").and_then(Value::as_str),
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
            }
            BridgeEventKind::FileChange => {
                let current_diff = event
                    .payload
                    .get("resolved_unified_diff")
                    .or_else(|| event.payload.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.diff_by_event_id,
                    &event.event_id,
                    current_diff,
                );

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "file_change",
                        "path": event.payload.get("path").or_else(|| event.payload.get("file")).and_then(Value::as_str).unwrap_or_default(),
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
            }
            _ => event,
        }
    }
}

fn compact_incremental_text(
    cache: &mut HashMap<String, String>,
    event_id: &str,
    current_value: &str,
) -> (String, bool) {
    compact_incremental_full_text(cache, event_id, current_value)
}

pub(super) fn claude_permission_mode_for_access_mode(access_mode: AccessMode) -> String {
    match access_mode {
        AccessMode::ReadOnly => "plan".to_string(),
        AccessMode::ControlWithApprovals => "default".to_string(),
        AccessMode::FullControl => "acceptEdits".to_string(),
    }
}

pub(super) fn thread_status_wire_value(status: ThreadStatus) -> &'static str {
    match status {
        ThreadStatus::Idle => "idle",
        ThreadStatus::Running => "running",
        ThreadStatus::Completed => "completed",
        ThreadStatus::Interrupted => "interrupted",
        ThreadStatus::Failed => "failed",
    }
}

pub(super) fn build_turn_started_history_event(
    thread_id: &str,
    occurred_at: &str,
    turn_id: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
) -> BridgeEventEnvelope<Value> {
    let mut payload = json!({
        "status": "running",
        "reason": "turn_started",
    });
    if let Some(turn_id) = turn_id.filter(|value| !value.trim().is_empty()) {
        payload["turn_id"] = Value::String(turn_id.to_string());
    }
    if let Some(model) = model.filter(|value| !value.trim().is_empty()) {
        payload["model"] = Value::String(model.to_string());
    }
    if let Some(effort) = effort.filter(|value| !value.trim().is_empty()) {
        payload["reasoning_effort"] = Value::String(effort.to_string());
    }

    BridgeEventEnvelope {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        event_id: format!("{thread_id}-status-turn-started-{occurred_at}"),
        bridge_seq: None,
        thread_id: thread_id.to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: occurred_at.to_string(),
        payload,
        annotations: None,
    }
}

pub(super) fn should_synthesize_visible_user_prompt(
    visible_prompt: &str,
    upstream_prompt: &str,
) -> bool {
    !visible_prompt.trim().is_empty() && is_hidden_message(upstream_prompt)
}

pub(super) fn build_visible_user_message_event(
    thread_id: &str,
    occurred_at: &str,
    turn_id: Option<&str>,
    visible_prompt: &str,
    client_message_id: Option<&str>,
) -> BridgeEventEnvelope<Value> {
    let prompt = visible_prompt.trim();
    let mut payload = json!({
        "type": "userMessage",
        "role": "user",
        "text": prompt,
        "content": [{
            "text": prompt,
        }],
    });
    if let Some(client_message_id) = client_message_id.filter(|value| !value.trim().is_empty())
        && let Some(object) = payload.as_object_mut()
    {
        object.insert(
            "client_message_id".to_string(),
            Value::String(client_message_id.to_string()),
        );
    }

    let event_id = match turn_id.filter(|value| !value.trim().is_empty()) {
        Some(turn_id) => format!("{turn_id}-visible-user-prompt"),
        None => format!("{thread_id}-visible-user-prompt-{occurred_at}"),
    };

    BridgeEventEnvelope {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        event_id,
        bridge_seq: None,
        thread_id: thread_id.to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: occurred_at.to_string(),
        payload,
        annotations: None,
    }
}

pub(super) fn should_publish_compacted_event(event: &BridgeEventEnvelope<Value>) -> bool {
    match event.kind {
        BridgeEventKind::MessageDelta => {
            payload_has_visible_live_content(&event.payload, &["delta", "text", "message"], &[])
        }
        BridgeEventKind::PlanDelta => {
            payload_has_visible_live_content(&event.payload, &["delta", "text"], &["steps"])
        }
        BridgeEventKind::CommandDelta => payload_has_visible_live_content(
            &event.payload,
            &["delta", "output", "aggregatedOutput"],
            &["arguments", "input"],
        ),
        BridgeEventKind::FileChange => payload_has_visible_live_content(
            &event.payload,
            &["delta", "resolved_unified_diff", "output"],
            &[],
        ),
        _ => true,
    }
}

fn payload_has_visible_live_content(
    payload: &Value,
    text_keys: &[&str],
    structured_keys: &[&str],
) -> bool {
    if payload
        .get("replace")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return true;
    }
    if text_keys.iter().any(|key| {
        payload
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
    }) {
        return true;
    }
    structured_keys
        .iter()
        .any(|key| payload.get(*key).is_some_and(|value| !value.is_null()))
}

pub(super) fn should_suppress_live_event(event: &BridgeEventEnvelope<Value>) -> bool {
    event.kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&event.payload)
}

pub(super) fn should_clear_transient_thread_state(event: &BridgeEventEnvelope<Value>) -> bool {
    event.kind == BridgeEventKind::ThreadStatusChanged
        && event
            .payload
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| status != "running")
}

pub(super) fn should_suppress_notification_event_for_bridge_active_turn(
    event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    should_suppress_non_running_thread_status_for_bridge_active_turn(
        event,
        has_bridge_owned_active_turn,
    )
}

pub(super) fn should_skip_background_notification_event(
    event: &BridgeEventEnvelope<Value>,
) -> bool {
    if event.kind != BridgeEventKind::ThreadStatusChanged {
        return true;
    }

    event
        .payload
        .get("status")
        .and_then(Value::as_str)
        .is_none_or(|status| status == "running")
}

pub(super) fn should_suppress_non_running_thread_status_for_bridge_active_turn(
    event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    has_bridge_owned_active_turn
        && event.kind == BridgeEventKind::ThreadStatusChanged
        && event
            .payload
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| status != "running")
}

#[cfg(test)]
pub(super) fn should_defer_bridge_owned_turn_finalization(status: ThreadStatus) -> bool {
    status == ThreadStatus::Running
}

#[cfg(test)]
pub(super) fn watchdog_should_finalize_bridge_owned_turn(
    status: ThreadStatus,
    has_active_turn_stream: bool,
) -> bool {
    status != ThreadStatus::Running && !has_active_turn_stream
}

pub(super) fn build_desktop_ipc_snapshot_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    previous_summary_status: Option<ThreadStatus>,
    conversation_state: &Value,
    access_mode: AccessMode,
    compactor: &mut LiveDeltaCompactor,
    is_patch_update: bool,
    latest_raw_turn_status: Option<&str>,
    has_bridge_owned_active_turn: bool,
) -> Result<(ThreadSnapshotDto, Vec<BridgeEventEnvelope<Value>>), String> {
    let mut next_snapshot =
        snapshot_from_conversation_state(conversation_state, previous_snapshot, access_mode)?;
    preserve_bootstrap_status_for_cached_desktop_snapshot(
        previous_snapshot,
        previous_summary_status,
        &mut next_snapshot,
        is_patch_update,
    );
    ensure_running_status_for_desktop_patch_update(
        previous_snapshot,
        &mut next_snapshot,
        is_patch_update,
        latest_raw_turn_status,
    );
    preserve_running_status_for_bridge_owned_desktop_update(
        previous_snapshot,
        &mut next_snapshot,
        latest_raw_turn_status,
        has_bridge_owned_active_turn,
    );

    let events = diff_thread_snapshots(previous_snapshot, &next_snapshot)
        .into_iter()
        .filter_map(|event| {
            let normalized = compactor.compact(event);
            (should_publish_desktop_ipc_live_event(&normalized, has_bridge_owned_active_turn)
                && should_publish_compacted_event(&normalized)
                && !should_suppress_live_event(&normalized))
            .then_some(normalized)
        })
        .collect::<Vec<_>>();

    Ok((next_snapshot, events))
}

fn should_publish_desktop_ipc_live_event(
    _event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    !has_bridge_owned_active_turn
}

pub(super) fn preserve_running_status_for_bridge_owned_desktop_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &mut ThreadSnapshotDto,
    latest_raw_turn_status: Option<&str>,
    has_bridge_owned_active_turn: bool,
) {
    if !has_bridge_owned_active_turn {
        return;
    }
    if previous_snapshot
        .map(|snapshot| snapshot.thread.status != ThreadStatus::Running)
        .unwrap_or(true)
    {
        return;
    }
    if next_snapshot.thread.status == ThreadStatus::Running {
        return;
    }
    if desktop_raw_turn_status_is_terminal(latest_raw_turn_status) {
        return;
    }

    next_snapshot.thread.status = ThreadStatus::Running;
}

fn desktop_raw_turn_status_is_terminal(latest_raw_turn_status: Option<&str>) -> bool {
    matches!(
        latest_raw_turn_status.map(|status| status.trim().to_ascii_lowercase()),
        Some(status)
            if matches!(
                status.as_str(),
                "completed"
                    | "complete"
                    | "done"
                    | "success"
                    | "ok"
                    | "succeeded"
                    | "interrupted"
                    | "halted"
                    | "cancelled"
                    | "canceled"
                    | "failed"
                    | "fail"
                    | "error"
                    | "errored"
                    | "denied"
            )
    )
}

pub(super) fn preserve_bootstrap_status_for_cached_desktop_snapshot(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    previous_summary_status: Option<ThreadStatus>,
    next_snapshot: &mut ThreadSnapshotDto,
    is_patch_update: bool,
) {
    if is_patch_update || previous_snapshot.is_some() {
        return;
    }

    let Some(previous_summary_status) = previous_summary_status else {
        return;
    };

    if previous_summary_status == ThreadStatus::Running
        || next_snapshot.thread.status != ThreadStatus::Running
    {
        return;
    }

    next_snapshot.thread.status = previous_summary_status;
}

pub(super) fn ensure_running_status_for_desktop_patch_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &mut ThreadSnapshotDto,
    is_patch_update: bool,
    _latest_raw_turn_status: Option<&str>,
) {
    if !is_patch_update {
        return;
    }
    if previous_snapshot
        .map(|snapshot| snapshot.thread.status == ThreadStatus::Running)
        .unwrap_or(false)
    {
        return;
    }
    if next_snapshot.thread.status == ThreadStatus::Running {
        return;
    }
    if matches!(
        next_snapshot.thread.status,
        ThreadStatus::Completed | ThreadStatus::Interrupted | ThreadStatus::Failed
    ) {
        return;
    }
    if !desktop_patch_update_has_fresh_activity(previous_snapshot, next_snapshot) {
        return;
    }

    next_snapshot.thread.status = ThreadStatus::Running;
}

fn desktop_patch_update_has_fresh_activity(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &ThreadSnapshotDto,
) -> bool {
    if next_snapshot.entries.is_empty() {
        return false;
    }

    let Some(previous_snapshot) = previous_snapshot else {
        return true;
    };

    previous_snapshot.entries != next_snapshot.entries
}

pub(super) fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_message)
        .unwrap_or(false)
}

fn payload_primary_text(payload: &Value) -> Option<&str> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed);
            }
        }
    }

    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|item| item.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

pub(super) fn is_hidden_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("<turn_aborted>")
        || trimmed.starts_with("You are running in mobile plan intake mode.")
        || trimmed.starts_with("You are continuing a mobile planning workflow.")
        || trimmed.contains("<codex-plan-questions>")
}

pub(super) fn resume_notification_threads<'a, I, F>(
    thread_ids: I,
    mut resume_thread: F,
) -> Result<Vec<String>, String>
where
    I: IntoIterator<Item = &'a String>,
    F: FnMut(&str) -> Result<(), String>,
{
    let mut dropped_threads = Vec::new();
    for thread_id in thread_ids {
        match resume_notification_thread_until_rollout_exists(thread_id, &mut resume_thread) {
            Ok(()) => {}
            Err(error) if is_stale_rollout_resume_error(&error) => {
                dropped_threads.push(thread_id.to_string());
            }
            Err(error) => return Err(error),
        }
    }
    Ok(dropped_threads)
}

pub(super) fn drain_notification_control_messages<F>(
    control_rx: &mpsc::Receiver<NotificationControlMessage>,
    mut handle_message: F,
) -> Result<(), String>
where
    F: FnMut(NotificationControlMessage) -> Result<(), String>,
{
    loop {
        match control_rx.try_recv() {
            Ok(message) => handle_message(message)?,
            Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => {
                return Ok(());
            }
        }
    }
}

pub(super) fn resume_notification_thread_until_rollout_exists<F>(
    thread_id: &str,
    mut resume_thread: F,
) -> Result<(), String>
where
    F: FnMut(&str) -> Result<(), String>,
{
    const MAX_ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_millis(50);

    let mut last_stale_rollout_error: Option<String> = None;
    for attempt in 0..MAX_ATTEMPTS {
        match resume_thread(thread_id) {
            Ok(()) => return Ok(()),
            Err(error) if is_stale_rollout_resume_error(&error) => {
                last_stale_rollout_error = Some(error);
                if attempt + 1 < MAX_ATTEMPTS {
                    std::thread::sleep(RETRY_DELAY);
                    continue;
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(last_stale_rollout_error
        .unwrap_or_else(|| format!("codex rpc request 'thread/resume' failed for {thread_id}")))
}

pub(super) fn is_stale_rollout_resume_error(error: &str) -> bool {
    error.contains("no rollout found") || error.contains("rollout at") && error.contains("is empty")
}
