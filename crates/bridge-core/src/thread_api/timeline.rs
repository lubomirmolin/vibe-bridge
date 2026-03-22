use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{SecondsFormat, TimeZone, Utc};
use serde_json::Value;
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto,
    ThreadStatus, ThreadSummaryDto, ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
};

use super::notifications::normalize_codex_item_payload;
use super::rpc::CodexThread;
use super::{GitStatusDto, RepositoryContextDto, UpstreamThreadRecord, UpstreamTimelineEvent};

pub(super) fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_archive_message)
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

pub(super) fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}

pub(super) fn normalize_custom_tool_output(raw_output: &str) -> String {
    if raw_output.trim().is_empty() {
        return String::new();
    }

    if let Ok(decoded) = serde_json::from_str::<Value>(raw_output)
        && let Some(text) = decoded.get("output").and_then(Value::as_str)
    {
        return text.to_string();
    }

    raw_output.to_string()
}

pub(super) fn truncate_summary(text: &str) -> String {
    const MAX_CHARS: usize = 140;
    let trimmed = text.trim();
    if trimmed.chars().count() <= MAX_CHARS {
        return trimmed.to_string();
    }

    let mut summary = trimmed.chars().take(MAX_CHARS - 1).collect::<String>();
    summary.push_str("...");
    summary
}

pub(super) fn map_codex_thread_to_upstream_record(thread: &CodexThread) -> UpstreamThreadRecord {
    let repository_name = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());

    let branch_name = thread
        .git_info
        .as_ref()
        .and_then(|git| git.branch.clone())
        .unwrap_or_else(|| "unknown".to_string());

    let remote_name = if thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_ref())
        .is_some()
    {
        "origin".to_string()
    } else {
        "local".to_string()
    };

    let source = thread.source.as_str().unwrap_or("unknown").to_string();

    let title = thread
        .name
        .as_deref()
        .or(thread.preview.as_deref())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();

    UpstreamThreadRecord {
        id: thread.id.clone(),
        headline: title,
        lifecycle_state: map_codex_status_to_lifecycle_state(&thread.status.kind),
        workspace_path: thread.cwd.clone(),
        repository_name,
        branch_name,
        remote_name,
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: unix_timestamp_to_iso8601(thread.created_at),
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
        source,
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: thread.preview.clone().unwrap_or_default(),
    }
}

pub(super) fn map_codex_thread_to_timeline_events(
    thread: &CodexThread,
) -> Vec<UpstreamTimelineEvent> {
    let mut events = Vec::new();
    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let Some((kind, payload)) =
                normalize_codex_item_payload(item, Some(thread.cwd.as_str()))
            else {
                continue;
            };
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&payload) {
                continue;
            }
            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));

            events.push(UpstreamTimelineEvent {
                id: format!("{}-{item_id}", turn.id),
                event_type: map_bridge_kind_to_event_type(kind).to_string(),
                happened_at: codex_item_occurred_at(item, &turn.id, thread.updated_at),
                summary_text: summarize_live_payload(kind, &payload),
                data: payload,
            });
        }
    }
    events
}

fn codex_item_occurred_at(item: &Value, turn_id: &str, thread_updated_at: i64) -> String {
    if let Some(timestamp) = codex_timestamp_from_item(item) {
        return timestamp;
    }

    if let Some(timestamp) = uuid_v7_timestamp_to_iso8601(turn_id) {
        return timestamp;
    }

    unix_timestamp_to_iso8601(thread_updated_at)
}

fn codex_timestamp_from_item(item: &Value) -> Option<String> {
    const KEYS: [&str; 8] = [
        "timestamp",
        "occurredAt",
        "updatedAt",
        "createdAt",
        "startedAt",
        "completedAt",
        "startTime",
        "endTime",
    ];

    KEYS.iter()
        .find_map(|key| item.get(*key))
        .and_then(value_to_timestamp)
}

fn value_to_timestamp(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }

            if let Ok(parsed_numeric) = trimmed.parse::<i64>() {
                Some(unix_timestamp_to_iso8601(parsed_numeric))
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => number.as_i64().map(unix_timestamp_to_iso8601).or_else(|| {
            number
                .as_u64()
                .map(|value| unix_timestamp_to_iso8601(value as i64))
        }),
        _ => None,
    }
}

