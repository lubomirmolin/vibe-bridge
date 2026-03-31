use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{ProviderKind, ThreadClientKind, ThreadTimelineEntryDto};

use super::patch_diff::resolve_apply_patch_to_unified_diff;
use super::rpc::{CodexRpcClient, read_thread_with_resume, should_resume_thread};
use super::timeline::{
    derive_repository_name_from_cwd, map_codex_thread_to_timeline_events,
    map_codex_thread_to_upstream_record, map_thread_client_kind_from_source, map_timeline_entry,
    map_wire_thread_status_to_lifecycle_state, normalize_custom_tool_output,
    parse_repository_name_from_origin, truncate_summary, unix_timestamp_to_iso8601, value_to_text,
};
use super::{
    ThreadSnapshot, UpstreamThreadRecord, UpstreamTimelineEvent, native_thread_id_for_provider,
    provider_thread_id,
};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct SessionIndexEntry {
    id: String,
    #[serde(rename = "thread_name")]
    thread_name: String,
    updated_at: String,
}

pub(super) fn resolve_codex_home_dir() -> Result<PathBuf, String> {
    if let Some(codex_home) = env::var_os("CODEX_HOME") {
        let path = PathBuf::from(codex_home);
        if !path.as_os_str().is_empty() {
            return Ok(path);
        }
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set; could not resolve Codex state directory".to_string())?;
    Ok(home.join(".codex"))
}

pub(super) fn resolve_claude_home_dir() -> Result<PathBuf, String> {
    if let Some(claude_home) = env::var_os("CLAUDE_HOME") {
        let path = PathBuf::from(claude_home);
        if !path.as_os_str().is_empty() {
            return Ok(path);
        }
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set; could not resolve Claude state directory".to_string())?;
    Ok(home.join(".claude"))
}

pub(super) fn load_thread_snapshot(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    codex_home: &Path,
) -> Result<ThreadSnapshot, String> {
    let rpc_result = load_thread_snapshot_from_codex_rpc(command, args, endpoint);
    let codex_archive_result = match &rpc_result {
        Ok((thread_records, _)) if !thread_records.is_empty() => {
            let requested_ids = thread_records
                .iter()
                .map(|record| record.id.clone())
                .collect::<HashSet<_>>();
            load_thread_snapshot_from_codex_archive_for_ids(codex_home, Some(&requested_ids))
        }
        _ => load_thread_snapshot_from_codex_archive(codex_home),
    };
    let claude_archive_result = resolve_claude_home_dir()
        .map(|claude_home| load_thread_snapshot_from_claude_archive_for_ids(&claude_home, None))
        .unwrap_or_else(|_| Ok((Vec::new(), HashMap::new())));
    let archive_result =
        merge_archive_provider_results(codex_archive_result, claude_archive_result);
    match (rpc_result, archive_result) {
        (Ok(rpc_snapshot), Ok(archive_snapshot)) if !rpc_snapshot.0.is_empty() => {
            Ok(merge_thread_snapshots(rpc_snapshot, archive_snapshot))
        }
        (_, Ok((thread_records, timeline_by_thread_id))) if !thread_records.is_empty() => {
            Ok((thread_records, timeline_by_thread_id))
        }
        (Ok(snapshot), _) => Ok(snapshot),
        (Err(rpc_error), Err(archive_error)) => Err(format!(
            "failed to load Codex threads from app-server ({rpc_error}) and local archive ({archive_error})"
        )),
        (Err(rpc_error), Ok(_)) => Err(format!(
            "failed to load Codex threads from app-server ({rpc_error}) and local archive was empty"
        )),
    }
}

pub(super) fn load_thread_snapshot_for_id(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    codex_home: &Path,
    thread_id: &str,
) -> Result<ThreadSnapshot, String> {
    if native_thread_id_for_provider(thread_id, ProviderKind::ClaudeCode).is_some() {
        let claude_home = resolve_claude_home_dir()
            .map_err(|error| format!("failed to resolve Claude archive directory: {error}"))?;
        let requested_ids = HashSet::from([thread_id.to_string()]);
        return load_thread_snapshot_from_claude_archive_for_ids(
            &claude_home,
            Some(&requested_ids),
        );
    }

    let rpc_result = load_thread_snapshot_from_codex_rpc_for_id(command, args, endpoint, thread_id);
    let requested_ids = HashSet::from([thread_id.to_string()]);
    let archive_result =
        load_thread_snapshot_from_codex_archive_for_ids(codex_home, Some(&requested_ids));

    match (rpc_result, archive_result) {
        (Ok(Some(rpc_snapshot)), Ok(archive_snapshot)) => {
            Ok(merge_thread_snapshots(rpc_snapshot, archive_snapshot))
        }
        (Ok(Some(rpc_snapshot)), _) => Ok(rpc_snapshot),
        (_, Ok((thread_records, timeline_by_thread_id))) if !thread_records.is_empty() => {
            Ok((thread_records, timeline_by_thread_id))
        }
        (Ok(None), _) => Ok((Vec::new(), HashMap::new())),
        (Err(rpc_error), Err(archive_error)) => Err(format!(
            "failed to load Codex thread {thread_id} from app-server ({rpc_error}) and local archive ({archive_error})"
        )),
        (Err(rpc_error), Ok(_)) => Err(format!(
            "failed to load Codex thread {thread_id} from app-server ({rpc_error}) and local archive was empty"
        )),
    }
}

fn merge_archive_provider_results(
    codex_archive_result: Result<ThreadSnapshot, String>,
    claude_archive_result: Result<ThreadSnapshot, String>,
) -> Result<ThreadSnapshot, String> {
    match (codex_archive_result, claude_archive_result) {
        (Ok(codex_snapshot), Ok(claude_snapshot)) => {
            Ok(merge_thread_snapshots(codex_snapshot, claude_snapshot))
        }
        (Ok(snapshot), Err(_)) | (Err(_), Ok(snapshot)) => Ok(snapshot),
        (Err(codex_error), Err(claude_error)) => Err(format!(
            "failed to load provider archives (codex: {codex_error}; claude: {claude_error})"
        )),
    }
}

pub(super) fn merge_thread_snapshots(
    rpc_snapshot: ThreadSnapshot,
    archive_snapshot: ThreadSnapshot,
) -> ThreadSnapshot {
    let (rpc_records, rpc_timeline_by_thread_id) = rpc_snapshot;
    let (archive_records, archive_timeline_by_thread_id) = archive_snapshot;

    let mut merged_records = Vec::with_capacity(rpc_records.len() + archive_records.len());
    let mut merged_timeline_by_thread_id = HashMap::new();
    let mut seen_thread_ids = HashSet::new();
    let mut archive_records_by_id = archive_records
        .into_iter()
        .map(|record| (record.id.clone(), record))
        .collect::<HashMap<_, _>>();

    for rpc_record in rpc_records {
        let thread_id = rpc_record.id.clone();
        seen_thread_ids.insert(thread_id.clone());
        let archive_record = archive_records_by_id.remove(&thread_id);
        let archive_timeline = archive_timeline_by_thread_id
            .get(&thread_id)
            .cloned()
            .unwrap_or_default();
        let merged_timeline = merge_rpc_timeline_with_archive(
            rpc_timeline_by_thread_id
                .get(&thread_id)
                .cloned()
                .unwrap_or_default(),
            archive_timeline,
        );

        let merged_record = merge_detail_record_for_thread(
            rpc_record,
            archive_record.as_ref(),
            &merged_timeline,
            archive_timeline_by_thread_id
                .get(&thread_id)
                .map(Vec::as_slice)
                .unwrap_or(&[]),
        );

        merged_timeline_by_thread_id.insert(thread_id.clone(), merged_timeline);
        merged_records.push(merged_record);
    }

    for (thread_id, mut archive_record) in archive_records_by_id {
        if !seen_thread_ids.insert(thread_id.clone()) {
            continue;
        }

        let archive_timeline = archive_timeline_by_thread_id
            .get(&thread_id)
            .cloned()
            .unwrap_or_default();
        cohere_detail_record_with_timeline(&mut archive_record, &archive_timeline);

        merged_timeline_by_thread_id.insert(thread_id.clone(), archive_timeline);
        merged_records.push(archive_record);
    }

    (merged_records, merged_timeline_by_thread_id)
}

fn merge_rpc_timeline_with_archive(
    rpc_events: Vec<UpstreamTimelineEvent>,
    archive_events: Vec<UpstreamTimelineEvent>,
) -> Vec<UpstreamTimelineEvent> {
    if archive_events.is_empty() {
        return sort_timeline_events(rpc_events);
    }

    let mut merged_events = archive_events;
    let mut fingerprint_to_index = merged_events
        .iter()
        .enumerate()
        .map(|(index, event)| (timeline_merge_fingerprint(event), index))
        .collect::<HashMap<_, _>>();

    for rpc_event in rpc_events {
        let fingerprint = timeline_merge_fingerprint(&rpc_event);
        if let std::collections::hash_map::Entry::Vacant(entry) =
            fingerprint_to_index.entry(fingerprint)
        {
            entry.insert(merged_events.len());
            merged_events.push(rpc_event);
        }
    }

    sort_timeline_events(merged_events)
}

pub(super) fn merge_snapshot_timeline(
    previous_events: &[UpstreamTimelineEvent],
    next_events: &[UpstreamTimelineEvent],
) -> Vec<UpstreamTimelineEvent> {
    let mut merged_events = previous_events.to_vec();

    for next_event in next_events {
        if let Some(existing_index) = merged_events
            .iter()
            .position(|event| event.id == next_event.id)
        {
            merged_events[existing_index] = next_event.clone();
        } else {
            merged_events.push(next_event.clone());
        }
    }

    sort_timeline_events(merged_events)
}

fn sort_timeline_events(mut events: Vec<UpstreamTimelineEvent>) -> Vec<UpstreamTimelineEvent> {
    events.sort_by(|left, right| left.happened_at.cmp(&right.happened_at));
    events
}

fn merge_detail_record_for_thread(
    mut rpc_record: UpstreamThreadRecord,
    archive_record: Option<&UpstreamThreadRecord>,
    merged_timeline: &[UpstreamTimelineEvent],
    archive_timeline: &[UpstreamTimelineEvent],
) -> UpstreamThreadRecord {
    if let Some(archive_record) = archive_record {
        if should_prefer_archive_metadata(&rpc_record, archive_record, archive_timeline) {
            rpc_record.headline = archive_record.headline.clone();
            rpc_record.lifecycle_state = archive_record.lifecycle_state.clone();
            rpc_record.workspace_path = archive_record.workspace_path.clone();
            rpc_record.repository_name = archive_record.repository_name.clone();
            rpc_record.branch_name = archive_record.branch_name.clone();
            rpc_record.remote_name = archive_record.remote_name.clone();
            rpc_record.source = archive_record.source.clone();
        } else {
            backfill_detail_identity_from_archive(&mut rpc_record, archive_record);
            if rpc_record.lifecycle_state == "idle" && archive_record.lifecycle_state != "idle" {
                rpc_record.lifecycle_state = archive_record.lifecycle_state.clone();
            }
        }
    }

    cohere_detail_record_with_timeline(&mut rpc_record, merged_timeline);
    rpc_record
}

fn should_prefer_archive_metadata(
    rpc_record: &UpstreamThreadRecord,
    archive_record: &UpstreamThreadRecord,
    archive_timeline: &[UpstreamTimelineEvent],
) -> bool {
    let archive_freshness = latest_visible_timeline_timestamp(archive_timeline)
        .unwrap_or_else(|| archive_record.updated_at.clone());
    if !archive_freshness.is_empty() && archive_freshness > rpc_record.updated_at {
        return true;
    }

    detail_identity_looks_placeholder(rpc_record)
        && !detail_identity_looks_placeholder(archive_record)
}

fn backfill_detail_identity_from_archive(
    rpc_record: &mut UpstreamThreadRecord,
    archive_record: &UpstreamThreadRecord,
) {
    if is_placeholder_title(&rpc_record.headline) && !is_placeholder_title(&archive_record.headline)
    {
        rpc_record.headline = archive_record.headline.clone();
    }
    if rpc_record.workspace_path.trim().is_empty()
        && !archive_record.workspace_path.trim().is_empty()
    {
        rpc_record.workspace_path = archive_record.workspace_path.clone();
    }
    if is_placeholder_repository(&rpc_record.repository_name)
        && !is_placeholder_repository(&archive_record.repository_name)
    {
        rpc_record.repository_name = archive_record.repository_name.clone();
    }
    if is_placeholder_branch(&rpc_record.branch_name)
        && !is_placeholder_branch(&archive_record.branch_name)
    {
        rpc_record.branch_name = archive_record.branch_name.clone();
    }
    if is_placeholder_source(&rpc_record.source) && !is_placeholder_source(&archive_record.source) {
        rpc_record.source = archive_record.source.clone();
    }
}

fn cohere_detail_record_with_timeline(
    thread_record: &mut UpstreamThreadRecord,
    timeline: &[UpstreamTimelineEvent],
) {
    if let Some(latest_visible_at) = latest_visible_timeline_timestamp(timeline)
        && (thread_record.updated_at.trim().is_empty()
            || latest_visible_at > thread_record.updated_at)
    {
        thread_record.updated_at = latest_visible_at;
    }

    if let Some(summary) = latest_substantive_timeline_summary(timeline) {
        thread_record.last_turn_summary = summary;
    }

    if let Some(lifecycle_state) = latest_timeline_lifecycle_state(timeline) {
        thread_record.lifecycle_state = lifecycle_state;
    }
}

fn latest_visible_timeline_timestamp(timeline: &[UpstreamTimelineEvent]) -> Option<String> {
    timeline
        .iter()
        .filter_map(|event| {
            let timestamp = event.happened_at.trim();
            if timestamp.is_empty() {
                None
            } else {
                Some(timestamp.to_string())
            }
        })
        .max()
}

fn latest_substantive_timeline_summary(timeline: &[UpstreamTimelineEvent]) -> Option<String> {
    timeline.iter().rev().find_map(|event| {
        let summary = event.summary_text.trim();
        if summary.is_empty() {
            return None;
        }
        if event.event_type == "command_output_delta"
            && (summary == "Command completed" || summary.starts_with("Called "))
        {
            return None;
        }
        Some(summary.to_string())
    })
}

fn latest_timeline_lifecycle_state(timeline: &[UpstreamTimelineEvent]) -> Option<String> {
    timeline.iter().rev().find_map(|event| {
        if event.event_type != "thread_status_changed" {
            return None;
        }
        event
            .data
            .get("status")
            .and_then(Value::as_str)
            .map(map_wire_thread_status_to_lifecycle_state)
    })
}

fn detail_identity_looks_placeholder(record: &UpstreamThreadRecord) -> bool {
    is_placeholder_title(&record.headline)
        || record.workspace_path.trim().is_empty()
        || is_placeholder_repository(&record.repository_name)
        || is_placeholder_branch(&record.branch_name)
        || is_placeholder_source(&record.source)
}

fn is_placeholder_title(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.is_empty() || trimmed == "Untitled thread"
}

fn is_placeholder_repository(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.is_empty() || trimmed == "unknown-repository"
}

fn is_placeholder_branch(value: &str) -> bool {
    value.trim().is_empty() || value.trim() == "unknown"
}

fn is_placeholder_source(value: &str) -> bool {
    value.trim().is_empty() || value.trim() == "unknown"
}

fn timeline_event_fingerprint(event: &UpstreamTimelineEvent) -> String {
    let serialized_payload =
        serde_json::to_string(&event.data).unwrap_or_else(|_| event.summary_text.clone());
    format!(
        "{}\u{1f}|{}\u{1f}|{}",
        event.event_type, event.summary_text, serialized_payload
    )
}

fn timeline_merge_fingerprint(event: &UpstreamTimelineEvent) -> String {
    match event.event_type.as_str() {
        "agent_message_delta" => {
            let role = event
                .data
                .get("role")
                .and_then(Value::as_str)
                .or_else(|| event.data.get("source").and_then(Value::as_str))
                .unwrap_or("assistant");
            let text = event
                .data
                .get("delta")
                .and_then(Value::as_str)
                .or_else(|| event.data.get("text").and_then(Value::as_str))
                .or_else(|| event.data.get("message").and_then(Value::as_str))
                .unwrap_or_default()
                .trim();
            format!("agent_message_delta\u{1f}|{role}\u{1f}|{text}")
        }
        "plan_delta" => {
            let text = event
                .data
                .get("delta")
                .and_then(Value::as_str)
                .or_else(|| event.data.get("text").and_then(Value::as_str))
                .unwrap_or(event.summary_text.as_str())
                .trim();
            let steps = event
                .data
                .get("steps")
                .map(|value| canonical_json_string(Some(value)))
                .unwrap_or_default();
            format!("plan_delta\u{1f}|{text}\u{1f}|{steps}")
        }
        "command_output_delta" => {
            let command = normalized_merge_text_value(
                event
                    .data
                    .get("command")
                    .or_else(|| event.data.get("name"))
                    .or_else(|| event.data.get("action")),
            );
            let arguments = canonical_json_string(
                event
                    .data
                    .get("arguments")
                    .or_else(|| event.data.get("input")),
            );
            let output = normalized_merge_text_value(
                event
                    .data
                    .get("output")
                    .or_else(|| event.data.get("aggregatedOutput"))
                    .or_else(|| event.data.get("delta")),
            );
            let summary = normalized_merge_text(&event.summary_text);
            format!(
                "command_output_delta\u{1f}|{}\u{1f}|{command}\u{1f}|{arguments}\u{1f}|{output}\u{1f}|{summary}",
                normalized_merge_timestamp(event)
            )
        }
        "file_change_delta" => {
            let command = normalized_merge_text_value(
                event
                    .data
                    .get("command")
                    .or_else(|| event.data.get("name"))
                    .or_else(|| event.data.get("action")),
            );
            let change = normalized_merge_text_value(
                event
                    .data
                    .get("change")
                    .or_else(|| event.data.get("input"))
                    .or_else(|| event.data.get("patch")),
            );
            let output = normalized_merge_text_value(
                event
                    .data
                    .get("output")
                    .or_else(|| event.data.get("aggregatedOutput")),
            );
            let changes = canonical_json_string(event.data.get("changes"));
            let summary = normalized_merge_text(&event.summary_text);
            format!(
                "file_change_delta\u{1f}|{}\u{1f}|{command}\u{1f}|{change}\u{1f}|{output}\u{1f}|{changes}\u{1f}|{summary}",
                normalized_merge_timestamp(event)
            )
        }
        _ => timeline_event_fingerprint(event),
    }
}

fn normalized_merge_timestamp(event: &UpstreamTimelineEvent) -> String {
    normalized_merge_text(&event.happened_at)
}

fn normalized_merge_text(value: &str) -> String {
    value.trim().to_string()
}

fn normalized_merge_text_value(value: Option<&Value>) -> String {
    value
        .and_then(value_to_text)
        .map(|text| normalized_merge_text(&text))
        .unwrap_or_default()
}

fn canonical_json_string(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    serde_json::to_string(&canonicalize_merge_value(value)).unwrap_or_default()
}

fn canonicalize_merge_value(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut keys = object.keys().cloned().collect::<Vec<_>>();
            keys.sort();

            let mut canonical = serde_json::Map::new();
            for key in keys {
                if let Some(next_value) = object.get(&key) {
                    canonical.insert(key, canonicalize_merge_value(next_value));
                }
            }
            Value::Object(canonical)
        }
        Value::Array(values) => Value::Array(
            values
                .iter()
                .map(canonicalize_merge_value)
                .collect::<Vec<_>>(),
        ),
        Value::String(text) => {
            let trimmed = text.trim();
            if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                canonicalize_merge_value(&parsed)
            } else {
                Value::String(trimmed.to_string())
            }
        }
        other => other.clone(),
    }
}

