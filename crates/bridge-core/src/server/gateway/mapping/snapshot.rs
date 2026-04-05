use super::super::codex::normalize_generated_thread_title;
use super::super::*;
use std::collections::HashMap;
use super::timeline::{
    normalize_codex_item_payload, payload_contains_hidden_message, payload_primary_text,
    summarize_live_payload, timeline_annotations_for_event,
};

pub(crate) fn is_placeholder_thread_title(title: &str) -> bool {
    let normalized = title.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "untitled thread"
        || normalized == "new thread"
        || normalized == "fresh session"
}

pub(crate) fn extract_generated_thread_title(agent_message: Option<&str>) -> Option<String> {
    let agent_message = agent_message?.trim();
    if agent_message.is_empty() {
        return None;
    }

    let parsed = serde_json::from_str::<Value>(agent_message).ok();
    let raw_title = parsed
        .as_ref()
        .and_then(|value| value.get("title"))
        .and_then(Value::as_str)
        .unwrap_or(agent_message);
    normalize_generated_thread_title(raw_title)
}

pub(crate) fn map_thread_summary(thread: CodexThread) -> ThreadSummaryDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .and_then(|git| git.branch)
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();

    ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: format!("codex:{}", thread.id),
        native_thread_id: thread.id,
        provider: ProviderKind::Codex,
        client: map_thread_client_kind_from_source(thread.source.as_str().unwrap_or("unknown")),
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd,
        repository,
        branch,
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
    }
}

pub(crate) fn map_thread_snapshot(thread: CodexThread) -> ThreadSnapshotDto {
    let detail = map_thread_detail(&thread);
    let pending_user_input = pending_user_input_from_thread(&thread);
    let entries = {
        let rpc_entries = map_thread_timeline_entries(&thread);
        let archive_entries = thread
            .path
            .as_deref()
            .map(Path::new)
            .filter(|path| path.is_absolute() && path.exists())
            .map(|path| load_archive_timeline_entries_for_session_path(&thread.id, path))
            .unwrap_or_else(|| load_archive_timeline_entries_for_thread(&thread.id));
        merge_rpc_and_archive_timeline_entries(rpc_entries, archive_entries)
    };
    let git_status = Some(map_git_status(&thread));

    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail,
        entries,
        approvals: Vec::<ApprovalSummaryDto>::new(),
        git_status,
        pending_user_input,
    }
}

fn pending_user_input_from_thread(thread: &CodexThread) -> Option<PendingUserInputDto> {
    for turn in thread.turns.iter().rev() {
        for item in turn.items.iter().rev() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
                continue;
            };
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&payload) {
                let Some(message_text) = payload_primary_text(&payload) else {
                    continue;
                };
                if let Some(questionnaire) =
                    parse_pending_user_input_payload(message_text, &thread.id)
                {
                    return Some(questionnaire);
                }
                continue;
            }

            return None;
        }
    }

    None
}

pub(crate) fn merge_rpc_and_archive_timeline_entries(
    rpc_entries: Vec<ThreadTimelineEntryDto>,
    archive_entries: Vec<ThreadTimelineEntryDto>,
) -> Vec<ThreadTimelineEntryDto> {
    if rpc_entries.is_empty() {
        return sort_timeline_entries(archive_entries);
    }
    if archive_entries.is_empty() {
        return sort_timeline_entries(rpc_entries);
    }

    let mut merged_by_id = rpc_entries
        .into_iter()
        .map(|entry| (entry.event_id.clone(), entry))
        .collect::<HashMap<_, _>>();

    for archive_entry in archive_entries {
        merged_by_id
            .entry(archive_entry.event_id.clone())
            .and_modify(|rpc_entry| {
                if archive_entry.occurred_at > rpc_entry.occurred_at
                    || (archive_entry.occurred_at == rpc_entry.occurred_at
                        && timeline_entry_score(&archive_entry) >= timeline_entry_score(rpc_entry))
                {
                    *rpc_entry = archive_entry.clone();
                }
            })
            .or_insert(archive_entry);
    }

    sort_timeline_entries(merged_by_id.into_values().collect())
}

