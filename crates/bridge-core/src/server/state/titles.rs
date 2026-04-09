use super::*;

pub(super) fn title_generation_model_for_thread<'a>(
    thread_id: &str,
    model: Option<&'a str>,
) -> Option<&'a str> {
    if is_provider_thread_id(thread_id, ProviderKind::Codex) {
        return model;
    }

    None
}

pub(super) fn provisional_thread_title_from_prompt(
    thread_id: &str,
    prompt: &str,
) -> Option<String> {
    if !is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
        return None;
    }

    prompt_fallback_thread_title(prompt)
}

pub(super) fn placeholder_thread_title_fallback_from_snapshot(
    snapshot: &ThreadSnapshotDto,
) -> Option<String> {
    if !is_placeholder_thread_title(&snapshot.thread.title) {
        return None;
    }

    title_generation_source_from_snapshot(snapshot)
        .and_then(|source| prompt_fallback_thread_title(&source.prompt))
}

fn prompt_fallback_thread_title(prompt: &str) -> Option<String> {
    let first_sentence = prompt
        .split(['.', '?', '!'])
        .find(|segment| !segment.trim().is_empty())
        .unwrap_or(prompt);
    normalize_prompt_fallback_thread_title(first_sentence)
}

fn normalize_prompt_fallback_thread_title(prompt: &str) -> Option<String> {
    let normalized_whitespace = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim()
        .trim_matches(|ch| matches!(ch, '"' | '\'' | '`'));
    if trimmed.is_empty() || is_placeholder_thread_title(trimmed) {
        return None;
    }

    let mut title = trimmed.to_string();
    const MAX_THREAD_TITLE_CHARS: usize = 80;
    if title.chars().count() > MAX_THREAD_TITLE_CHARS {
        title = title
            .chars()
            .take(MAX_THREAD_TITLE_CHARS)
            .collect::<String>();
    }

    while title.ends_with('.') || title.ends_with(':') || title.ends_with(';') {
        title.pop();
    }

    let normalized = title.trim();
    if normalized.is_empty() || is_placeholder_thread_title(normalized) {
        return None;
    }

    Some(normalized.to_string())
}

pub(super) fn preserve_generated_thread_title(
    previous_snapshot: &ThreadSnapshotDto,
    next_snapshot: &mut ThreadSnapshotDto,
) {
    if is_placeholder_thread_title(&next_snapshot.thread.title)
        && !is_placeholder_thread_title(&previous_snapshot.thread.title)
    {
        next_snapshot.thread.title = previous_snapshot.thread.title.clone();
    }
}

pub(super) fn merge_reconciled_thread_summaries(
    current_summaries: Vec<ThreadSummaryDto>,
    mut reconciled_summaries: Vec<ThreadSummaryDto>,
) -> Vec<ThreadSummaryDto> {
    let current_by_thread_id = current_summaries
        .into_iter()
        .map(|summary| (summary.thread_id.clone(), summary))
        .collect::<HashMap<_, _>>();

    for summary in &mut reconciled_summaries {
        let Some(current_summary) = current_by_thread_id.get(&summary.thread_id) else {
            continue;
        };
        if is_placeholder_thread_title(&summary.title)
            && !is_placeholder_thread_title(&current_summary.title)
        {
            summary.title = current_summary.title.clone();
        }
    }

    reconciled_summaries
}

pub(super) fn thread_summary_from_snapshot(snapshot: &ThreadSnapshotDto) -> ThreadSummaryDto {
    ThreadSummaryDto {
        contract_version: snapshot.contract_version.clone(),
        thread_id: snapshot.thread.thread_id.clone(),
        native_thread_id: snapshot.thread.native_thread_id.clone(),
        provider: snapshot.thread.provider,
        client: snapshot.thread.client,
        title: snapshot.thread.title.clone(),
        status: snapshot.thread.status,
        workspace: snapshot.thread.workspace.clone(),
        repository: snapshot.thread.repository.clone(),
        branch: snapshot.thread.branch.clone(),
        updated_at: snapshot.thread.updated_at.clone(),
    }
}

#[derive(Debug, Clone)]
pub(super) struct ThreadTitleGenerationSource {
    pub(super) workspace: String,
    pub(super) prompt: String,
}

pub(super) fn title_generation_source_from_snapshot(
    snapshot: &ThreadSnapshotDto,
) -> Option<ThreadTitleGenerationSource> {
    let prompt = snapshot
        .entries
        .iter()
        .find_map(first_user_message_text_from_entry)
        .or_else(|| {
            let summary = snapshot.thread.last_turn_summary.trim();
            (!summary.is_empty() && !is_placeholder_thread_title(summary))
                .then(|| summary.to_string())
        })?;
    let workspace = snapshot.thread.workspace.trim();
    if workspace.is_empty() {
        return None;
    }

    Some(ThreadTitleGenerationSource {
        workspace: workspace.to_string(),
        prompt,
    })
}

fn first_user_message_text_from_entry(entry: &ThreadTimelineEntryDto) -> Option<String> {
    if entry.kind != BridgeEventKind::MessageDelta {
        return None;
    }
    if entry.payload.get("role").and_then(Value::as_str) != Some("user") {
        return None;
    }

    extract_text_from_payload(&entry.payload)
}

pub(super) fn extract_text_from_payload(payload: &Value) -> Option<String> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
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
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

pub(super) fn is_placeholder_thread_title(title: &str) -> bool {
    let normalized = title.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "untitled thread"
        || normalized == "new thread"
        || normalized == "fresh session"
}