fn uuid_v7_timestamp_to_iso8601(value: &str) -> Option<String> {
    let compact = value.chars().filter(|ch| *ch != '-').collect::<String>();
    if compact.len() != 32 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }
    if compact
        .chars()
        .nth(12)
        .is_none_or(|version| !version.eq_ignore_ascii_case(&'7'))
    {
        return None;
    }

    let millis = i64::from_str_radix(&compact[0..12], 16).ok()?;
    Some(unix_timestamp_to_iso8601(millis))
}

pub(super) fn map_codex_status_to_lifecycle_state(status_kind: &str) -> String {
    match status_kind {
        "active" => "active".to_string(),
        "systemError" => "error".to_string(),
        _ => "idle".to_string(),
    }
}

pub(super) fn parse_repository_name_from_origin(origin_url: &str) -> Option<String> {
    let trimmed = origin_url.trim_end_matches('/');
    let segment = trimmed
        .rsplit(['/', ':'])
        .next()
        .filter(|segment| !segment.is_empty())?;
    Some(segment.trim_end_matches(".git").to_string())
}

pub(super) fn derive_repository_name_from_cwd(cwd: &str) -> Option<String> {
    Path::new(cwd)
        .file_name()
        .and_then(|name| name.to_str())
        .map(ToString::to_string)
}

pub(super) fn map_thread_summary(upstream: &UpstreamThreadRecord) -> ThreadSummaryDto {
    ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: upstream.id.clone(),
        title: upstream.headline.clone(),
        status: map_thread_status(&upstream.lifecycle_state),
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        updated_at: upstream.updated_at.clone(),
    }
}

pub(super) fn map_thread_detail(upstream: &UpstreamThreadRecord) -> ThreadDetailDto {
    ThreadDetailDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: upstream.id.clone(),
        title: upstream.headline.clone(),
        status: map_thread_status(&upstream.lifecycle_state),
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        created_at: upstream.created_at.clone(),
        updated_at: upstream.updated_at.clone(),
        source: upstream.source.clone(),
        access_mode: map_access_mode(&upstream.approval_mode),
        last_turn_summary: upstream.last_turn_summary.clone(),
    }
}

pub(super) fn map_repository_context(upstream: &UpstreamThreadRecord) -> RepositoryContextDto {
    RepositoryContextDto {
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        remote: upstream.remote_name.clone(),
    }
}

pub(super) fn map_git_status(upstream: &UpstreamThreadRecord) -> GitStatusDto {
    GitStatusDto {
        dirty: upstream.git_dirty,
        ahead_by: upstream.git_ahead_by,
        behind_by: upstream.git_behind_by,
    }
}

pub(super) fn map_timeline_entry(upstream: &UpstreamTimelineEvent) -> ThreadTimelineEntryDto {
    let kind = map_event_kind(&upstream.event_type);

    ThreadTimelineEntryDto {
        event_id: upstream.id.clone(),
        kind,
        occurred_at: upstream.happened_at.clone(),
        summary: upstream.summary_text.clone(),
        payload: upstream.data.clone(),
        annotations: timeline_annotations_for_event(&upstream.id, kind, &upstream.data),
    }
}

pub(super) fn build_timeline_event_envelope(
    event_id: impl Into<String>,
    thread_id: impl Into<String>,
    kind: BridgeEventKind,
    occurred_at: impl Into<String>,
    payload: Value,
) -> BridgeEventEnvelope<Value> {
    let event_id = event_id.into();
    let annotations = timeline_annotations_for_event(&event_id, kind, &payload);

    BridgeEventEnvelope::new(event_id, thread_id, kind, occurred_at, payload)
        .with_annotations(annotations)
}

fn timeline_annotations_for_event(
    event_id: &str,
    kind: BridgeEventKind,
    payload: &Value,
) -> Option<ThreadTimelineAnnotationsDto> {
    let exploration_kind = classify_exploration_kind(kind, payload)?;
    let command = extract_exploration_command(payload)?;

    Some(ThreadTimelineAnnotationsDto {
        group_kind: Some(ThreadTimelineGroupKind::Exploration),
        group_id: derive_exploration_group_id(event_id, payload),
        exploration_kind: Some(exploration_kind),
        entry_label: exploration_entry_label(exploration_kind, command.as_str()),
    })
}