fn load_thread_snapshot_from_codex_rpc(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
) -> Result<ThreadSnapshot, String> {
    let mut client = CodexRpcClient::start(command, args, endpoint)?;
    let threads = client.fetch_all_threads()?;

    let mut thread_records = Vec::with_capacity(threads.len());
    let mut timeline_by_thread_id = HashMap::new();
    for thread in &threads {
        let record = map_codex_thread_to_upstream_record(thread);
        timeline_by_thread_id.insert(
            record.id.clone(),
            map_codex_thread_to_timeline_events(thread),
        );
        thread_records.push(record);
    }

    Ok((thread_records, timeline_by_thread_id))
}

fn load_thread_snapshot_from_codex_rpc_for_id(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    thread_id: &str,
) -> Result<Option<ThreadSnapshot>, String> {
    let Some(native_thread_id) = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
    else {
        return Ok(None);
    };
    let mut client = CodexRpcClient::start(command, args, endpoint)?;
    let thread = match read_thread_with_resume(&mut client, native_thread_id, true) {
        Ok(thread) => thread,
        Err(error) if should_resume_thread(&error) || error.contains("not found") => {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };

    let thread_record = map_codex_thread_to_upstream_record(&thread);
    let timeline = map_codex_thread_to_timeline_events(&thread);
    let timeline_by_thread_id = HashMap::from([(thread_record.id.clone(), timeline)]);

    Ok(Some((vec![thread_record], timeline_by_thread_id)))
}

pub(super) fn load_thread_snapshot_from_codex_archive(
    codex_home: &Path,
) -> Result<ThreadSnapshot, String> {
    load_thread_snapshot_from_codex_archive_for_ids(codex_home, None)
}

pub(super) fn load_thread_snapshot_from_codex_archive_for_ids(
    codex_home: &Path,
    requested_ids: Option<&HashSet<String>>,
) -> Result<ThreadSnapshot, String> {
    let requested_native_ids = requested_ids.map(|requested_ids| {
        requested_ids
            .iter()
            .filter_map(|thread_id| native_thread_id_for_provider(thread_id, ProviderKind::Codex))
            .map(ToString::to_string)
            .collect::<HashSet<_>>()
    });
    let session_index_path = codex_home.join("session_index.jsonl");
    let sessions_root = codex_home.join("sessions");
    let raw_index = match fs::read_to_string(&session_index_path) {
        Ok(raw_index) => Some(raw_index),
        Err(error) if error.kind() == ErrorKind::NotFound => None,
        Err(error) => {
            return Err(format!(
                "failed to read session index at {}: {error}",
                session_index_path.display()
            ));
        }
    };

    let mut entries = raw_index
        .as_deref()
        .map(|raw_index| {
            raw_index
                .lines()
                .filter(|line| !line.trim().is_empty())
                .map(|line| {
                    serde_json::from_str::<SessionIndexEntry>(line).map_err(|error| {
                        format!("failed to parse session index entry as JSON: {error}")
                    })
                })
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()?
        .unwrap_or_default();

    entries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    if let Some(requested_native_ids) = requested_native_ids.as_ref() {
        entries.retain(|entry| requested_native_ids.contains(&entry.id));

        let indexed_ids = entries
            .iter()
            .map(|entry| entry.id.clone())
            .collect::<HashSet<_>>();
        let missing_ids = requested_native_ids
            .iter()
            .filter(|id| !indexed_ids.contains(*id))
            .cloned()
            .collect::<HashSet<_>>();
        if !missing_ids.is_empty() {
            let fallback_paths = discover_session_paths(&sessions_root, &missing_ids)?;
            for missing_id in missing_ids {
                let Some(path) = fallback_paths.get(&missing_id) else {
                    continue;
                };
                entries.push(synthetic_session_index_entry_for_path(&missing_id, path));
            }
            entries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        }
    } else {
        if entries.is_empty() {
            entries = discover_all_session_entries(&sessions_root)?;
            entries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        }
        entries.truncate(CodexRpcClient::MAX_THREADS_TO_FETCH);
    }

    let requested_ids = entries
        .iter()
        .map(|entry| entry.id.clone())
        .collect::<HashSet<_>>();
    let discovered_paths = discover_session_paths(&sessions_root, &requested_ids)?;

    let mut thread_records = Vec::new();
    let mut timeline_by_thread_id = HashMap::new();
    for entry in entries {
        let parsed = discovered_paths
            .get(&entry.id)
            .and_then(|path| parse_archived_session(path, &entry).ok())
            .unwrap_or_else(|| archived_thread_record_from_index(&entry));

        let thread_id = parsed.0.id.clone();
        thread_records.push(parsed.0);
        timeline_by_thread_id.insert(thread_id, parsed.1);
    }

    Ok((thread_records, timeline_by_thread_id))
}

pub(super) fn load_thread_snapshot_from_claude_archive_for_ids(
    claude_home: &Path,
    requested_ids: Option<&HashSet<String>>,
) -> Result<ThreadSnapshot, String> {
    let projects_root = claude_home.join("projects");
    if !projects_root.exists() {
        return Ok((Vec::new(), HashMap::new()));
    }

    let requested_native_ids = requested_ids.map(|requested_ids| {
        requested_ids
            .iter()
            .filter_map(|thread_id| {
                native_thread_id_for_provider(thread_id, ProviderKind::ClaudeCode)
            })
            .map(ToString::to_string)
            .collect::<HashSet<_>>()
    });

    let mut discovered_paths = Vec::new();
    visit_claude_session_paths(&projects_root, &mut discovered_paths)?;

    let mut parsed_sessions = Vec::new();
    for path in discovered_paths {
        let Some((thread_record, timeline)) = parse_claude_archived_session(&path)? else {
            continue;
        };
        if let Some(requested_native_ids) = requested_native_ids.as_ref()
            && !requested_native_ids.contains(&thread_record.native_id)
        {
            continue;
        }
        parsed_sessions.push((thread_record, timeline));
    }

    parsed_sessions.sort_by(|left, right| right.0.updated_at.cmp(&left.0.updated_at));
    if requested_native_ids.is_none() {
        parsed_sessions.truncate(CodexRpcClient::MAX_THREADS_TO_FETCH);
    }

    let mut thread_records = Vec::with_capacity(parsed_sessions.len());
    let mut timeline_by_thread_id = HashMap::new();
    for (thread_record, timeline) in parsed_sessions {
        let thread_id = thread_record.id.clone();
        thread_records.push(thread_record);
        timeline_by_thread_id.insert(thread_id, timeline);
    }

    Ok((thread_records, timeline_by_thread_id))
}

fn visit_claude_session_paths(
    directory: &Path,
    discovered: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => {
            return Err(format!(
                "failed to enumerate Claude session archive at {}: {error}",
                directory.display()
            ));
        }
    };

    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to inspect Claude session archive entry under {}: {error}",
                directory.display()
            )
        })?;
        let path = entry.path();

        if path.is_dir() {
            if path.file_name().and_then(|value| value.to_str()) == Some("subagents") {
                continue;
            }
            visit_claude_session_paths(&path, discovered)?;
            continue;
        }

        let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if file_name.ends_with(".jsonl") {
            discovered.push(path);
        }
    }

    Ok(())
}

