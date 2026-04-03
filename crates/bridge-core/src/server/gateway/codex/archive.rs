use super::super::mapping::{payload_contains_hidden_message, payload_primary_text};
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
    Ok(
        ThreadApiService::from_codex_app_server(&config.command, &config.args, endpoint)?
            .list_response()
            .threads,
    )
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
    let service = ThreadApiService::from_codex_app_server_thread(
        &config.command,
        &config.args,
        endpoint,
        thread_id,
    )?;
    let detail = service
        .detail_response(thread_id)
        .ok_or_else(|| format!("thread {thread_id} not found"))?;
    let timeline = service
        .timeline_page_response(thread_id, None, 500)
        .ok_or_else(|| format!("thread {thread_id} not found"))?;
    let (entries, pending_user_input) = filter_hidden_timeline_entries_and_extract_pending_input(
        thread_id,
        timeline.entries,
        timeline.pending_user_input,
    );
    let git_status = service
        .git_status_response(thread_id)
        .map(|response| GitStatusDto {
            workspace: response.repository.workspace,
            repository: response.repository.repository,
            branch: response.repository.branch,
            remote: (!response.repository.remote.trim().is_empty())
                .then_some(response.repository.remote),
            dirty: response.status.dirty,
            ahead_by: response.status.ahead_by,
            behind_by: response.status.behind_by,
        });

    Ok(ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail.thread,
        entries,
        approvals: Vec::new(),
        git_status,
        pending_user_input,
    })
}

fn filter_hidden_timeline_entries_and_extract_pending_input(
    thread_id: &str,
    entries: Vec<ThreadTimelineEntryDto>,
    pending_user_input: Option<PendingUserInputDto>,
) -> (Vec<ThreadTimelineEntryDto>, Option<PendingUserInputDto>) {
    let mut next_pending_user_input = pending_user_input;
    let visible_entries = entries
        .into_iter()
        .filter(|entry| {
            if entry.kind != BridgeEventKind::MessageDelta
                || !payload_contains_hidden_message(&entry.payload)
            {
                return true;
            }

            if next_pending_user_input.is_none()
                && let Some(message_text) = payload_primary_text(&entry.payload)
            {
                next_pending_user_input = parse_pending_user_input_payload(message_text, thread_id);
            }
            false
        })
        .collect();

    (visible_entries, next_pending_user_input)
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