fn classify_exploration_kind(
    kind: BridgeEventKind,
    payload: &Value,
) -> Option<ThreadTimelineExplorationKind> {
    if kind != BridgeEventKind::CommandDelta {
        return None;
    }

    let command = extract_exploration_command(payload)?;
    let normalized_command = command.trim().to_lowercase();
    if is_exploration_read_command(&normalized_command) {
        Some(ThreadTimelineExplorationKind::Read)
    } else if is_exploration_search_command(&normalized_command) {
        Some(ThreadTimelineExplorationKind::Search)
    } else {
        None
    }
}

fn extract_exploration_command(payload: &Value) -> Option<String> {
    [
        payload.get("command"),
        payload.get("action"),
        payload.get("arguments"),
        payload.get("input"),
        payload.get("output"),
        payload.get("aggregatedOutput"),
    ]
    .into_iter()
    .flatten()
    .filter_map(extract_shell_like_command)
    .find(|command| {
        let normalized = command.trim().to_lowercase();
        is_exploration_read_command(&normalized) || is_exploration_search_command(&normalized)
    })
}

fn extract_shell_like_command(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }

            if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                return extract_shell_like_command(&parsed)
                    .or_else(|| parse_background_command(trimmed));
            }

            parse_background_command(trimmed).or_else(|| Some(trimmed.to_string()))
        }
        Value::Object(object) => object
            .get("cmd")
            .or_else(|| object.get("command"))
            .or_else(|| object.get("action"))
            .and_then(extract_shell_like_command)
            .or_else(|| object.get("input").and_then(extract_shell_like_command))
            .or_else(|| object.get("arguments").and_then(extract_shell_like_command)),
        Value::Array(values) => values.iter().find_map(extract_shell_like_command),
        other => {
            value_to_text(other).and_then(|text| extract_shell_like_command(&Value::String(text)))
        }
    }
}