fn parse_claude_archived_session(
    path: &Path,
) -> Result<Option<(UpstreamThreadRecord, Vec<UpstreamTimelineEvent>)>, String> {
    let raw = fs::read_to_string(path).map_err(|error| {
        format!(
            "failed to read Claude archived session {}: {error}",
            path.display()
        )
    })?;

    let fallback_native_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .map(ToString::to_string);
    let mut session_id = None;
    let mut cwd = None;
    let mut branch_name = None;
    let mut source = None;
    let mut custom_title = None;
    let mut ai_title = None;
    let mut created_at = None;
    let mut updated_at = None;
    let mut first_user_message = None;
    let mut last_turn_summary = None;
    let mut timeline = Vec::new();
    let mut visible_message_fingerprints = HashSet::new();
    let mut tool_name_by_id = HashMap::new();
    let mut file_change_tool_ids = HashSet::new();

    for line in raw.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(_) => continue,
        };

        let timestamp = value
            .get("timestamp")
            .and_then(Value::as_str)
            .filter(|timestamp| !timestamp.trim().is_empty())
            .map(ToString::to_string)
            .or_else(|| archive_path_modified_at(path))
            .unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_string());
        if created_at.is_none() {
            created_at = Some(timestamp.clone());
        }
        if updated_at
            .as_ref()
            .map(|current: &String| timestamp > *current)
            .unwrap_or(true)
        {
            updated_at = Some(timestamp.clone());
        }

        session_id = value
            .get("sessionId")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or(session_id);
        cwd = value
            .get("cwd")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or(cwd);
        branch_name = value
            .get("gitBranch")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or(branch_name);
        source = value
            .get("entrypoint")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or(source);
        if value.get("type").and_then(Value::as_str) == Some("custom-title") {
            custom_title = value
                .get("customTitle")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(custom_title);
        } else if value.get("type").and_then(Value::as_str) == Some("ai-title") {
            ai_title = value
                .get("aiTitle")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(ai_title);
        }

        let native_id = session_id
            .clone()
            .or_else(|| fallback_native_id.clone())
            .unwrap_or_default();
        if native_id.trim().is_empty() {
            continue;
        }
        let thread_id = provider_thread_id(ProviderKind::ClaudeCode, &native_id);

        for event in map_claude_message_events(
            &thread_id,
            &timestamp,
            &value,
            cwd.as_deref(),
            &mut tool_name_by_id,
            &mut file_change_tool_ids,
            timeline.len() as u64 + 1,
        ) {
            if first_user_message.is_none()
                && event.event_type == "agent_message_delta"
                && event.data.get("role").and_then(Value::as_str) == Some("user")
            {
                let message = event
                    .data
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim();
                if !message.is_empty() {
                    first_user_message = Some(message.to_string());
                }
            }

            if let Some(fingerprint) = archived_message_fingerprint(&event)
                && !visible_message_fingerprints.insert(fingerprint)
            {
                continue;
            }
            last_turn_summary = Some(event.summary_text.clone());
            timeline.push(event);
        }
    }

    let native_id = session_id.or(fallback_native_id);
    let Some(native_id) = native_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(None);
    };

    let workspace_path = cwd.unwrap_or_default();
    let branch_name = branch_name.unwrap_or_else(|| "unknown".to_string());
    let headline = claude_thread_headline(
        custom_title.as_deref(),
        ai_title.as_deref(),
        first_user_message.as_deref(),
    );
    let created_at = created_at
        .or_else(|| archive_path_modified_at(path))
        .unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_string());
    let updated_at = updated_at
        .or_else(|| archive_path_modified_at(path))
        .unwrap_or_else(|| created_at.clone());

    Ok(Some((
        UpstreamThreadRecord {
            id: provider_thread_id(ProviderKind::ClaudeCode, &native_id),
            native_id,
            provider: ProviderKind::ClaudeCode,
            client: map_thread_client_kind_from_source(source.as_deref().unwrap_or("archive")),
            headline: headline.clone(),
            lifecycle_state: "done".to_string(),
            workspace_path: workspace_path.clone(),
            repository_name: derive_repository_name_from_cwd(&workspace_path)
                .unwrap_or_else(|| "unknown-repository".to_string()),
            branch_name,
            remote_name: "local".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at,
            updated_at,
            source: source.unwrap_or_else(|| "archive".to_string()),
            approval_mode: "read_only".to_string(),
            last_turn_summary: last_turn_summary.unwrap_or(headline),
        },
        timeline,
    )))
}

