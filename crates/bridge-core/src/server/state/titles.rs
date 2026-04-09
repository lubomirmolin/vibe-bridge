use super::*;

impl BridgeAppState {
    pub(super) async fn apply_local_placeholder_thread_title_fallback(
        &self,
        thread_id: &str,
    ) -> Option<String> {
        if !self.thread_title_still_needs_generation(thread_id).await {
            return None;
        }

        let snapshot = self.projections().snapshot(thread_id).await?;
        let fallback_title = title_generation_source_from_snapshot(&snapshot)
            .and_then(|source| provisional_thread_title_from_prompt(thread_id, &source.prompt))?;
        self.projections()
            .update_thread_title(thread_id, &fallback_title, &snapshot.thread.updated_at)
            .await?;
        Some(fallback_title)
    }

    pub(super) async fn schedule_thread_title_generation_from_prompt(
        &self,
        thread_id: &str,
        visible_prompt: &str,
        workspace: &str,
        model: Option<&str>,
    ) {
        let normalized_prompt = visible_prompt.trim();
        if normalized_prompt.is_empty() {
            return;
        }
        if let Some(fallback_title) =
            provisional_thread_title_from_prompt(thread_id, normalized_prompt)
        {
            let _ = self
                .persist_generated_thread_title(thread_id, &fallback_title)
                .await;
            return;
        }
        if !self
            .reserve_thread_title_generation_if_needed(thread_id)
            .await
        {
            return;
        }

        let state = self.clone();
        let thread_id = thread_id.to_string();
        let prompt = normalized_prompt.to_string();
        let workspace = workspace.to_string();
        let model = title_generation_model_for_thread(&thread_id, model).map(str::to_string);
        tokio::spawn(async move {
            let generation_result = state
                .inner
                .gateway
                .generate_thread_title_candidate(&workspace, &prompt, model.as_deref())
                .await;

            if let Ok(Some(title)) = generation_result {
                let _ = state
                    .persist_generated_thread_title(&thread_id, &title)
                    .await;
            }

            state.release_thread_title_generation(&thread_id).await;
        });
    }

    async fn reserve_thread_title_generation_if_needed(&self, thread_id: &str) -> bool {
        if !self.should_generate_thread_title(thread_id).await {
            return false;
        }

        self.inner
            .inflight_thread_title_generations
            .write()
            .await
            .insert(thread_id.to_string())
    }

    async fn release_thread_title_generation(&self, thread_id: &str) {
        self.inner
            .inflight_thread_title_generations
            .write()
            .await
            .remove(thread_id);
    }

    pub(super) async fn should_generate_thread_title(&self, thread_id: &str) -> bool {
        if !matches!(
            provider_from_thread_id(thread_id),
            Some(
                shared_contracts::ProviderKind::Codex | shared_contracts::ProviderKind::ClaudeCode
            )
        ) {
            return false;
        }
        if self
            .inner
            .inflight_thread_title_generations
            .read()
            .await
            .contains(thread_id)
        {
            return false;
        }

        self.thread_title_still_needs_generation(thread_id).await
    }

    async fn thread_title_still_needs_generation(&self, thread_id: &str) -> bool {
        self.projections()
            .thread_title(thread_id)
            .await
            .map(|title| is_placeholder_thread_title(&title))
            .unwrap_or(true)
    }

    async fn persist_generated_thread_title(
        &self,
        thread_id: &str,
        title: &str,
    ) -> Result<(), String> {
        let normalized_title = title.trim();
        if normalized_title.is_empty() || !self.thread_title_still_needs_generation(thread_id).await
        {
            return Ok(());
        }

        if is_provider_thread_id(thread_id, ProviderKind::Codex)
            && let Err(error) = self
                .inner
                .gateway
                .set_thread_name(thread_id, normalized_title)
                .await
        {
            eprintln!(
                "bridge generated thread title upstream rename failed thread_id={thread_id}: {error}; keeping local title"
            );
        }
        let occurred_at = Utc::now().to_rfc3339();
        let status = self
            .projections()
            .snapshot(thread_id)
            .await
            .map(|snapshot| snapshot.thread.status)
            .or(self.projections().summary_status(thread_id).await)
            .unwrap_or(ThreadStatus::Idle);
        self.dispatch_thread_event(build_raw_thread_event(
            RawThreadEventSource::BridgeLocal,
            BridgeEventEnvelope {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                event_id: format!("{thread_id}-title-{occurred_at}"),
                thread_id: thread_id.to_string(),
                kind: BridgeEventKind::ThreadStatusChanged,
                occurred_at,
                payload: json!({
                    "status": thread_status_wire_value(status),
                    "reason": "thread_title_generated",
                    "title": normalized_title,
                }),
                annotations: None,
                bridge_seq: None,
            },
        ))
        .await;
        Ok(())
    }
}

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
struct ThreadTitleGenerationSource {
    prompt: String,
}

fn title_generation_source_from_snapshot(
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
    Some(ThreadTitleGenerationSource { prompt })
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
