use super::*;
use crate::server::timeline_dedupe::dedupe_visible_user_prompt_representations;
use crate::server::timeline_events::build_timeline_event_envelope;

impl BridgeAppState {
    pub async fn ensure_snapshot(&self, thread_id: &str) -> Result<ThreadSnapshotDto, String> {
        if let Some(snapshot) = self.projections().snapshot(thread_id).await {
            let needs_full_load = snapshot.thread.status != ThreadStatus::Running
                && !snapshot_has_substantive_entries(&snapshot);
            if !needs_full_load {
                self.request_notification_thread_resume(thread_id).await;
                return Ok(snapshot);
            }
        }

        let snapshot = self.refresh_snapshot_from_gateway(thread_id).await?;
        self.request_notification_thread_resume(thread_id).await;
        Ok(snapshot)
    }

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        let mut snapshot = self
            .inner
            .gateway
            .create_thread(provider, workspace, model)
            .await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        let mut summaries = self.projections().list_summaries().await;
        let next_summary = thread_summary_from_snapshot(&snapshot);
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot.clone()).await;
        self.projections().replace_summaries(summaries).await;
        Ok(snapshot)
    }

    pub async fn timeline_page(
        &self,
        thread_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<ThreadTimelinePageDto, String> {
        let cached_snapshot = self.projections().snapshot(thread_id).await;
        let cached_summary = self.projections().summary(thread_id).await;
        let should_refresh = cached_snapshot
            .as_ref()
            .map(|snapshot| {
                should_refresh_terminal_timeline_snapshot(before, snapshot, cached_summary.as_ref())
            })
            .unwrap_or(true);
        if should_refresh {
            self.refresh_snapshot_from_gateway(thread_id).await?;
        }

        let mut page = self
            .projections()
            .timeline_page(thread_id, before, limit)
            .await
            .ok_or_else(|| format!("thread {thread_id} not found"))?;
        page.thread.access_mode = self.access_mode().await;
        Ok(page)
    }

    async fn refresh_snapshot_from_gateway(
        &self,
        thread_id: &str,
    ) -> Result<ThreadSnapshotDto, String> {
        let mut snapshot = self.inner.gateway.fetch_thread_snapshot(thread_id).await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        self.apply_external_snapshot_update(snapshot.clone(), Vec::new())
            .await;
        Ok(snapshot)
    }

    pub async fn git_status(&self, thread_id: &str) -> Result<GitStatusResponse, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let git_state = read_git_state_for_status(&snapshot.thread.workspace, thread_id)?;
        self.projections()
            .update_git_state(
                thread_id,
                &git_state.response.repository,
                &git_state.response.status,
                None,
                None,
            )
            .await;
        Ok(git_state.response)
    }

    pub async fn git_diff(
        &self,
        thread_id: &str,
        mode: ThreadGitDiffMode,
        path: Option<&str>,
    ) -> Result<ThreadGitDiffDto, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let repository = match mode {
            ThreadGitDiffMode::Workspace => read_git_state(&snapshot.thread.workspace, thread_id)
                .map(|state| state.snapshot_status)?,
            ThreadGitDiffMode::LatestThreadChange => {
                snapshot.git_status.clone().unwrap_or(SharedGitStatusDto {
                    workspace: snapshot.thread.workspace.clone(),
                    repository: snapshot.thread.repository.clone(),
                    branch: snapshot.thread.branch.clone(),
                    remote: None,
                    dirty: false,
                    ahead_by: 0,
                    behind_by: 0,
                })
            }
        };
        let (unified_diff, revision) = match mode {
            ThreadGitDiffMode::Workspace => {
                resolve_workspace_diff(&snapshot.thread.workspace, path)?
            }
            ThreadGitDiffMode::LatestThreadChange => (
                resolve_latest_thread_change_diff(&snapshot.entries, path),
                None,
            ),
        };

        Ok(ThreadGitDiffDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: snapshot.thread,
            repository,
            mode,
            revision,
            files: parse_git_diff_file_summaries(&unified_diff),
            unified_diff,
            fetched_at: Utc::now().to_rfc3339(),
        })
    }

    pub async fn thread_usage(&self, thread_id: &str) -> Result<ThreadUsageDto, CodexUsageError> {
        let snapshot = self
            .ensure_snapshot(thread_id)
            .await
            .map_err(CodexUsageError::UpstreamUnavailable)?;

        if snapshot.thread.provider != ProviderKind::Codex {
            return Err(CodexUsageError::AuthUnavailable(
                "Usage bars are only available for Codex threads.".to_string(),
            ));
        }

        let usage = self
            .inner
            .codex_usage_client
            .read()
            .await
            .fetch_usage()
            .await?;
        Ok(ThreadUsageDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: snapshot.thread.thread_id,
            provider: ProviderKind::Codex,
            plan_type: usage.plan_type,
            primary_window: usage.primary_window,
            secondary_window: usage.secondary_window,
        })
    }

    pub(super) async fn set_codex_health(&self, health: ServiceHealthDto) {
        *self.inner.codex_health.write().await = health;
    }

    pub(super) async fn set_available_models(&self, models: Vec<ModelOptionDto>) {
        *self.inner.available_models.write().await = models;
    }

    pub(super) async fn record_bridge_turn_metadata(&self, event: &BridgeEventEnvelope<Value>) {
        let mut metadata_by_thread = self.inner.bridge_turn_metadata.write().await;
        let entries = metadata_by_thread
            .entry(event.thread_id.clone())
            .or_insert_with(Vec::new);
        let next_entry = ThreadTimelineEntryDto {
            event_id: event.event_id.clone(),
            kind: event.kind,
            occurred_at: event.occurred_at.clone(),
            summary: String::new(),
            payload: event.payload.clone(),
            annotations: event.annotations.clone(),
        };
        if let Some(index) = entries
            .iter()
            .position(|existing| existing.event_id == next_entry.event_id)
        {
            entries[index] = next_entry;
        } else {
            entries.push(next_entry);
        }
        entries.sort_by(|left, right| {
            left.occurred_at
                .cmp(&right.occurred_at)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });
    }

    pub(super) async fn merge_bridge_turn_metadata(&self, snapshot: &mut ThreadSnapshotDto) {
        let metadata_entries = self
            .inner
            .bridge_turn_metadata
            .read()
            .await
            .get(&snapshot.thread.thread_id)
            .cloned()
            .unwrap_or_default();
        if metadata_entries.is_empty() {
            return;
        }

        for metadata_entry in metadata_entries {
            if snapshot
                .entries
                .iter()
                .any(|existing| existing.event_id == metadata_entry.event_id)
            {
                continue;
            }
            snapshot.entries.push(metadata_entry);
        }
        snapshot.entries.sort_by(|left, right| {
            left.occurred_at
                .cmp(&right.occurred_at)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });
    }

    pub(super) async fn apply_external_snapshot_update(
        &self,
        mut snapshot: ThreadSnapshotDto,
        events: Vec<BridgeEventEnvelope<Value>>,
    ) {
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        self.inject_pending_turn_client_message_id_into_snapshot(&mut snapshot)
            .await;
        if let Some(previous_snapshot) = self
            .projections()
            .snapshot(&snapshot.thread.thread_id)
            .await
        {
            snapshot.entries =
                merge_external_snapshot_entries(&previous_snapshot.entries, &snapshot.entries);
            preserve_generated_thread_title(&previous_snapshot, &mut snapshot);
        }
        dedupe_visible_user_prompt_representations(&mut snapshot.entries);
        let next_summary = thread_summary_from_snapshot(&snapshot);
        let mut summaries = self.projections().list_summaries().await;
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot).await;
        self.projections().replace_summaries(summaries).await;

        for event in events {
            if should_clear_transient_thread_state(&event) {
                self.clear_transient_thread_state(&event.thread_id).await;
            }
            self.event_hub().publish(event);
        }
    }

    async fn inject_pending_turn_client_message_id_into_snapshot(
        &self,
        snapshot: &mut ThreadSnapshotDto,
    ) {
        let pending = self
            .pending_turn_client_message(&snapshot.thread.thread_id)
            .await;
        let Some(pending) = pending else {
            return;
        };

        let Some(index) = find_pending_client_message_snapshot_entry(&snapshot.entries, &pending)
        else {
            return;
        };

        if let Some(object) = snapshot.entries[index].payload.as_object_mut() {
            object.insert(
                "client_message_id".to_string(),
                Value::String(pending.client_message_id),
            );
        }
        self.clear_pending_turn_client_message(&snapshot.thread.thread_id)
            .await;
    }

    pub(super) async fn schedule_recent_placeholder_title_backfill(&self, limit: usize) {
        let mut placeholder_threads = self.projections().list_summaries().await;
        placeholder_threads.retain(|summary| is_placeholder_thread_title(&summary.title));
        placeholder_threads.truncate(limit);

        for summary in placeholder_threads {
            self.schedule_thread_title_backfill_from_snapshot(&summary.thread_id, None)
                .await;
        }
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

    async fn schedule_thread_title_backfill_from_snapshot(
        &self,
        thread_id: &str,
        model: Option<&str>,
    ) {
        if !self
            .reserve_thread_title_generation_if_needed(thread_id)
            .await
        {
            return;
        }

        let state = self.clone();
        let thread_id = thread_id.to_string();
        let model = title_generation_model_for_thread(&thread_id, model).map(str::to_string);
        tokio::spawn(async move {
            let snapshot = state.ensure_snapshot(&thread_id).await.ok();
            let generated_title = snapshot
                .as_ref()
                .and_then(title_generation_source_from_snapshot)
                .and_then(|source| {
                    if source.prompt.trim().is_empty() {
                        None
                    } else {
                        Some(source)
                    }
                });

            if let Some(source) = generated_title {
                if let Some(title) =
                    provisional_thread_title_from_prompt(&thread_id, &source.prompt)
                {
                    let _ = state
                        .persist_generated_thread_title(&thread_id, &title)
                        .await;
                } else if let Ok(Some(title)) = state
                    .inner
                    .gateway
                    .generate_thread_title_candidate(
                        &source.workspace,
                        &source.prompt,
                        model.as_deref(),
                    )
                    .await
                {
                    let _ = state
                        .persist_generated_thread_title(&thread_id, &title)
                        .await;
                }
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

    pub(super) async fn thread_title_still_needs_generation(&self, thread_id: &str) -> bool {
        self.projections()
            .thread_title(thread_id)
            .await
            .map(|title| is_placeholder_thread_title(&title))
            .unwrap_or(true)
    }

    pub(super) async fn persist_generated_thread_title(
        &self,
        thread_id: &str,
        title: &str,
    ) -> Result<(), String> {
        let normalized_title = title.trim();
        if normalized_title.is_empty() || !self.thread_title_still_needs_generation(thread_id).await
        {
            return Ok(());
        }

        if is_provider_thread_id(thread_id, ProviderKind::Codex) {
            self.inner
                .gateway
                .set_thread_name(thread_id, normalized_title)
                .await?;
        }
        let occurred_at = Utc::now().to_rfc3339();
        let status = self
            .projections()
            .update_thread_title(thread_id, normalized_title, &occurred_at)
            .await
            .unwrap_or(ThreadStatus::Idle);
        self.event_hub().publish(BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-title-{occurred_at}"),
            bridge_seq: None,
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at,
            payload: json!({
                "status": thread_status_wire_value(status),
                "reason": "thread_title_generated",
                "title": normalized_title,
            }),
            annotations: None,
        });
        Ok(())
    }
}

fn merge_external_snapshot_entries(
    previous_entries: &[ThreadTimelineEntryDto],
    next_entries: &[ThreadTimelineEntryDto],
) -> Vec<ThreadTimelineEntryDto> {
    let mut merged_by_id = previous_entries
        .iter()
        .cloned()
        .map(|entry| (entry.event_id.clone(), entry))
        .collect::<HashMap<_, _>>();

    for next_entry in next_entries {
        merged_by_id
            .entry(next_entry.event_id.clone())
            .and_modify(|previous_entry| {
                *previous_entry = merge_timeline_entry(previous_entry, next_entry);
            })
            .or_insert_with(|| next_entry.clone());
    }

    let mut merged_entries = merged_by_id.into_values().collect::<Vec<_>>();
    dedupe_visible_user_prompt_representations(&mut merged_entries);
    merged_entries.sort_by(|left, right| {
        left.occurred_at
            .cmp(&right.occurred_at)
            .then_with(|| left.event_id.cmp(&right.event_id))
    });
    merged_entries
}

fn merge_timeline_entry(
    previous_entry: &ThreadTimelineEntryDto,
    next_entry: &ThreadTimelineEntryDto,
) -> ThreadTimelineEntryDto {
    ThreadTimelineEntryDto {
        event_id: next_entry.event_id.clone(),
        kind: next_entry.kind,
        occurred_at: if next_entry.occurred_at >= previous_entry.occurred_at {
            next_entry.occurred_at.clone()
        } else {
            previous_entry.occurred_at.clone()
        },
        summary: if !next_entry.summary.trim().is_empty() {
            next_entry.summary.clone()
        } else {
            previous_entry.summary.clone()
        },
        payload: merge_timeline_payload(&previous_entry.payload, &next_entry.payload),
        annotations: next_entry
            .annotations
            .clone()
            .or_else(|| previous_entry.annotations.clone()),
    }
}

fn merge_timeline_payload(previous_payload: &Value, next_payload: &Value) -> Value {
    match (previous_payload, next_payload) {
        (Value::Object(previous_object), Value::Object(next_object)) => {
            let mut merged = previous_object.clone();
            for (key, value) in next_object {
                merged.insert(key.clone(), value.clone());
            }
            Value::Object(merged)
        }
        _ => next_payload.clone(),
    }
}

pub(super) fn should_refresh_terminal_timeline_snapshot(
    before: Option<&str>,
    snapshot: &ThreadSnapshotDto,
    summary: Option<&ThreadSummaryDto>,
) -> bool {
    if before.is_some() || snapshot.thread.status == ThreadStatus::Running {
        return false;
    }

    if !snapshot_has_substantive_entries(snapshot) {
        return true;
    }

    if summary
        .map(|summary| summary.updated_at > snapshot.thread.updated_at)
        .unwrap_or(false)
    {
        return true;
    }

    snapshot
        .entries
        .iter()
        .any(entry_needs_exploration_annotation_refresh)
}

fn entry_needs_exploration_annotation_refresh(entry: &ThreadTimelineEntryDto) -> bool {
    if entry.kind != BridgeEventKind::CommandDelta || entry.annotations.is_some() {
        return false;
    }

    build_timeline_event_envelope(
        format!("refresh-check-{}", entry.event_id),
        "refresh-check-thread",
        entry.kind,
        entry.occurred_at.clone(),
        entry.payload.clone(),
    )
    .annotations
    .and_then(|annotations| annotations.exploration_kind)
    .is_some()
}

fn find_pending_client_message_snapshot_entry(
    entries: &[ThreadTimelineEntryDto],
    pending: &PendingTurnClientMessage,
) -> Option<usize> {
    entries
        .iter()
        .enumerate()
        .rev()
        .find(|(_, entry)| {
            timeline_entry_matches_pending_turn(entry, pending)
                && timeline_entry_lacks_client_message_id(entry)
        })
        .map(|(index, _)| index)
        .or_else(|| {
            let normalized_prompt = normalize_pending_prompt_text(&pending.prompt_text);
            (!normalized_prompt.is_empty()).then_some(())?;
            entries
                .iter()
                .enumerate()
                .rev()
                .find(|(_, entry)| {
                    timeline_entry_is_user_message(entry)
                        && timeline_entry_lacks_client_message_id(entry)
                        && normalize_pending_prompt_text(
                            timeline_entry_primary_text(entry).unwrap_or_default(),
                        ) == normalized_prompt
                })
                .map(|(index, _)| index)
        })
        .or_else(|| {
            entries
                .iter()
                .enumerate()
                .rev()
                .find(|(_, entry)| {
                    timeline_entry_is_user_message(entry)
                        && timeline_entry_lacks_client_message_id(entry)
                })
                .map(|(index, _)| index)
        })
}

fn timeline_entry_matches_pending_turn(
    entry: &ThreadTimelineEntryDto,
    pending: &PendingTurnClientMessage,
) -> bool {
    let Some(turn_id) = pending.turn_id.as_deref() else {
        return false;
    };
    event_belongs_to_turn(&entry.event_id, turn_id)
}

fn timeline_entry_is_user_message(entry: &ThreadTimelineEntryDto) -> bool {
    entry.payload.get("role").and_then(Value::as_str) == Some("user")
        || entry.payload.get("type").and_then(Value::as_str) == Some("userMessage")
}

fn timeline_entry_lacks_client_message_id(entry: &ThreadTimelineEntryDto) -> bool {
    entry.payload.get("client_message_id").is_none()
}

fn event_belongs_to_turn(event_id: &str, turn_id: &str) -> bool {
    event_id == turn_id
        || event_id
            .strip_prefix(turn_id)
            .is_some_and(|suffix| suffix.starts_with('-'))
}

fn timeline_entry_primary_text(entry: &ThreadTimelineEntryDto) -> Option<&str> {
    entry
        .payload
        .get("text")
        .and_then(Value::as_str)
        .or_else(|| entry.payload.get("delta").and_then(Value::as_str))
        .or_else(|| {
            entry
                .payload
                .get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .find(|text| !text.trim().is_empty())
        })
}

fn normalize_pending_prompt_text(value: &str) -> String {
    value
        .trim()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Returns `true` if the snapshot has been fully loaded from the gateway (i.e. it is
/// not a stub created by hydrating from the persisted event log alone).
///
/// Stubs are created by `ensure_snapshot_for_thread_from_summary_locked` with
/// `source = "bridge_event_log"` and carry no message/command/file-change entries.
/// A snapshot with that source and no substantive content needs a full gateway refresh
/// before it can be shown to the user.
fn snapshot_has_substantive_entries(snapshot: &ThreadSnapshotDto) -> bool {
    // If the source is anything other than the synthetic event-log placeholder, treat
    // the snapshot as already loaded (even if entries happen to be empty, e.g. brand-new
    // threads or test fixtures that intentionally carry no content).
    if snapshot.thread.source != "bridge_event_log" {
        return true;
    }
    snapshot.entries.iter().any(|entry| {
        matches!(
            entry.kind,
            BridgeEventKind::MessageDelta
                | BridgeEventKind::CommandDelta
                | BridgeEventKind::FileChange
                | BridgeEventKind::PlanDelta
        )
    })
}