fn map_claude_message_events(
    thread_id: &str,
    timestamp: &str,
    value: &Value,
    workspace_path: Option<&str>,
    tool_name_by_id: &mut HashMap<String, String>,
    file_change_tool_ids: &mut HashSet<String>,
    sequence_start: u64,
) -> Vec<UpstreamTimelineEvent> {
    let Some(message) = value.get("message") else {
        return Vec::new();
    };
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            value
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("assistant")
        });
    if matches!(role, "developer" | "system") {
        return Vec::new();
    }

    let items = message
        .get("content")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut events = Vec::new();
    let normalized_content = claude_message_content(&items);
    let text = normalized_content
        .iter()
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n\n");
    let has_images = normalized_content
        .iter()
        .any(|item| item.get("type").and_then(Value::as_str) == Some("image"));
    if (!text.trim().is_empty() || has_images) && !is_hidden_archive_message(&text) {
        let source = if role == "user" { "user" } else { "assistant" };
        let item_type = if role == "user" {
            "userMessage"
        } else {
            "agentMessage"
        };
        events.push(UpstreamTimelineEvent {
            id: format!("{thread_id}-claude-{sequence_start}"),
            event_type: "agent_message_delta".to_string(),
            happened_at: timestamp.to_string(),
            summary_text: if text.trim().is_empty() {
                "Attached image".to_string()
            } else {
                truncate_summary(&text)
            },
            data: json!({
                "delta": text,
                "role": role,
                "source": source,
                "type": item_type,
                "content": normalized_content,
            }),
        });
    }

    let mut offset = 1;
    for item in items {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        match item_type {
            "tool_use" => {
                let tool_name = item
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("tool")
                    .to_string();
                let tool_use_id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
                    .unwrap_or_else(|| format!("{thread_id}-tool-{sequence_start}-{offset}"));
                let input = item.get("input").cloned().unwrap_or(Value::Null);
                let input_text = value_to_text(&input).unwrap_or_default();
                let is_file_change = is_claude_file_change_tool(&tool_name)
                    || is_file_change_custom_tool(&tool_name)
                    || is_file_change_text(&input_text);
                tool_name_by_id.insert(tool_use_id.clone(), tool_name.clone());
                if is_file_change {
                    file_change_tool_ids.insert(tool_use_id.clone());
                }

                let mut data = json!({
                    "id": tool_use_id,
                    "command": tool_name,
                });
                if let Some(object) = data.as_object_mut() {
                    if is_file_change {
                        object.insert("change".to_string(), Value::String(input_text.clone()));
                        object.insert("input".to_string(), input.clone());
                        if let Some(resolved_diff) =
                            resolve_apply_patch_to_unified_diff(&input_text, workspace_path)
                        {
                            object.insert(
                                "resolved_unified_diff".to_string(),
                                Value::String(resolved_diff),
                            );
                        }
                    } else {
                        object.insert("arguments".to_string(), input.clone());
                    }
                }

                events.push(UpstreamTimelineEvent {
                    id: format!("{thread_id}-claude-{}", sequence_start + offset),
                    event_type: if is_file_change {
                        "file_change_delta".to_string()
                    } else {
                        "command_output_delta".to_string()
                    },
                    happened_at: timestamp.to_string(),
                    summary_text: if is_file_change {
                        format!("Edited files via {tool_name}")
                    } else {
                        format!("Called {tool_name}")
                    },
                    data,
                });
                offset += 1;
            }
            "tool_result" => {
                let tool_use_id = item
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let tool_name = tool_name_by_id
                    .get(&tool_use_id)
                    .cloned()
                    .unwrap_or_else(|| "tool".to_string());
                let is_file_change = file_change_tool_ids.contains(&tool_use_id);
                let output = normalize_claude_tool_result_output(value, &item);
                let summary = if output.trim().is_empty() {
                    if is_file_change {
                        "File change completed".to_string()
                    } else {
                        "Command completed".to_string()
                    }
                } else {
                    truncate_summary(&output)
                };

                let mut data = json!({
                    "tool_use_id": tool_use_id,
                    "command": tool_name,
                    "output": output,
                });
                if let Some(tool_use_result) = value.get("toolUseResult")
                    && let Some(object) = data.as_object_mut()
                {
                    object.insert("tool_use_result".to_string(), tool_use_result.clone());
                }

                events.push(UpstreamTimelineEvent {
                    id: format!("{thread_id}-claude-{}", sequence_start + offset),
                    event_type: if is_file_change {
                        "file_change_delta".to_string()
                    } else {
                        "command_output_delta".to_string()
                    },
                    happened_at: timestamp.to_string(),
                    summary_text: summary,
                    data,
                });
                offset += 1;
            }
            _ => {}
        }
    }

    events
}

