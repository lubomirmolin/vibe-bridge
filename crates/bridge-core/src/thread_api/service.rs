use std::collections::HashMap;

use serde_json::{Value, json};
use shared_contracts::{
    BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ModelCatalogDto, ModelOptionDto,
    ThreadTimelinePageDto,
};

use super::archive::{
    load_thread_snapshot, load_thread_snapshot_for_id, merge_snapshot_timeline,
    resolve_codex_home_dir,
};
use super::rpc::{
    CodexRpcClient, fallback_model_options, normalize_turn_text, read_thread_with_resume,
    start_turn_with_resume,
};
use super::sync::ThreadSyncConfig;
use super::timeline::{
    build_timeline_event_envelope, current_timestamp_string, map_bridge_kind_to_event_type,
    map_event_kind, map_git_status, map_repository_context, map_thread_detail, map_thread_status,
    map_thread_summary, map_timeline_entry, map_wire_thread_status_to_lifecycle_state,
    summarize_live_payload,
};
use super::{
    GitStatusResponse, MutationDispatch, MutationResultResponse, ThreadApiService,
    ThreadDetailResponse, ThreadListResponse, UpstreamThreadRecord, UpstreamTimelineEvent,
};

impl ThreadApiService {
    pub fn empty() -> Self {
        Self::with_seed_data(Vec::new(), HashMap::new())
    }

    pub fn with_seed_data(
        thread_records: Vec<UpstreamThreadRecord>,
        timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    ) -> Self {
        let mut service = Self {
            thread_records,
            timeline_by_thread_id,
            thread_sync_receipts_by_id: HashMap::new(),
            next_event_sequence: 10,
            sync_config: None,
        };
        service.refresh_all_thread_sync_receipts();
        service
    }

    pub fn from_codex_app_server(
        command: &str,
        args: &[String],
        endpoint: Option<&str>,
    ) -> Result<Self, String> {
        let codex_home = resolve_codex_home_dir()?;
        let (thread_records, timeline_by_thread_id) =
            load_thread_snapshot(command, args, endpoint, &codex_home)?;

        let mut service = Self {
            thread_records,
            timeline_by_thread_id,
            thread_sync_receipts_by_id: HashMap::new(),
            next_event_sequence: 10,
            sync_config: Some(ThreadSyncConfig {
                codex_command: command.to_string(),
                codex_args: args.to_vec(),
                codex_endpoint: endpoint.map(ToOwned::to_owned),
                codex_home,
            }),
        };
        service.refresh_all_thread_sync_receipts();
        Ok(service)
    }

    pub fn sync_from_upstream(&mut self) -> Result<(), String> {
        let Some(sync_config) = &self.sync_config else {
            return Ok(());
        };

        let (thread_records, timeline_by_thread_id) = load_thread_snapshot(
            &sync_config.codex_command,
            &sync_config.codex_args,
            sync_config.codex_endpoint.as_deref(),
            &sync_config.codex_home,
        )?;
        self.thread_records = thread_records;
        self.timeline_by_thread_id = timeline_by_thread_id;
        self.refresh_all_thread_sync_receipts();
        Ok(())
    }

    pub fn sync_thread_from_upstream(&mut self, thread_id: &str) -> Result<(), String> {
        let Some(sync_config) = &self.sync_config else {
            return Ok(());
        };

        if self.should_reuse_recent_thread_sync(thread_id) {
            return Ok(());
        }

        let (thread_records, timeline_by_thread_id) = load_thread_snapshot_for_id(
            &sync_config.codex_command,
            &sync_config.codex_args,
            sync_config.codex_endpoint.as_deref(),
            &sync_config.codex_home,
            thread_id,
        )?;

        let next_thread = thread_records
            .into_iter()
            .find(|thread| thread.id == thread_id);
        let next_timeline = timeline_by_thread_id.get(thread_id).cloned();

        if let Some(thread) = next_thread {
            if let Some(existing_index) = self
                .thread_records
                .iter()
                .position(|existing| existing.id == thread_id)
            {
                self.thread_records[existing_index] = thread;
            } else {
                self.thread_records.push(thread);
            }
        } else {
            self.thread_records.retain(|thread| thread.id != thread_id);
        }

        if let Some(timeline) = next_timeline {
            self.timeline_by_thread_id
                .insert(thread_id.to_string(), timeline);
        } else {
            self.timeline_by_thread_id.remove(thread_id);
        }

        self.refresh_thread_sync_receipt(thread_id);

        Ok(())
    }