fn sort_timeline_entries(mut entries: Vec<ThreadTimelineEntryDto>) -> Vec<ThreadTimelineEntryDto> {
    entries.sort_by(|left, right| {
        left.occurred_at
            .cmp(&right.occurred_at)
            .then_with(|| left.event_id.cmp(&right.event_id))
    });
    entries
}

fn timeline_entry_score(entry: &ThreadTimelineEntryDto) -> usize {
    match entry.kind {
        BridgeEventKind::MessageDelta => 4,
        BridgeEventKind::PlanDelta => 3,
        BridgeEventKind::FileChange | BridgeEventKind::CommandDelta => 2,
        BridgeEventKind::ThreadStatusChanged => 1,
        _ => 0,
    }
}

fn map_thread_detail(thread: &CodexThread) -> ThreadDetailDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .as_ref()
        .and_then(|git| git.branch.clone())
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();
    let active_turn_id = (map_thread_status(&thread.status.kind) == ThreadStatus::Running)
        .then(|| thread.turns.last().map(|turn| turn.id.clone()))
        .flatten();

    ThreadDetailDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: format!("codex:{}", thread.id),
        native_thread_id: thread.id.clone(),
        provider: ProviderKind::Codex,
        client: map_thread_client_kind_from_source(thread.source.as_str().unwrap_or("unknown")),
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd.clone(),
        repository,
        branch,
        created_at: unix_timestamp_to_iso8601(thread.created_at),
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
        source: thread.source.as_str().unwrap_or("unknown").to_string(),
        access_mode: AccessMode::ControlWithApprovals,
        last_turn_summary: thread.preview.clone().unwrap_or_default(),
        active_turn_id,
    }
}

fn map_git_status(thread: &CodexThread) -> GitStatusDto {
    GitStatusDto {
        workspace: thread.cwd.clone(),
        repository: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.as_deref())
            .and_then(parse_repository_name_from_origin)
            .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
            .unwrap_or_else(|| "unknown-repository".to_string()),
        branch: thread
            .git_info
            .as_ref()
            .and_then(|git| git.branch.clone())
            .unwrap_or_else(|| "unknown".to_string()),
        remote: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.clone()),
        dirty: false,
        ahead_by: 0,
        behind_by: 0,
    }
}

fn map_thread_timeline_entries(thread: &CodexThread) -> Vec<ThreadTimelineEntryDto> {
    let mut entries = Vec::new();

    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
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
            let event_id = format!("{}-{item_id}", turn.id);

            entries.push(ThreadTimelineEntryDto {
                event_id: event_id.clone(),
                kind,
                occurred_at: codex_item_occurred_at(item, &turn.id, thread.updated_at),
                summary: summarize_live_payload(kind, &payload),
                annotations: timeline_annotations_for_event(&event_id, kind, &payload),
                payload,
            });
        }
    }

    entries
}

fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
    let millis = if timestamp.abs() >= 1_000_000_000_000 {
        timestamp
    } else {
        timestamp.saturating_mul(1000)
    };

    Utc.timestamp_millis_opt(millis)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn map_thread_status(kind: &str) -> ThreadStatus {
    match kind {
        "idle" => ThreadStatus::Idle,
        "active" => ThreadStatus::Running,
        "systemError" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
}

pub(crate) fn parse_repository_name_from_origin(origin_url: &str) -> Option<String> {
    let trimmed = origin_url.trim().trim_end_matches('/');
    let repository = trimmed
        .rsplit(['/', ':'])
        .next()?
        .trim_end_matches(".git")
        .trim();
    (!repository.is_empty()).then(|| repository.to_string())
}

pub(crate) fn derive_repository_name_from_cwd(cwd: &str) -> Option<String> {
    cwd.rsplit('/')
        .find(|segment| !segment.trim().is_empty())
        .map(|segment| segment.trim().to_string())
}

pub(crate) fn derive_repository_name_from_path(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn codex_item_occurred_at(item: &Value, turn_id: &str, thread_updated_at: i64) -> String {
    codex_timestamp_from_item(item)
        .or_else(|| uuid_v7_timestamp_to_iso8601(turn_id))
        .unwrap_or_else(|| unix_timestamp_to_iso8601(thread_updated_at))
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
        .filter_map(|key| item.get(*key))
        .find_map(value_to_timestamp)
}

fn value_to_timestamp(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else if let Ok(parsed_numeric) = trimmed.parse::<i64>() {
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