fn claude_message_content(items: &[Value]) -> Vec<Value> {
    let mut content = Vec::new();
    for item in items {
        match item.get("type").and_then(Value::as_str).unwrap_or_default() {
            "text" => {
                let Some(text) = item.get("text").and_then(Value::as_str).map(str::trim) else {
                    continue;
                };
                if text.is_empty() {
                    continue;
                }
                content.push(json!({
                    "type": "text",
                    "text_type": "text",
                    "text": text,
                }));
            }
            "image" | "input_image" => {
                if let Some(image_url) = archived_response_image_url(item) {
                    content.push(json!({
                        "type": "image",
                        "image_url": image_url,
                    }));
                }
            }
            _ => {}
        }
    }
    content
}

fn normalize_claude_tool_result_output(record: &Value, item: &Value) -> String {
    if let Some(tool_use_result) = record.get("toolUseResult") {
        if let Some(stdout) = tool_use_result.get("stdout").and_then(Value::as_str) {
            let stderr = tool_use_result
                .get("stderr")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let combined = [stdout.trim_end(), stderr.trim_end()]
                .into_iter()
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            if !combined.is_empty() {
                return combined;
            }
        }
        if let Some(content) = tool_use_result.get("content") {
            let text = value_to_text(content).unwrap_or_default();
            if !text.trim().is_empty() {
                return text;
            }
        }
    }

    match item.get("content") {
        Some(Value::String(text)) => text.to_string(),
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(|value| {
                value.as_str().map(ToString::to_string).or_else(|| {
                    value
                        .get("text")
                        .and_then(Value::as_str)
                        .map(ToString::to_string)
                })
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Some(value) => value_to_text(value).unwrap_or_default(),
        None => String::new(),
    }
}

fn is_claude_file_change_tool(tool_name: &str) -> bool {
    matches!(
        tool_name.trim().to_ascii_lowercase().as_str(),
        "edit" | "write" | "multiedit" | "notebookedit"
    )
}

fn claude_thread_headline(
    custom_title: Option<&str>,
    ai_title: Option<&str>,
    first_user_message: Option<&str>,
) -> String {
    if let Some(custom_title) = custom_title
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return truncate_summary(custom_title);
    }

    if let Some(ai_title) = ai_title.map(str::trim).filter(|value| !value.is_empty()) {
        return truncate_summary(ai_title);
    }

    if let Some(first_user_message) = first_user_message
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return truncate_summary(first_user_message);
    }

    "Untitled thread".to_string()
}