fn parse_background_command(raw: &str) -> Option<String> {
    raw.lines()
        .find_map(|line| line.strip_prefix("Command:"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn is_exploration_read_command(command: &str) -> bool {
    command.starts_with("nl -ba ")
        || command.starts_with("cat ")
        || command.starts_with("bat ")
        || command.starts_with("sed -n ")
        || command.starts_with("head ")
        || command.starts_with("tail ")
        || command.starts_with("git diff ")
        || command.starts_with("git show ")
        || command == "git status"
        || command.starts_with("git status ")
        || command == "pwd"
}

fn is_exploration_search_command(command: &str) -> bool {
    command == "ls"
        || command.starts_with("ls ")
        || command == "tree"
        || command.starts_with("tree ")
        || command.starts_with("fd ")
        || command.starts_with("git grep ")
        || command.starts_with("git ls-files")
        || command.starts_with("rg -n ")
        || command.starts_with("rg --files ")
        || command == "rg"
        || command.starts_with("rg ")
        || command.starts_with("find ")
        || command.starts_with("grep ")
        || command.starts_with("search_query ")
}

fn derive_exploration_group_id(event_id: &str, payload: &Value) -> Option<String> {
    let item_id = payload.get("id").and_then(Value::as_str)?.trim();
    let turn_prefix = event_id.strip_suffix(&format!("-{item_id}"))?.trim();
    if turn_prefix.is_empty() {
        return None;
    }

    Some(format!("exploration:{turn_prefix}"))
}

fn exploration_entry_label(
    exploration_kind: ThreadTimelineExplorationKind,
    command: &str,
) -> Option<String> {
    match exploration_kind {
        ThreadTimelineExplorationKind::Read => {
            extract_file_name_from_command(command).map(|file_name| format!("Read {file_name}"))
        }
        ThreadTimelineExplorationKind::Search => Some("Search".to_string()),
    }
}

fn extract_file_name_from_command(command: &str) -> Option<String> {
    command
        .split_whitespace()
        .map(|segment| segment.trim_matches(|ch| ch == '"' || ch == '\'' || ch == '`'))
        .rfind(|segment| segment.contains('/') || segment.contains('.'))
        .and_then(|path| path.rsplit('/').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

pub(super) fn map_thread_status(raw: &str) -> ThreadStatus {
    match raw {
        "active" => ThreadStatus::Running,
        "done" => ThreadStatus::Completed,
        "halted" => ThreadStatus::Interrupted,
        "error" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
}

fn map_access_mode(raw: &str) -> AccessMode {
    match raw {
        "read_only" => AccessMode::ReadOnly,
        "full_control" => AccessMode::FullControl,
        _ => AccessMode::ControlWithApprovals,
    }
}

pub(super) fn map_event_kind(raw: &str) -> BridgeEventKind {
    match raw {
        "agent_message_delta" => BridgeEventKind::MessageDelta,
        "plan_delta" => BridgeEventKind::PlanDelta,
        "command_output_delta" => BridgeEventKind::CommandDelta,
        "file_change_delta" => BridgeEventKind::FileChange,
        "approval_requested" => BridgeEventKind::ApprovalRequested,
        "thread_status_changed" => BridgeEventKind::ThreadStatusChanged,
        _ => BridgeEventKind::MessageDelta,
    }
}

pub(super) fn map_bridge_kind_to_event_type(kind: BridgeEventKind) -> &'static str {
    match kind {
        BridgeEventKind::MessageDelta => "agent_message_delta",
        BridgeEventKind::PlanDelta => "plan_delta",
        BridgeEventKind::CommandDelta => "command_output_delta",
        BridgeEventKind::FileChange => "file_change_delta",
        BridgeEventKind::ThreadStatusChanged => "thread_status_changed",
        BridgeEventKind::ApprovalRequested => "approval_requested",
        BridgeEventKind::SecurityAudit => "security_audit",
    }
}

pub(super) fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::CommandDelta => payload
            .get("output")
            .or_else(|| payload.get("aggregatedOutput"))
            .or_else(|| payload.get("command"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::FileChange => payload
            .get("resolved_unified_diff")
            .or_else(|| payload.get("output"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| {
                payload
                    .get("path")
                    .or_else(|| payload.get("file"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
            })
            .to_string(),
        BridgeEventKind::ThreadStatusChanged => payload
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::ApprovalRequested => payload
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::SecurityAudit => payload
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}

pub(super) fn map_wire_thread_status_to_lifecycle_state(raw: &str) -> String {
    match raw {
        "running" => "active".to_string(),
        "completed" => "done".to_string(),
        "interrupted" => "halted".to_string(),
        "failed" => "error".to_string(),
        _ => "idle".to_string(),
    }
}

pub(super) fn current_timestamp_string() -> String {
    let now = current_unix_epoch_millis() as i64;
    unix_timestamp_to_iso8601(now)
}

pub(super) fn current_unix_epoch_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

pub(super) fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
    let millis = if timestamp.abs() >= 1_000_000_000_000 {
        timestamp
    } else {
        timestamp.saturating_mul(1000)
    };

    Utc.timestamp_millis_opt(millis)
        .single()
        .map(|datetime| datetime.to_rfc3339_opts(SecondsFormat::Millis, true))
        .unwrap_or_else(|| timestamp.to_string())
}

fn is_hidden_archive_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("<turn_aborted>")
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use shared_contracts::{BridgeEventKind, ThreadTimelineExplorationKind};

    use super::{
        map_thread_summary, payload_contains_hidden_message, summarize_live_payload,
        timeline_annotations_for_event,
    };
    use crate::thread_api::UpstreamThreadRecord;

    #[test]
    fn hidden_payload_detection_stays_consistent() {
        assert!(payload_contains_hidden_message(&json!({
            "text": "# AGENTS.md instructions for /repo"
        })));
        assert!(!payload_contains_hidden_message(&json!({
            "text": "normal text"
        })));
    }

    #[test]
    fn exploration_annotations_detect_read_commands() {
        let annotations = timeline_annotations_for_event(
            "turn-1-item-1",
            BridgeEventKind::CommandDelta,
            &json!({
                "id": "item-1",
                "command": "sed -n '1,20p' src/lib.rs"
            }),
        )
        .expect("annotations should exist");

        assert_eq!(
            annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Read)
        );
    }

    #[test]
    fn summary_mapping_preserves_thread_identity() {
        let summary = map_thread_summary(&UpstreamThreadRecord {
            id: "thread-1".to_string(),
            headline: "Title".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/repo".to_string(),
            repository_name: "repo".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-01-01T00:00:00Z".to_string(),
            updated_at: "2026-01-01T00:00:01Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: summarize_live_payload(
                BridgeEventKind::MessageDelta,
                &json!({"text": "hello"}),
            ),
        });

        assert_eq!(summary.thread_id, "thread-1");
        assert_eq!(summary.title, "Title");
    }
}