    pub fn reconcile_from_upstream(&mut self) -> Result<Vec<BridgeEventEnvelope<Value>>, String> {
        let Some(sync_config) = &self.sync_config else {
            return Ok(Vec::new());
        };

        let (thread_records, timeline_by_thread_id) = load_thread_snapshot(
            &sync_config.codex_command,
            &sync_config.codex_args,
            sync_config.codex_endpoint.as_deref(),
            &sync_config.codex_home,
        )?;

        Ok(self.reconcile_snapshot(thread_records, timeline_by_thread_id))
    }

    pub fn reconcile_snapshot(
        &mut self,
        thread_records: Vec<UpstreamThreadRecord>,
        timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    ) -> Vec<BridgeEventEnvelope<Value>> {
        let previous_threads = self
            .thread_records
            .iter()
            .cloned()
            .map(|thread| (thread.id.clone(), thread))
            .collect::<HashMap<_, _>>();
        let previous_timeline = self.timeline_by_thread_id.clone();
        let mut events = Vec::new();

        let mut merged_timeline_by_thread_id = HashMap::new();

        for thread in &thread_records {
            if let Some(previous_thread) = previous_threads.get(&thread.id)
                && previous_thread.lifecycle_state != thread.lifecycle_state
            {
                events.push(self.next_event_with_occurred_at(
                    &thread.id,
                    BridgeEventKind::ThreadStatusChanged,
                    thread.updated_at.as_str(),
                    json!({
                        "status": serde_json::to_value(map_thread_status(&thread.lifecycle_state))
                            .expect("thread status should serialize"),
                        "reason": "upstream_sync",
                    }),
                ));
            }

            let previous_event_ids = previous_timeline
                .get(&thread.id)
                .map(|events| {
                    events
                        .iter()
                        .cloned()
                        .map(|event| (event.id.clone(), event))
                        .collect::<HashMap<_, _>>()
                })
                .unwrap_or_default();

            let merged_timeline = merge_snapshot_timeline(
                previous_timeline
                    .get(&thread.id)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]),
                timeline_by_thread_id
                    .get(&thread.id)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]),
            );

            for event in &merged_timeline {
                if let Some(previous_event) = previous_event_ids.get(&event.id)
                    && previous_event == event
                {
                    continue;
                }

                events.push(build_timeline_event_envelope(
                    event.id.clone(),
                    thread.id.clone(),
                    map_event_kind(&event.event_type),
                    event.happened_at.clone(),
                    event.data.clone(),
                ));
            }

            merged_timeline_by_thread_id.insert(thread.id.clone(), merged_timeline);
        }

        self.thread_records = thread_records;
        self.timeline_by_thread_id = merged_timeline_by_thread_id;
        self.refresh_all_thread_sync_receipts();
        events
    }

    pub fn apply_live_event(&mut self, event: BridgeEventEnvelope<Value>) {
        let thread_id = event.thread_id.clone();
        let upstream_event = UpstreamTimelineEvent {
            id: event.event_id.clone(),
            event_type: map_bridge_kind_to_event_type(event.kind).to_string(),
            happened_at: event.occurred_at.clone(),
            summary_text: summarize_live_payload(event.kind, &event.payload),
            data: event.payload.clone(),
        };

        let timeline = self
            .timeline_by_thread_id
            .entry(thread_id.clone())
            .or_default();
        if let Some(existing_index) = timeline
            .iter()
            .position(|entry| entry.id == upstream_event.id)
        {
            timeline[existing_index] = upstream_event.clone();
        } else {
            timeline.push(upstream_event.clone());
        }

        if let Some(thread) = self
            .thread_records
            .iter_mut()
            .find(|thread| thread.id == thread_id)
        {
            thread.updated_at = event.occurred_at.clone();

            if event.kind == BridgeEventKind::ThreadStatusChanged {
                let next_status = event
                    .payload
                    .get("status")
                    .and_then(Value::as_str)
                    .map(map_wire_thread_status_to_lifecycle_state);
                if let Some(next_status) = next_status {
                    thread.lifecycle_state = next_status;
                }
            }

            if !upstream_event.summary_text.trim().is_empty() {
                thread.last_turn_summary = upstream_event.summary_text;
            }
        }

        self.refresh_thread_sync_receipt(&thread_id);
    }

    pub fn sample() -> Self {
        let thread_records = vec![
            UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Implement shared contracts".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: true,
                git_ahead_by: 2,
                git_behind_by: 1,
                created_at: "2026-03-17T17:45:00Z".to_string(),
                updated_at: "2026-03-17T18:00:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Summarized lifecycle behavior".to_string(),
            },
            UpstreamThreadRecord {
                id: "thread-456".to_string(),
                headline: "Investigate reconnect dedup".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/codex-runtime-tools".to_string(),
                repository_name: "codex-runtime-tools".to_string(),
                branch_name: "develop".to_string(),
                remote_name: "upstream".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T16:30:00Z".to_string(),
                updated_at: "2026-03-17T17:30:00Z".to_string(),
                source: "vscode".to_string(),
                approval_mode: "full_control".to_string(),
                last_turn_summary: "Captured reconnect edge cases".to_string(),
            },
        ];

        let timeline_by_thread_id = HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T18:01:00Z".to_string(),
                    summary_text: "Agent emitted message delta".to_string(),
                    data: json!({ "delta": "Working on foundation contracts" }),
                },
                UpstreamTimelineEvent {
                    id: "evt-2".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T18:01:10Z".to_string(),
                    summary_text: "Command output streamed".to_string(),
                    data: json!({ "command": "cargo test --workspace", "delta": "running 12 tests" }),
                },
            ],
        )]);

        Self::with_seed_data(thread_records, timeline_by_thread_id)
    }

    pub fn list_response(&self) -> ThreadListResponse {
        ThreadListResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            threads: self
                .thread_records
                .iter()
                .map(map_thread_summary)
                .collect::<Vec<_>>(),
        }
    }

    pub fn detail_response(&self, thread_id: &str) -> Option<ThreadDetailResponse> {
        self.thread_records
            .iter()
            .find(|thread| thread.id == thread_id)
            .map(|thread| ThreadDetailResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: map_thread_detail(thread),
            })
    }

    pub fn model_catalog_response(&self) -> ModelCatalogDto {
        let models = self
            .load_models_from_upstream()
            .unwrap_or_else(|_| fallback_model_options());
        ModelCatalogDto {
            contract_version: CONTRACT_VERSION.to_string(),
            models,
        }
    }

    pub fn timeline_page_response(
        &self,
        thread_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Option<ThreadTimelinePageDto> {
        let thread = self
            .thread_records
            .iter()
            .find(|thread| thread.id == thread_id)?;
        let events = self
            .timeline_by_thread_id
            .get(thread_id)
            .map(Vec::as_slice)
            .unwrap_or(&[]);

        let normalized_limit = limit.max(1);
        let end_index = before
            .and_then(|cursor| events.iter().position(|event| event.id == cursor))
            .unwrap_or(events.len());
        let start_index = end_index.saturating_sub(normalized_limit);
        let page_events = &events[start_index..end_index];
        let has_more_before = start_index > 0;
        let next_before = has_more_before.then(|| events[start_index].id.clone());

        Some(ThreadTimelinePageDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: map_thread_detail(thread),
            entries: page_events
                .iter()
                .map(map_timeline_entry)
                .collect::<Vec<_>>(),
            next_before,
            has_more_before,
        })
    }

    pub fn timeline_cursor_exists(&self, thread_id: &str, cursor: &str) -> Option<bool> {
        let events = self.timeline_by_thread_id.get(thread_id)?;
        Some(events.iter().any(|event| event.id == cursor))
    }

    fn load_models_from_upstream(&self) -> Result<Vec<ModelOptionDto>, String> {
        if self.sync_config.is_none() {
            return Ok(fallback_model_options());
        }

        let mut client = self.codex_rpc_client()?;
        let models = client.list_models()?;
        if models.is_empty() {
            return Ok(fallback_model_options());
        }

        Ok(models)
    }

    pub fn git_status_response(&self, thread_id: &str) -> Option<GitStatusResponse> {
        self.thread_records
            .iter()
            .find(|thread| thread.id == thread_id)
            .map(|thread| GitStatusResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                repository: map_repository_context(thread),
                status: map_git_status(thread),
            })
    }

    pub fn start_turn(
        &mut self,
        thread_id: &str,
        prompt: Option<&str>,
    ) -> Result<Option<MutationDispatch>, String> {
        if self.sync_config.is_some() {
            return self.start_turn_via_upstream(thread_id, prompt);
        }

        Ok(self.start_turn_stub(thread_id, prompt))
    }

    fn start_turn_stub(
        &mut self,
        thread_id: &str,
        prompt: Option<&str>,
    ) -> Option<MutationDispatch> {
        let prompt = prompt.unwrap_or("No prompt provided").trim();
        let prompt = if prompt.is_empty() {
            "No prompt provided"
        } else {
            prompt
        };
        let updated_at = self.next_timestamp();

        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            thread.lifecycle_state = "active".to_string();
            thread.last_turn_summary = format!("Started turn: {prompt}");
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let status_event = self.next_event(
            thread_id,
            BridgeEventKind::ThreadStatusChanged,
            json!({
                "status": "running",
                "reason": "turn_start",
                "prompt": prompt,
            }),
        );
        let message_event = self.next_event(
            thread_id,
            BridgeEventKind::MessageDelta,
            json!({
                "delta": format!("Started turn with prompt: {prompt}"),
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_start".to_string(),
                outcome: "success".to_string(),
                message: "Turn started and streaming is active".to_string(),
                thread_status,
                repository,
                status,
            },
            events: vec![status_event, message_event],
        })
    }

    fn start_turn_via_upstream(
        &mut self,
        thread_id: &str,
        prompt: Option<&str>,
    ) -> Result<Option<MutationDispatch>, String> {
        let prompt = normalize_turn_text(prompt, "No prompt provided");
        let mut client = self.codex_rpc_client()?;
        let started_turn = start_turn_with_resume(&mut client, thread_id, &prompt)?;
        let updated_at = current_timestamp_string();

        let (thread_status, repository, status) = {
            let Some(thread) = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)
            else {
                return Ok(None);
            };
            thread.lifecycle_state = "active".to_string();
            thread.last_turn_summary = format!("Started turn: {prompt}");
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        Ok(Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_start".to_string(),
                outcome: "success".to_string(),
                message: format!("Turn started ({})", started_turn.id),
                thread_status,
                repository,
                status,
            },
            events: Vec::new(),
        }))
    }

    pub fn steer_turn(
        &mut self,
        thread_id: &str,
        instruction: Option<&str>,
    ) -> Result<Option<MutationDispatch>, String> {
        if self.sync_config.is_some() {
            return self.steer_turn_via_upstream(thread_id, instruction);
        }

        Ok(self.steer_turn_stub(thread_id, instruction))
    }

    fn steer_turn_stub(
        &mut self,
        thread_id: &str,
        instruction: Option<&str>,
    ) -> Option<MutationDispatch> {
        let instruction = instruction.unwrap_or("Continue").trim();
        let instruction = if instruction.is_empty() {
            "Continue"
        } else {
            instruction
        };
        let updated_at = self.next_timestamp();

        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            thread.lifecycle_state = "active".to_string();
            thread.last_turn_summary = format!("Steer instruction: {instruction}");
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let event = self.next_event(
            thread_id,
            BridgeEventKind::PlanDelta,
            json!({
                "instruction": instruction,
                "phase": "steer",
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_steer".to_string(),
                outcome: "success".to_string(),
                message: "Steer instruction applied to active turn".to_string(),
                thread_status,
                repository,
                status,
            },
            events: vec![event],
        })
    }

    fn steer_turn_via_upstream(
        &mut self,
        thread_id: &str,
        instruction: Option<&str>,
    ) -> Result<Option<MutationDispatch>, String> {
        let instruction = normalize_turn_text(instruction, "Continue");
        let active_turn_id = self.resolve_active_turn_id(thread_id)?;
        let mut client = self.codex_rpc_client()?;
        let steered_turn_id = client.steer_turn(thread_id, &active_turn_id, &instruction)?;
        let updated_at = current_timestamp_string();

        let (thread_status, repository, status) = {
            let Some(thread) = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)
            else {
                return Ok(None);
            };
            thread.lifecycle_state = "active".to_string();
            thread.last_turn_summary = format!("Steer instruction: {instruction}");
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        Ok(Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_steer".to_string(),
                outcome: "success".to_string(),
                message: format!("Steer instruction sent to active turn ({steered_turn_id})"),
                thread_status,
                repository,
                status,
            },
            events: Vec::new(),
        }))
    }

    pub fn interrupt_turn(&mut self, thread_id: &str) -> Result<Option<MutationDispatch>, String> {
        if self.sync_config.is_some() {
            return self.interrupt_turn_via_upstream(thread_id);
        }

        Ok(self.interrupt_turn_stub(thread_id))
    }

    fn interrupt_turn_stub(&mut self, thread_id: &str) -> Option<MutationDispatch> {
        let updated_at = self.next_timestamp();
        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            thread.lifecycle_state = "halted".to_string();
            thread.last_turn_summary = "Interrupted active turn".to_string();
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let event = self.next_event(
            thread_id,
            BridgeEventKind::ThreadStatusChanged,
            json!({
                "status": "interrupted",
                "reason": "turn_interrupt",
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_interrupt".to_string(),
                outcome: "success".to_string(),
                message: "Interrupt signal sent to active turn".to_string(),
                thread_status,
                repository,
                status,
            },
            events: vec![event],
        })
    }

    fn interrupt_turn_via_upstream(
        &mut self,
        thread_id: &str,
    ) -> Result<Option<MutationDispatch>, String> {
        let active_turn_id = self.resolve_active_turn_id(thread_id)?;
        let mut client = self.codex_rpc_client()?;
        client.interrupt_turn(thread_id, &active_turn_id)?;
        let updated_at = current_timestamp_string();

        let (thread_status, repository, status) = {
            let Some(thread) = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)
            else {
                return Ok(None);
            };
            thread.lifecycle_state = "halted".to_string();
            thread.last_turn_summary = "Interrupted active turn".to_string();
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        Ok(Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "turn_interrupt".to_string(),
                outcome: "success".to_string(),
                message: "Interrupt signal sent to active turn".to_string(),
                thread_status,
                repository,
                status,
            },
            events: Vec::new(),
        }))
    }

    fn codex_rpc_client(&self) -> Result<CodexRpcClient, String> {
        let Some(sync_config) = &self.sync_config else {
            return Err("thread API is not configured for upstream Codex mutations".to_string());
        };

        CodexRpcClient::start(
            &sync_config.codex_command,
            &sync_config.codex_args,
            sync_config.codex_endpoint.as_deref(),
        )
    }

    fn resolve_active_turn_id(&self, thread_id: &str) -> Result<String, String> {
        let mut client = self.codex_rpc_client()?;
        let thread = read_thread_with_resume(&mut client, thread_id, true)?;
        thread
            .turns
            .last()
            .map(|turn| turn.id.clone())
            .ok_or_else(|| format!("no active turn found for thread {thread_id}"))
    }

    pub fn switch_branch(&mut self, thread_id: &str, branch: &str) -> Option<MutationDispatch> {
        let branch = branch.trim();
        if branch.is_empty() {
            return None;
        }
        let updated_at = self.next_timestamp();

        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            thread.branch_name = branch.to_string();
            thread.git_dirty = false;
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let event = self.next_event(
            thread_id,
            BridgeEventKind::CommandDelta,
            json!({
                "action": "git_branch_switch",
                "branch": branch,
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "git_branch_switch".to_string(),
                outcome: "success".to_string(),
                message: format!("Switched branch to {branch}"),
                thread_status,
                repository,
                status,
            },
            events: vec![event],
        })
    }

    pub fn pull_repo(&mut self, thread_id: &str, remote: Option<&str>) -> Option<MutationDispatch> {
        let updated_at = self.next_timestamp();
        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            if let Some(remote) = remote
                && !remote.trim().is_empty()
            {
                thread.remote_name = remote.trim().to_string();
            }
            thread.git_behind_by = 0;
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let event = self.next_event(
            thread_id,
            BridgeEventKind::CommandDelta,
            json!({
                "action": "git_pull",
                "remote": repository.remote,
                "branch": repository.branch,
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "git_pull".to_string(),
                outcome: "success".to_string(),
                message: format!(
                    "Pulled latest changes from {} for {}",
                    repository.remote, repository.branch
                ),
                thread_status,
                repository,
                status,
            },
            events: vec![event],
        })
    }

    pub fn push_repo(&mut self, thread_id: &str, remote: Option<&str>) -> Option<MutationDispatch> {
        let updated_at = self.next_timestamp();
        let (thread_status, repository, status) = {
            let thread = self
                .thread_records
                .iter_mut()
                .find(|thread| thread.id == thread_id)?;
            if let Some(remote) = remote
                && !remote.trim().is_empty()
            {
                thread.remote_name = remote.trim().to_string();
            }
            thread.git_ahead_by = 0;
            thread.updated_at = updated_at;

            (
                map_thread_status(&thread.lifecycle_state),
                map_repository_context(thread),
                map_git_status(thread),
            )
        };

        let event = self.next_event(
            thread_id,
            BridgeEventKind::CommandDelta,
            json!({
                "action": "git_push",
                "remote": repository.remote,
                "branch": repository.branch,
            }),
        );

        Some(MutationDispatch {
            response: MutationResultResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                operation: "git_push".to_string(),
                outcome: "success".to_string(),
                message: format!(
                    "Pushed local commits to {} for {}",
                    repository.remote, repository.branch
                ),
                thread_status,
                repository,
                status,
            },
            events: vec![event],
        })
    }

    fn next_event(
        &mut self,
        thread_id: &str,
        kind: BridgeEventKind,
        payload: Value,
    ) -> BridgeEventEnvelope<Value> {
        let occurred_at = self.next_timestamp();
        self.next_event_with_occurred_at(thread_id, kind, occurred_at.as_str(), payload)
    }

    fn next_event_with_occurred_at(
        &mut self,
        thread_id: &str,
        kind: BridgeEventKind,
        occurred_at: &str,
        payload: Value,
    ) -> BridgeEventEnvelope<Value> {
        let event_id = format!("evt-live-{}", self.next_event_sequence);
        self.next_event_sequence += 1;
        build_timeline_event_envelope(
            event_id,
            thread_id.to_string(),
            kind,
            occurred_at.to_string(),
            payload,
        )
    }

    fn next_timestamp(&mut self) -> String {
        let sequence = self.next_event_sequence;
        let minute = (sequence / 60) % 60;
        let second = sequence % 60;
        format!("2026-03-17T22:{minute:02}:{second:02}Z")
    }
}