fn discover_all_session_entries(sessions_root: &Path) -> Result<Vec<SessionIndexEntry>, String> {
    let mut discovered_paths = Vec::new();
    visit_all_session_paths(sessions_root, &mut discovered_paths)?;

    let mut entries = discovered_paths
        .into_iter()
        .filter_map(|path| synthetic_session_index_entry_for_archive(&path))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(entries)
}

fn synthetic_session_index_entry_for_path(session_id: &str, path: &Path) -> SessionIndexEntry {
    let updated_at = session_meta_timestamp_from_archive(path).unwrap_or_else(|| {
        archive_path_modified_at(path).unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_string())
    });
    SessionIndexEntry {
        id: session_id.to_string(),
        thread_name: "Untitled thread".to_string(),
        updated_at,
    }
}

fn synthetic_session_index_entry_for_archive(path: &Path) -> Option<SessionIndexEntry> {
    let session_id = session_id_from_archive(path)?;
    Some(synthetic_session_index_entry_for_path(&session_id, path))
}

fn session_id_from_archive(path: &Path) -> Option<String> {
    let raw = fs::read_to_string(path).ok()?;
    for line in raw.lines().filter(|line| !line.trim().is_empty()) {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("session_meta") {
            continue;
        }

        if let Some(session_id) = value
            .get("payload")
            .and_then(|payload| payload.get("id"))
            .and_then(Value::as_str)
            .filter(|session_id| !session_id.trim().is_empty())
        {
            return Some(session_id.to_string());
        }
    }
    None
}

fn session_meta_timestamp_from_archive(path: &Path) -> Option<String> {
    let raw = fs::read_to_string(path).ok()?;
    for line in raw.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("session_meta") {
            continue;
        }

        if let Some(timestamp) = value
            .get("payload")
            .and_then(|payload| payload.get("timestamp"))
            .and_then(Value::as_str)
            .filter(|timestamp| !timestamp.trim().is_empty())
        {
            return Some(timestamp.to_string());
        }

        if let Some(timestamp) = value
            .get("timestamp")
            .and_then(Value::as_str)
            .filter(|timestamp| !timestamp.trim().is_empty())
        {
            return Some(timestamp.to_string());
        }
    }
    None
}

fn archive_path_modified_at(path: &Path) -> Option<String> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| unix_timestamp_to_iso8601(duration.as_millis() as i64))
}

fn discover_session_paths(
    root: &Path,
    requested_ids: &HashSet<String>,
) -> Result<HashMap<String, PathBuf>, String> {
    let mut discovered = HashMap::new();
    visit_session_tree(root, requested_ids, &mut discovered)?;
    Ok(discovered)
}

fn visit_session_tree(
    directory: &Path,
    requested_ids: &HashSet<String>,
    discovered: &mut HashMap<String, PathBuf>,
) -> Result<(), String> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => {
            return Err(format!(
                "failed to enumerate session archive at {}: {error}",
                directory.display()
            ));
        }
    };

    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to inspect session archive entry under {}: {error}",
                directory.display()
            )
        })?;
        let path = entry.path();

        if path.is_dir() {
            visit_session_tree(&path, requested_ids, discovered)?;
            continue;
        }

        let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if !file_name.ends_with(".jsonl") {
            continue;
        }

        for session_id in requested_ids {
            if file_name.contains(session_id) {
                discovered.entry(session_id.clone()).or_insert(path.clone());
            }
        }

        if discovered.len() == requested_ids.len() {
            break;
        }
    }

    Ok(())
}

fn visit_all_session_paths(directory: &Path, discovered: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => {
            return Err(format!(
                "failed to enumerate session archive at {}: {error}",
                directory.display()
            ));
        }
    };

    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to inspect session archive entry under {}: {error}",
                directory.display()
            )
        })?;
        let path = entry.path();

        if path.is_dir() {
            visit_all_session_paths(&path, discovered)?;
            continue;
        }

        let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if file_name.ends_with(".jsonl") {
            discovered.push(path);
        }
    }

    Ok(())
}

