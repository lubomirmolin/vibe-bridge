use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{SecondsFormat, TimeZone, Utc};
use serde_json::Value;
use shared_contracts::{
    BridgeEventEnvelope, BridgeEventKind, ThreadTimelineAnnotationsDto,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
};

pub(crate) fn build_timeline_event_envelope(
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

pub(crate) fn current_timestamp_string() -> String {
    let now = current_unix_epoch_millis() as i64;
    unix_timestamp_to_iso8601(now)
}

pub(crate) fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::ThreadMetadataChanged => payload
            .get("workflow_state")
            .and_then(Value::as_object)
            .and_then(|workflow| workflow.get("state"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::UserInputRequested => payload
            .get("title")
            .or_else(|| payload.get("detail"))
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

pub(crate) fn timeline_annotations_for_event(
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

pub(crate) fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
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

fn current_unix_epoch_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
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
    extract_shell_like_command_with_depth(value, 0)
}

fn extract_shell_like_command_with_depth(value: &Value, depth: usize) -> Option<String> {
    if depth >= 8 {
        return None;
    }

    match value {
        Value::Null => None,
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }

            if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                return match parsed {
                    Value::Null | Value::Bool(_) | Value::Number(_) => {
                        parse_background_command(trimmed).or_else(|| Some(trimmed.to_string()))
                    }
                    other => extract_shell_like_command_with_depth(&other, depth + 1)
                        .or_else(|| parse_background_command(trimmed)),
                };
            }

            parse_background_command(trimmed).or_else(|| Some(trimmed.to_string()))
        }
        Value::Object(object) => object
            .get("cmd")
            .or_else(|| object.get("command"))
            .or_else(|| object.get("action"))
            .and_then(|value| extract_shell_like_command_with_depth(value, depth + 1))
            .or_else(|| {
                object
                    .get("input")
                    .and_then(|value| extract_shell_like_command_with_depth(value, depth + 1))
            })
            .or_else(|| {
                object
                    .get("arguments")
                    .and_then(|value| extract_shell_like_command_with_depth(value, depth + 1))
            }),
        Value::Array(values) => extract_shell_like_command_from_array(values).or_else(|| {
            values
                .iter()
                .find_map(|value| extract_shell_like_command_with_depth(value, depth + 1))
        }),
        Value::Bool(_) | Value::Number(_) => Some(value.to_string()),
    }
}

fn parse_background_command(raw: &str) -> Option<String> {
    raw.lines()
        .find_map(|line| line.strip_prefix("Command:"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn extract_shell_like_command_from_array(values: &[Value]) -> Option<String> {
    let parts = values
        .iter()
        .map(|value| value.as_str().map(str::trim))
        .collect::<Option<Vec<_>>>()?;

    if parts.is_empty() {
        return None;
    }

    if matches!(parts.first(), Some(&"bash" | &"sh" | &"zsh" | &"fish"))
        && let Some(index) = parts.iter().position(|part| matches!(*part, "-c" | "-lc"))
        && let Some(command) = parts.get(index + 1)
    {
        return (!command.is_empty()).then(|| (*command).to_string());
    }

    Some(parts.join(" "))
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
