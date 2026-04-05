use super::super::legacy_archive::{
    load_thread_snapshot, load_thread_snapshot_for_id,
    map_thread_detail as map_legacy_thread_detail, map_thread_summary as map_legacy_thread_summary,
    map_timeline_entry, resolve_codex_home_dir,
};
use super::super::mapping::payload_contains_hidden_message;
use super::super::*;
use super::models::fallback_model_options;
pub(super) fn fetch_thread_summaries(
    transport: &mut CodexJsonTransport,
    config: &BridgeCodexConfig,
) -> Result<Vec<ThreadSummaryDto>, String> {
    match fetch_live_thread_summaries(transport) {
        Ok(summaries) if !summaries.is_empty() => {
            let archive_summaries = fetch_thread_summaries_from_archive(config)?;
            Ok(merge_thread_summaries(summaries, archive_summaries))
        }
        Ok(_) => fetch_thread_summaries_from_archive(config),
        Err(live_error) => {
            let fallback = fetch_thread_summaries_from_archive(config)?;
            if fallback.is_empty() {
                Err(live_error)
            } else {
                Ok(fallback)
            }
        }
    }
}

fn fetch_live_thread_summaries(
    transport: &mut CodexJsonTransport,
) -> Result<Vec<ThreadSummaryDto>, String> {
    let mut summaries = Vec::new();
    let mut cursor: Option<String> = None;

    loop {
        if summaries.len() >= CodexGateway::MAX_THREADS_TO_FETCH {
            break;
        }

        let mut params = serde_json::Map::new();
        if let Some(cursor) = &cursor {
            params.insert("cursor".to_string(), Value::String(cursor.clone()));
        }

        let response = transport.request("thread/list", Value::Object(params))?;
        let payload: CodexThreadListResult = serde_json::from_value(response)
            .map_err(|error| format!("invalid thread/list response from codex: {error}"))?;

        let remaining = CodexGateway::MAX_THREADS_TO_FETCH.saturating_sub(summaries.len());
        summaries.extend(
            payload
                .data
                .into_iter()
                .take(remaining)
                .map(super::super::mapping::map_thread_summary),
        );

        if let Some(next_cursor) = payload.next_cursor {
            cursor = Some(next_cursor);
        } else {
            break;
        }
    }

    Ok(summaries)
}

pub(crate) fn fetch_thread_summaries_from_archive(
    config: &BridgeCodexConfig,
) -> Result<Vec<ThreadSummaryDto>, String> {
    let endpoint = match config.mode {
        CodexRuntimeMode::Spawn => None,
        _ => config.endpoint.as_deref(),
    };
    let codex_home = resolve_codex_home_dir()?;
    let (thread_records, _) =
        load_thread_snapshot(&config.command, &config.args, endpoint, &codex_home)?;
    Ok(thread_records
        .iter()
        .map(map_legacy_thread_summary)
        .collect())
}

fn merge_thread_summaries(
    live_summaries: Vec<ThreadSummaryDto>,
    archive_summaries: Vec<ThreadSummaryDto>,
) -> Vec<ThreadSummaryDto> {
    let mut merged = live_summaries;
    let live_thread_ids = merged
        .iter()
        .map(|summary| summary.thread_id.clone())
        .collect::<std::collections::HashSet<_>>();
    merged.extend(
        archive_summaries
            .into_iter()
            .filter(|summary| !live_thread_ids.contains(&summary.thread_id)),
    );
    merged
}

pub(crate) fn fetch_thread_snapshot_from_archive(
    config: &BridgeCodexConfig,
    thread_id: &str,
) -> Result<ThreadSnapshotDto, String> {
    let endpoint = match config.mode {
        CodexRuntimeMode::Spawn => None,
        _ => config.endpoint.as_deref(),
    };
    let codex_home = resolve_codex_home_dir()?;
    let (thread_records, timeline_by_thread_id) = load_thread_snapshot_for_id(
        &config.command,
        &config.args,
        endpoint,
        &codex_home,
        thread_id,
    )?;
    let thread_record = thread_records
        .into_iter()
        .find(|record| record.id == thread_id)
        .ok_or_else(|| format!("thread {thread_id} not found"))?;
    let timeline_entries = timeline_by_thread_id
        .get(thread_id)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let (entries, pending_user_input) = filter_hidden_timeline_entries_and_extract_pending_input(
        thread_id,
        timeline_entries
            .iter()
            .map(map_timeline_entry)
            .collect::<Vec<_>>(),
        None,
    );
    let git_status = Some(GitStatusDto {
        workspace: thread_record.workspace_path.clone(),
        repository: thread_record.repository_name.clone(),
        branch: thread_record.branch_name.clone(),
        remote: (!thread_record.remote_name.trim().is_empty())
            .then_some(thread_record.remote_name.clone()),
        dirty: thread_record.git_dirty,
        ahead_by: thread_record.git_ahead_by,
        behind_by: thread_record.git_behind_by,
    });

    Ok(ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: map_legacy_thread_detail(&thread_record),
        latest_bridge_seq: None,
        entries,
        approvals: Vec::new(),
        git_status,
        workflow_state: None,
        pending_user_input,
    })
}

fn filter_hidden_timeline_entries_and_extract_pending_input(
    thread_id: &str,
    entries: Vec<ThreadTimelineEntryDto>,
    pending_user_input: Option<PendingUserInputDto>,
) -> (Vec<ThreadTimelineEntryDto>, Option<PendingUserInputDto>) {
    let visible_entries = entries
        .into_iter()
        .filter(|entry| {
            entry.kind != BridgeEventKind::MessageDelta
                || !payload_contains_hidden_message(&entry.payload)
        })
        .collect();

    let _ = thread_id;
    (visible_entries, pending_user_input)
}

pub(super) fn fetch_model_catalog(transport: &mut CodexJsonTransport) -> Vec<ModelOptionDto> {
    match transport.request(
        "model/list",
        serde_json::json!({
            "cursor": Value::Null,
            "limit": 50,
            "includeHidden": false,
        }),
    ) {
        Ok(response) => {
            let models = super::super::mapping::parse_model_options(response);
            if models.is_empty() {
                fallback_model_options()
            } else {
                models
            }
        }
        Err(_) => fallback_model_options(),
    }
}