fn parse_archived_session(
    path: &Path,
    index_entry: &SessionIndexEntry,
) -> Result<(UpstreamThreadRecord, Vec<UpstreamTimelineEvent>), String> {
    let raw = fs::read_to_string(path).map_err(|error| {
        format!(
            "failed to read archived session {}: {error}",
            path.display()
        )
    })?;

    let mut cwd: Option<String> = None;
    let mut branch_name: Option<String> = None;
    let mut repository_url: Option<String> = None;
    let mut created_at: Option<String> = None;
    let mut source: Option<String> = None;
    let mut timeline = Vec::new();
    let mut last_turn_summary: Option<String> = None;
    let mut visible_message_fingerprints = HashSet::new();
    let thread_id = provider_thread_id(ProviderKind::Codex, &index_entry.id);

    for line in raw.lines().filter(|line| !line.trim().is_empty()) {
        let value: Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(_) => continue,
        };

        let timestamp = value
            .get("timestamp")
            .and_then(Value::as_str)
            .unwrap_or(&index_entry.updated_at)
            .to_string();
        let record_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let payload = value.get("payload").cloned().unwrap_or(Value::Null);

        if record_type == "session_meta" {
            if created_at.is_none() {
                created_at = payload
                    .get("timestamp")
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
                    .or_else(|| Some(timestamp.clone()));
            }
            cwd = payload
                .get("cwd")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(cwd);
            branch_name = payload
                .get("git")
                .and_then(|git| git.get("branch"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(branch_name);
            repository_url = payload
                .get("git")
                .and_then(|git| git.get("repository_url"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(repository_url);
            source = payload
                .get("source")
                .or_else(|| payload.get("originator"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .or(source);
            continue;
        }

        if let Some(event) = map_archived_session_event(
            &thread_id,
            &timestamp,
            record_type,
            &payload,
            timeline.len() as u64 + 1,
            cwd.as_deref(),
        ) {
            if let Some(fingerprint) = archived_message_fingerprint(&event)
                && !visible_message_fingerprints.insert(fingerprint)
            {
                continue;
            }
            last_turn_summary = Some(event.summary_text.clone());
            timeline.push(event);
        }
    }

    let workspace_path = cwd.unwrap_or_default();
    let repository_name = repository_url
        .as_deref()
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&workspace_path))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch_name = branch_name.unwrap_or_else(|| "unknown".to_string());
    let remote_name = if repository_url.is_some() {
        "origin".to_string()
    } else {
        "local".to_string()
    };

    Ok((
        UpstreamThreadRecord {
            id: provider_thread_id(ProviderKind::Codex, &index_entry.id),
            native_id: index_entry.id.clone(),
            provider: ProviderKind::Codex,
            client: map_thread_client_kind_from_source(source.as_deref().unwrap_or("archive")),
            headline: index_entry.thread_name.clone(),
            lifecycle_state: "done".to_string(),
            workspace_path,
            repository_name,
            branch_name,
            remote_name,
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: created_at.unwrap_or_else(|| index_entry.updated_at.clone()),
            updated_at: index_entry.updated_at.clone(),
            source: source.unwrap_or_else(|| "archive".to_string()),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: last_turn_summary.unwrap_or_else(|| index_entry.thread_name.clone()),
        },
        timeline,
    ))
}

fn archived_thread_record_from_index(
    index_entry: &SessionIndexEntry,
) -> (UpstreamThreadRecord, Vec<UpstreamTimelineEvent>) {
    (
        UpstreamThreadRecord {
            id: provider_thread_id(ProviderKind::Codex, &index_entry.id),
            native_id: index_entry.id.clone(),
            provider: ProviderKind::Codex,
            client: ThreadClientKind::Archive,
            headline: index_entry.thread_name.clone(),
            lifecycle_state: "done".to_string(),
            workspace_path: String::new(),
            repository_name: "unknown-repository".to_string(),
            branch_name: "unknown".to_string(),
            remote_name: "local".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: index_entry.updated_at.clone(),
            updated_at: index_entry.updated_at.clone(),
            source: "archive".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: index_entry.thread_name.clone(),
        },
        Vec::new(),
    )
}

fn map_archived_session_event(
    thread_id: &str,
    timestamp: &str,
    record_type: &str,
    payload: &Value,
    sequence: u64,
    workspace_path: Option<&str>,
) -> Option<UpstreamTimelineEvent> {
    match record_type {
        "event_msg" => {
            let payload_type = payload
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match payload_type {
                "user_message" => {
                    let message = payload.get("message").and_then(Value::as_str)?.trim();
                    let content = archived_event_message_content(
                        payload,
                        Some(message),
                        "input_text",
                        "images",
                    );
                    let has_images = content
                        .iter()
                        .any(|item| item.get("type").and_then(Value::as_str) == Some("image"));
                    if (message.is_empty() && !has_images) || is_hidden_archive_message(message) {
                        return None;
                    }
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: if message.is_empty() {
                            "Attached image".to_string()
                        } else {
                            truncate_summary(message)
                        },
                        data: json!({
                            "delta": message,
                            "role": "user",
                            "source": "user",
                            "type": "userMessage",
                            "content": content,
                        }),
                    })
                }
                "agent_message" => {
                    let message = payload.get("message").and_then(Value::as_str)?.trim();
                    if message.is_empty() || is_hidden_archive_message(message) {
                        return None;
                    }
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: if message.is_empty() {
                            "Attached image".to_string()
                        } else {
                            truncate_summary(message)
                        },
                        data: json!({
                            "delta": message,
                            "role": "assistant",
                            "source": "assistant",
                            "type": "agentMessage",
                            "content": archived_text_content(message, "output_text"),
                        }),
                    })
                }
                "agent_reasoning" => {
                    let text = payload.get("text").and_then(Value::as_str)?.trim();
                    if text.is_empty() {
                        return None;
                    }
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "plan_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: truncate_summary(text),
                        data: json!({ "delta": text }),
                    })
                }
                _ => None,
            }
        }
        "response_item" => {
            let payload_type = payload
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match payload_type {
                "function_call" => {
                    let name = payload
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("command");
                    if name == "update_plan"
                        && let Some(plan_data) =
                            normalize_archived_update_plan_payload(payload.get("arguments"))
                    {
                        let summary = plan_data
                            .get("text")
                            .and_then(Value::as_str)
                            .map(truncate_summary)
                            .unwrap_or_else(|| "Plan updated".to_string());
                        return Some(UpstreamTimelineEvent {
                            id: format!("{thread_id}-archive-{sequence}"),
                            event_type: "plan_delta".to_string(),
                            happened_at: timestamp.to_string(),
                            summary_text: summary,
                            data: plan_data,
                        });
                    }
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "command_output_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: format!("Called {name}"),
                        data: json!({
                            "command": name,
                            "arguments": payload.get("arguments").cloned().unwrap_or(Value::Null),
                        }),
                    })
                }
                "function_call_output" => {
                    let output = payload
                        .get("output")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let summary = if output.trim().is_empty() {
                        "Command completed".to_string()
                    } else {
                        truncate_summary(output)
                    };
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "command_output_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: summary,
                        data: payload.clone(),
                    })
                }
                "custom_tool_call" => {
                    let tool_name = payload
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("custom_tool");
                    if tool_name == "update_plan"
                        && let Some(plan_data) =
                            normalize_archived_update_plan_payload(payload.get("input"))
                    {
                        let summary = plan_data
                            .get("text")
                            .and_then(Value::as_str)
                            .map(truncate_summary)
                            .unwrap_or_else(|| "Plan updated".to_string());
                        return Some(UpstreamTimelineEvent {
                            id: format!("{thread_id}-archive-{sequence}"),
                            event_type: "plan_delta".to_string(),
                            happened_at: timestamp.to_string(),
                            summary_text: summary,
                            data: plan_data,
                        });
                    }
                    let input = payload.get("input").cloned().unwrap_or(Value::Null);
                    let input_text = value_to_text(&input).unwrap_or_default();
                    let is_file_change =
                        is_file_change_custom_tool(tool_name) || is_file_change_text(&input_text);

                    let mut data = payload.clone();
                    if let Some(object) = data.as_object_mut() {
                        if is_file_change {
                            object.insert("change".to_string(), Value::String(input_text.clone()));
                            if let Some(resolved_diff) =
                                resolve_apply_patch_to_unified_diff(&input_text, workspace_path)
                            {
                                object.insert(
                                    "resolved_unified_diff".to_string(),
                                    Value::String(resolved_diff),
                                );
                            }
                        } else {
                            object.insert("arguments".to_string(), input.clone());
                        }
                    }

                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: if is_file_change {
                            "file_change_delta".to_string()
                        } else {
                            "command_output_delta".to_string()
                        },
                        happened_at: timestamp.to_string(),
                        summary_text: if is_file_change {
                            format!("Edited files via {tool_name}")
                        } else {
                            format!("Called {tool_name}")
                        },
                        data,
                    })
                }
                "custom_tool_call_output" => {
                    let output = payload
                        .get("output")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let normalized_output = normalize_custom_tool_output(output);
                    let is_file_change = is_file_change_text(&normalized_output);
                    let summary = if normalized_output.trim().is_empty() {
                        if is_file_change {
                            "File change completed".to_string()
                        } else {
                            "Command completed".to_string()
                        }
                    } else {
                        truncate_summary(&normalized_output)
                    };

                    let mut data = payload.clone();
                    if let Some(object) = data.as_object_mut() {
                        object.insert("output".to_string(), Value::String(normalized_output));
                    }

                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: if is_file_change {
                            "file_change_delta".to_string()
                        } else {
                            "command_output_delta".to_string()
                        },
                        happened_at: timestamp.to_string(),
                        summary_text: summary,
                        data,
                    })
                }
                "message" => {
                    let role = payload
                        .get("role")
                        .and_then(Value::as_str)
                        .unwrap_or("assistant");
                    if matches!(role, "developer" | "system") {
                        return None;
                    }

                    let content = archived_response_message_content(payload);
                    let message = content
                        .iter()
                        .find_map(|item| item.get("text").and_then(Value::as_str))
                        .map(str::trim)
                        .unwrap_or_default();
                    let has_images = content
                        .iter()
                        .any(|item| item.get("type").and_then(Value::as_str) == Some("image"));
                    if (message.is_empty() && !has_images)
                        || (!message.is_empty() && is_hidden_archive_message(message))
                    {
                        return None;
                    }

                    let (source, item_type) = if role == "user" {
                        ("user", "userMessage")
                    } else {
                        ("assistant", "agentMessage")
                    };

                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: truncate_summary(message),
                        data: json!({
                            "delta": message,
                            "role": role,
                            "source": source,
                            "type": item_type,
                            "content": content,
                        }),
                    })
                }
                "reasoning" => {
                    let summary = payload
                        .get("summary")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .find_map(|item| item.get("text").and_then(Value::as_str))
                        .map(str::trim)
                        .filter(|text| !text.is_empty())?;
                    Some(UpstreamTimelineEvent {
                        id: format!("{thread_id}-archive-{sequence}"),
                        event_type: "plan_delta".to_string(),
                        happened_at: timestamp.to_string(),
                        summary_text: truncate_summary(summary),
                        data: json!({ "delta": summary }),
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

fn normalize_archived_update_plan_payload(input: Option<&Value>) -> Option<Value> {
    let plan_input = match input? {
        Value::String(text) => serde_json::from_str::<Value>(text).ok()?,
        Value::Object(_) => input.cloned()?,
        _ => return None,
    };
    let steps = plan_input
        .get("plan")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let step = entry
                .get("step")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?;
            let status = entry
                .get("status")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("pending");
            Some(json!({
                "step": step,
                "status": status,
            }))
        })
        .collect::<Vec<_>>();
    let explanation = plan_input
        .get("explanation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if steps.is_empty() && explanation.is_none() {
        return None;
    }

    let total_count = steps.len();
    let completed_count = steps
        .iter()
        .filter(|step| step.get("status").and_then(Value::as_str) == Some("completed"))
        .count();
    let text = render_archived_update_plan_text(
        explanation.as_deref(),
        &steps,
        completed_count,
        total_count,
    );

    let mut payload = json!({
        "type": "plan",
        "text": text,
    });
    if let Some(object) = payload.as_object_mut() {
        if let Some(explanation) = explanation {
            object.insert("explanation".to_string(), Value::String(explanation));
        }
        if !steps.is_empty() {
            object.insert("steps".to_string(), Value::Array(steps));
            object.insert("completed_count".to_string(), json!(completed_count));
            object.insert("total_count".to_string(), json!(total_count));
        }
    }

    Some(payload)
}

fn render_archived_update_plan_text(
    explanation: Option<&str>,
    steps: &[Value],
    completed_count: usize,
    total_count: usize,
) -> String {
    if total_count == 0 {
        return explanation.unwrap_or_default().to_string();
    }

    let task_label = if total_count == 1 { "task" } else { "tasks" };
    let mut lines = vec![format!(
        "{completed_count} out of {total_count} {task_label} completed"
    )];
    lines.extend(steps.iter().enumerate().filter_map(|(index, step)| {
        step.get("step")
            .and_then(Value::as_str)
            .map(|value| format!("{}. {value}", index + 1))
    }));
    lines.join("\n")
}

pub(super) fn is_file_change_custom_tool(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "apply_patch" | "replace_file_content" | "multi_replace_file_content"
    ) || tool_name.contains("edit_file")
}

fn archived_text_content(message: &str, text_type: &str) -> Vec<Value> {
    if message.trim().is_empty() {
        Vec::new()
    } else {
        vec![json!({
            "type": "text",
            "text_type": text_type,
            "text": message,
        })]
    }
}

fn archived_event_message_content(
    payload: &Value,
    message: Option<&str>,
    text_type: &str,
    images_key: &str,
) -> Vec<Value> {
    let mut content = archived_text_content(message.unwrap_or_default(), text_type);

    if let Some(images) = payload.get(images_key).and_then(Value::as_array) {
        for image in images.iter().filter_map(Value::as_str) {
            if image.trim().is_empty() {
                continue;
            }
            content.push(json!({
                "type": "image",
                "image_url": image,
            }));
        }
    }

    if let Some(images) = payload.get("local_images").and_then(Value::as_array) {
        for image in images.iter().filter_map(Value::as_str) {
            if image.trim().is_empty() {
                continue;
            }
            content.push(json!({
                "type": "image",
                "image_url": image,
            }));
        }
    }

    content
}

fn archived_response_message_content(payload: &Value) -> Vec<Value> {
    let mut content = Vec::new();
    let Some(items) = payload.get("content").and_then(Value::as_array) else {
        return content;
    };

    for item in items {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        match item_type {
            "input_text" | "output_text" | "text" => {
                if let Some(text) = item.get("text").and_then(Value::as_str)
                    && !text.trim().is_empty()
                {
                    content.push(json!({
                        "type": "text",
                        "text_type": item_type,
                        "text": text,
                    }));
                }
            }
            "input_image" | "image" => {
                if let Some(image_url) = archived_response_image_url(item)
                    && !image_url.trim().is_empty()
                {
                    content.push(json!({
                        "type": "image",
                        "image_url": image_url,
                    }));
                }
            }
            _ => {}
        }
    }

    content
}

fn archived_response_image_url(item: &Value) -> Option<String> {
    if let Some(image_url) = item.get("image_url").and_then(Value::as_str) {
        let trimmed = image_url.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }

    let source = item.get("source")?;
    if source.get("type").and_then(Value::as_str) != Some("base64") {
        return None;
    }
    let media_type = source
        .get("media_type")
        .or_else(|| source.get("mediaType"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let data = source
        .get("data")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;

    Some(format!("data:{media_type};base64,{data}"))
}

pub(super) fn is_file_change_text(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }

    text.contains("Updated the following files:")
        || text.contains("*** Begin Patch")
        || text.contains("*** Update File:")
        || text.contains("*** Add File:")
        || text.contains("[diff_block_start]")
        || text.contains("diff --git ")
        || text.lines().any(|line| {
            line.trim_start()
                .starts_with(['M', 'A', 'D', 'R', 'C', '?'])
        })
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

fn archived_message_fingerprint(event: &UpstreamTimelineEvent) -> Option<String> {
    if event.event_type != "agent_message_delta" {
        return None;
    }

    let role = event
        .data
        .get("role")
        .and_then(Value::as_str)
        .or_else(|| event.data.get("source").and_then(Value::as_str))
        .unwrap_or("assistant");
    let message = event.data.get("delta").and_then(Value::as_str)?.trim();
    if message.is_empty() {
        return None;
    }

    Some(format!("{role}:{message}"))
}

pub(crate) fn load_archive_timeline_entries_for_thread(
    thread_id: &str,
) -> Vec<ThreadTimelineEntryDto> {
    let codex_home = resolve_codex_home_dir().unwrap_or_else(|_| PathBuf::from(".codex"));

    let normalized_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .map(|native_id| provider_thread_id(ProviderKind::Codex, native_id))
        .unwrap_or_else(|| thread_id.to_string());
    let Ok((_, mut timeline_by_thread_id)) = load_thread_snapshot_for_id(
        "definitely-missing-codex",
        &["app-server".to_string()],
        None,
        &codex_home,
        &normalized_thread_id,
    ) else {
        return Vec::new();
    };

    timeline_by_thread_id
        .remove(&normalized_thread_id)
        .unwrap_or_default()
        .into_iter()
        .map(|event| map_timeline_entry(&event))
        .collect()
}

pub(crate) fn load_archive_timeline_entries_for_session_path(
    thread_id: &str,
    session_path: &Path,
) -> Vec<ThreadTimelineEntryDto> {
    let index_entry = SessionIndexEntry {
        id: thread_id.to_string(),
        thread_name: "Untitled thread".to_string(),
        updated_at: session_meta_timestamp_from_archive(session_path)
            .or_else(|| archive_path_modified_at(session_path))
            .unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_string()),
    };

    parse_archived_session(session_path, &index_entry)
        .map(|(_, timeline)| {
            timeline
                .into_iter()
                .map(|event| map_timeline_entry(&event))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{is_file_change_custom_tool, is_file_change_text};

    #[test]
    fn file_change_detection_covers_patch_and_tool_names() {
        assert!(is_file_change_custom_tool("apply_patch"));
        assert!(is_file_change_text(
            "*** Begin Patch\n*** Update File: src/lib.rs"
        ));
        assert!(!is_file_change_text("plain text output"));
    }
}
