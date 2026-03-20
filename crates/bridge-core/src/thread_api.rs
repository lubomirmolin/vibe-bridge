use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto,
    ThreadStatus, ThreadSummaryDto, ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind, ThreadTimelinePageDto,
};

use crate::codex_transport::CodexJsonTransport;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamThreadRecord {
    pub id: String,
    pub headline: String,
    pub lifecycle_state: String,
    pub workspace_path: String,
    pub repository_name: String,
    pub branch_name: String,
    pub remote_name: String,
    pub git_dirty: bool,
    pub git_ahead_by: u32,
    pub git_behind_by: u32,
    pub created_at: String,
    pub updated_at: String,
    pub source: String,
    pub approval_mode: String,
    pub last_turn_summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamTimelineEvent {
    pub id: String,
    pub event_type: String,
    pub happened_at: String,
    pub summary_text: String,
    pub data: serde_json::Value,
}

type ThreadSnapshot = (
    Vec<UpstreamThreadRecord>,
    HashMap<String, Vec<UpstreamTimelineEvent>>,
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadApiService {
    thread_records: Vec<UpstreamThreadRecord>,
    timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    next_event_sequence: u64,
    sync_config: Option<ThreadSyncConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadListResponse {
    pub contract_version: String,
    pub threads: Vec<ThreadSummaryDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadDetailResponse {
    pub contract_version: String,
    pub thread: ThreadDetailDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepositoryContextDto {
    pub workspace: String,
    pub repository: String,
    pub branch: String,
    pub remote: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GitStatusDto {
    pub dirty: bool,
    pub ahead_by: u32,
    pub behind_by: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GitStatusResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub repository: RepositoryContextDto,
    pub status: GitStatusDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MutationResultResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub operation: String,
    pub outcome: String,
    pub message: String,
    pub thread_status: ThreadStatus,
    pub repository: RepositoryContextDto,
    pub status: GitStatusDto,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MutationDispatch {
    pub response: MutationResultResponse,
    pub events: Vec<BridgeEventEnvelope<Value>>,
}

impl ThreadApiService {
    pub fn empty() -> Self {
        Self::with_seed_data(Vec::new(), HashMap::new())
    }

    pub fn with_seed_data(
        thread_records: Vec<UpstreamThreadRecord>,
        timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    ) -> Self {
        Self {
            thread_records,
            timeline_by_thread_id,
            next_event_sequence: 10,
            sync_config: None,
        }
    }

    pub fn from_codex_app_server(
        command: &str,
        args: &[String],
        endpoint: Option<&str>,
    ) -> Result<Self, String> {
        let codex_home = resolve_codex_home_dir()?;
        let (thread_records, timeline_by_thread_id) =
            load_thread_snapshot(command, args, endpoint, &codex_home)?;

        Ok(Self {
            thread_records,
            timeline_by_thread_id,
            next_event_sequence: 10,
            sync_config: Some(ThreadSyncConfig {
                codex_command: command.to_string(),
                codex_args: args.to_vec(),
                codex_endpoint: endpoint.map(ToOwned::to_owned),
                codex_home,
            }),
        })
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
        Ok(())
    }

    pub fn sync_thread_from_upstream(&mut self, thread_id: &str) -> Result<(), String> {
        let Some(sync_config) = &self.sync_config else {
            return Ok(());
        };

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

#[derive(Debug, Clone, PartialEq, Eq)]
struct ThreadSyncConfig {
    codex_command: String,
    codex_args: Vec<String>,
    codex_endpoint: Option<String>,
    codex_home: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct SessionIndexEntry {
    id: String,
    #[serde(rename = "thread_name")]
    thread_name: String,
    updated_at: String,
}

fn resolve_codex_home_dir() -> Result<PathBuf, String> {
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

fn load_thread_snapshot(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    codex_home: &Path,
) -> Result<ThreadSnapshot, String> {
    let rpc_result = load_thread_snapshot_from_codex_rpc(command, args, endpoint);
    let archive_result = match &rpc_result {
        Ok((thread_records, _)) if !thread_records.is_empty() => {
            let requested_ids = thread_records
                .iter()
                .map(|record| record.id.clone())
                .collect::<HashSet<_>>();
            load_thread_snapshot_from_codex_archive_for_ids(codex_home, Some(&requested_ids))
        }
        _ => load_thread_snapshot_from_codex_archive(codex_home),
    };
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

fn load_thread_snapshot_for_id(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    codex_home: &Path,
    thread_id: &str,
) -> Result<ThreadSnapshot, String> {
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

fn merge_thread_snapshots(
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

        merged_timeline_by_thread_id.insert(thread_id.clone(), merged_timeline);
        merged_records.push(rpc_record);
        archive_records_by_id.remove(&thread_id);
    }

    for (thread_id, archive_record) in archive_records_by_id {
        if !seen_thread_ids.insert(thread_id.clone()) {
            continue;
        }

        merged_timeline_by_thread_id.insert(
            thread_id.clone(),
            archive_timeline_by_thread_id
                .get(&thread_id)
                .cloned()
                .unwrap_or_default(),
        );
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

fn merge_snapshot_timeline(
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
    // Keep equal-timestamp entries in source order so mixed event kinds from the
    // same snapshot stay grouped deterministically across pagination boundaries.
    events.sort_by(|left, right| left.happened_at.cmp(&right.happened_at));
    events
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
            format!("plan_delta\u{1f}|{text}")
        }
        _ => timeline_event_fingerprint(event),
    }
}

fn load_thread_snapshot_from_codex_rpc(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
) -> Result<ThreadSnapshot, String> {
    let mut client = CodexRpcClient::start(command, args, endpoint)?;
    let threads = client.fetch_all_threads()?;

    let thread_records = threads
        .iter()
        .map(map_codex_thread_to_upstream_record)
        .collect::<Vec<_>>();

    let timeline_by_thread_id = threads
        .iter()
        .map(|thread| {
            (
                thread.id.clone(),
                map_codex_thread_to_timeline_events(thread),
            )
        })
        .collect::<HashMap<_, _>>();

    Ok((thread_records, timeline_by_thread_id))
}

fn load_thread_snapshot_from_codex_rpc_for_id(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
    thread_id: &str,
) -> Result<Option<ThreadSnapshot>, String> {
    let mut client = CodexRpcClient::start(command, args, endpoint)?;
    let thread = match read_thread_with_resume(&mut client, thread_id, true) {
        Ok(thread) => thread,
        Err(error) if should_resume_thread(&error) || error.contains("not found") => {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };

    let thread_record = map_codex_thread_to_upstream_record(&thread);
    let timeline = map_codex_thread_to_timeline_events(&thread);
    let timeline_by_thread_id = HashMap::from([(thread.id.clone(), timeline)]);

    Ok(Some((vec![thread_record], timeline_by_thread_id)))
}

fn load_thread_snapshot_from_codex_archive(codex_home: &Path) -> Result<ThreadSnapshot, String> {
    load_thread_snapshot_from_codex_archive_for_ids(codex_home, None)
}

fn load_thread_snapshot_from_codex_archive_for_ids(
    codex_home: &Path,
    requested_ids: Option<&HashSet<String>>,
) -> Result<ThreadSnapshot, String> {
    let session_index_path = codex_home.join("session_index.jsonl");
    let sessions_root = codex_home.join("sessions");
    let raw_index = fs::read_to_string(&session_index_path).map_err(|error| {
        format!(
            "failed to read session index at {}: {error}",
            session_index_path.display()
        )
    })?;

    let mut entries = raw_index
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str::<SessionIndexEntry>(line)
                .map_err(|error| format!("failed to parse session index entry as JSON: {error}"))
        })
        .collect::<Result<Vec<_>, _>>()?;

    entries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    if let Some(requested_ids) = requested_ids {
        entries.retain(|entry| requested_ids.contains(&entry.id));
    } else {
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

        thread_records.push(parsed.0);
        timeline_by_thread_id.insert(entry.id, parsed.1);
    }

    Ok((thread_records, timeline_by_thread_id))
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
            &index_entry.id,
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
            id: index_entry.id.clone(),
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
            id: index_entry.id.clone(),
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

fn is_file_change_custom_tool(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "apply_patch" | "replace_file_content" | "multi_replace_file_content"
    ) || tool_name.contains("edit_file")
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchFile {
    path: String,
    output_path: String,
    change_type: ApplyPatchChangeType,
    hunks: Vec<ApplyPatchHunk>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApplyPatchChangeType {
    Modified,
    Added,
    Deleted,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchHunk {
    lines: Vec<ApplyPatchLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ApplyPatchLine {
    kind: ApplyPatchLineKind,
    text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApplyPatchLineKind {
    Context,
    Addition,
    Deletion,
}

fn resolve_apply_patch_to_unified_diff(
    patch_text: &str,
    workspace_path: Option<&str>,
) -> Option<String> {
    if !patch_text.contains("*** Begin Patch") {
        return None;
    }

    let patch_files = parse_apply_patch(patch_text);
    if patch_files.is_empty() {
        return None;
    }

    let mut rendered_files = Vec::new();
    for patch_file in patch_files {
        let rendered =
            render_resolved_apply_patch_file_as_unified_diff(&patch_file, workspace_path)?;
        rendered_files.push(rendered);
    }

    Some(rendered_files.join("\n"))
}

fn parse_apply_patch(patch_text: &str) -> Vec<ApplyPatchFile> {
    let mut files = Vec::new();
    let mut current_file: Option<ApplyPatchFile> = None;
    let mut current_hunk: Option<ApplyPatchHunk> = None;

    fn finish_hunk(
        current_file: &mut Option<ApplyPatchFile>,
        current_hunk: &mut Option<ApplyPatchHunk>,
    ) {
        if let Some(hunk) = current_hunk.take()
            && let Some(file) = current_file.as_mut()
            && !hunk.lines.is_empty()
        {
            file.hunks.push(hunk);
        }
    }

    fn finish_file(
        files: &mut Vec<ApplyPatchFile>,
        current_file: &mut Option<ApplyPatchFile>,
        current_hunk: &mut Option<ApplyPatchHunk>,
    ) {
        finish_hunk(current_file, current_hunk);
        if let Some(file) = current_file.take() {
            files.push(file);
        }
    }

    for raw_line in patch_text.lines() {
        if raw_line == "*** Begin Patch"
            || raw_line == "*** End Patch"
            || raw_line == "*** End of File"
        {
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Update File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Modified,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Add File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Added,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Delete File: ") {
            finish_file(&mut files, &mut current_file, &mut current_hunk);
            let normalized_path = path.trim().to_string();
            current_file = Some(ApplyPatchFile {
                output_path: normalized_path.clone(),
                path: normalized_path,
                change_type: ApplyPatchChangeType::Deleted,
                hunks: Vec::new(),
            });
            continue;
        }

        if let Some(path) = raw_line.strip_prefix("*** Move to: ") {
            if let Some(file) = current_file.as_mut() {
                file.output_path = path.trim().to_string();
            }
            continue;
        }

        if raw_line.starts_with("@@") {
            finish_hunk(&mut current_file, &mut current_hunk);
            current_hunk = Some(ApplyPatchHunk { lines: Vec::new() });
            continue;
        }

        let Some(file) = current_file.as_ref() else {
            continue;
        };
        let _ = file;

        let kind = if raw_line.starts_with('+') {
            Some(ApplyPatchLineKind::Addition)
        } else if raw_line.starts_with('-') {
            Some(ApplyPatchLineKind::Deletion)
        } else if raw_line.starts_with(' ') || raw_line.is_empty() {
            Some(ApplyPatchLineKind::Context)
        } else {
            None
        };

        if let Some(kind) = kind {
            let text = if raw_line.is_empty() {
                String::new()
            } else {
                raw_line[1..].to_string()
            };
            current_hunk
                .get_or_insert_with(|| ApplyPatchHunk { lines: Vec::new() })
                .lines
                .push(ApplyPatchLine { kind, text });
        }
    }

    finish_file(&mut files, &mut current_file, &mut current_hunk);
    files
}

fn render_resolved_apply_patch_file_as_unified_diff(
    patch_file: &ApplyPatchFile,
    workspace_path: Option<&str>,
) -> Option<String> {
    let old_lines = match patch_file.change_type {
        ApplyPatchChangeType::Added => Vec::new(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
            read_workspace_lines(workspace_path, &patch_file.path)?
        }
    };

    let mut rendered = Vec::new();
    rendered.push(format!(
        "diff --git a/{} b/{}",
        patch_file.path, patch_file.output_path
    ));
    rendered.push(match patch_file.change_type {
        ApplyPatchChangeType::Added => "--- /dev/null".to_string(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
            format!("--- a/{}", patch_file.path)
        }
    });
    rendered.push(match patch_file.change_type {
        ApplyPatchChangeType::Deleted => "+++ /dev/null".to_string(),
        ApplyPatchChangeType::Modified | ApplyPatchChangeType::Added => {
            format!("+++ b/{}", patch_file.output_path)
        }
    });

    if patch_file.hunks.is_empty() {
        match patch_file.change_type {
            ApplyPatchChangeType::Deleted => {
                let deleted_count = old_lines.len();
                if deleted_count > 0 {
                    rendered.push(format!("@@ -1,{} +0,0 @@", deleted_count));
                    for line in &old_lines {
                        rendered.push(format!("-{line}"));
                    }
                }
                return Some(rendered.join("\n"));
            }
            ApplyPatchChangeType::Added | ApplyPatchChangeType::Modified => {
                return None;
            }
        }
    }

    let mut search_start = 0usize;
    let mut line_delta: isize = 0;
    for hunk in &patch_file.hunks {
        let old_pattern = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Addition)
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>();

        let match_index = match patch_file.change_type {
            ApplyPatchChangeType::Added => 0,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
                locate_hunk_in_old_lines(&old_lines, &old_pattern, search_start)?
            }
        };

        let old_count = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Addition)
            .count();
        let new_count = hunk
            .lines
            .iter()
            .filter(|line| line.kind != ApplyPatchLineKind::Deletion)
            .count();

        let old_start = match patch_file.change_type {
            ApplyPatchChangeType::Added => 0,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => match_index + 1,
        };
        let new_start = match patch_file.change_type {
            ApplyPatchChangeType::Added => 1,
            ApplyPatchChangeType::Modified | ApplyPatchChangeType::Deleted => {
                (match_index as isize + line_delta + 1).max(0) as usize
            }
        };

        rendered.push(format!(
            "@@ -{},{} +{},{} @@",
            old_start, old_count, new_start, new_count
        ));
        for line in &hunk.lines {
            let prefix = match line.kind {
                ApplyPatchLineKind::Context => ' ',
                ApplyPatchLineKind::Addition => '+',
                ApplyPatchLineKind::Deletion => '-',
            };
            rendered.push(format!("{prefix}{}", line.text));
        }

        search_start = match_index.saturating_add(old_count);
        line_delta += new_count as isize - old_count as isize;
    }

    Some(rendered.join("\n"))
}

fn read_workspace_lines(workspace_path: Option<&str>, raw_path: &str) -> Option<Vec<String>> {
    let resolved_path = resolve_workspace_file_path(workspace_path, raw_path)?;
    let contents = fs::read_to_string(&resolved_path).ok()?;
    Some(contents.lines().map(normalize_line_ending).collect())
}

fn resolve_workspace_file_path(workspace_path: Option<&str>, raw_path: &str) -> Option<PathBuf> {
    let path = PathBuf::from(raw_path.trim());
    if path.is_absolute() {
        return Some(path);
    }

    let workspace = workspace_path?.trim();
    if workspace.is_empty() {
        return None;
    }

    Some(Path::new(workspace).join(path))
}

fn normalize_line_ending(line: &str) -> String {
    line.strip_suffix('\r').unwrap_or(line).to_string()
}

fn locate_hunk_in_old_lines(
    old_lines: &[String],
    old_pattern: &[&str],
    search_start: usize,
) -> Option<usize> {
    if old_pattern.is_empty() {
        return Some(search_start.min(old_lines.len()));
    }

    if old_pattern.len() > old_lines.len() {
        return None;
    }

    let normalized_pattern = old_pattern
        .iter()
        .map(|line| normalize_line_ending(line))
        .collect::<Vec<_>>();

    let max_start = old_lines.len().saturating_sub(normalized_pattern.len());
    for index in search_start..=max_start {
        if old_lines[index..index + normalized_pattern.len()]
            .iter()
            .zip(normalized_pattern.iter())
            .all(|(left, right)| left == right)
        {
            return Some(index);
        }
    }

    None
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
                if let Some(image_url) = item.get("image_url").and_then(Value::as_str)
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

fn is_file_change_text(text: &str) -> bool {
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

fn normalize_custom_tool_output(raw_output: &str) -> String {
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

fn is_hidden_archive_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
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

fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}

fn truncate_summary(text: &str) -> String {
    const MAX_CHARS: usize = 140;
    let trimmed = text.trim();
    if trimmed.chars().count() <= MAX_CHARS {
        return trimmed.to_string();
    }

    let mut summary = trimmed.chars().take(MAX_CHARS - 1).collect::<String>();
    summary.push_str("...");
    summary
}

fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

fn read_thread_with_resume(
    client: &mut CodexRpcClient,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThread, String> {
    match client.read_thread(thread_id, include_turns) {
        Ok(thread) => Ok(thread),
        Err(error) if should_resume_thread(&error) => {
            client.resume_thread(thread_id)?;
            client.read_thread(thread_id, include_turns)
        }
        Err(error) => Err(error),
    }
}

fn start_turn_with_resume(
    client: &mut CodexRpcClient,
    thread_id: &str,
    prompt: &str,
) -> Result<CodexTurn, String> {
    match client.start_turn(thread_id, prompt) {
        Ok(turn) => Ok(turn),
        Err(error) if should_resume_thread(&error) => {
            client.resume_thread(thread_id)?;
            client.start_turn(thread_id, prompt)
        }
        Err(error) => Err(error),
    }
}

fn normalize_turn_text(raw: Option<&str>, fallback: &str) -> String {
    let normalized = raw.unwrap_or(fallback).trim();
    if normalized.is_empty() {
        fallback.to_string()
    } else {
        normalized.to_string()
    }
}

fn text_user_input(text: &str) -> Value {
    json!({
        "type": "text",
        "text": text,
        "text_elements": [],
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadListResult {
    data: Vec<CodexThread>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadReadResult {
    thread: CodexThread,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnStartResult {
    turn: CodexTurn,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadResumeResult {
    thread: CodexThread,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnSteerResult {
    #[serde(rename = "turnId")]
    turn_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThread {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    preview: Option<String>,
    status: CodexThreadStatus,
    cwd: String,
    #[serde(rename = "gitInfo")]
    git_info: Option<CodexGitInfo>,
    #[serde(rename = "createdAt")]
    created_at: i64,
    #[serde(rename = "updatedAt")]
    updated_at: i64,
    #[serde(default)]
    source: Value,
    #[serde(default)]
    turns: Vec<CodexTurn>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadStatus {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexGitInfo {
    branch: Option<String>,
    #[serde(rename = "originUrl")]
    origin_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurn {
    id: String,
    #[serde(default)]
    items: Vec<Value>,
}

#[derive(Debug)]
struct CodexRpcClient {
    transport: CodexJsonTransport,
}

impl CodexRpcClient {
    const MAX_THREADS_TO_FETCH: usize = 50;

    fn start(command: &str, args: &[String], endpoint: Option<&str>) -> Result<Self, String> {
        Ok(Self {
            transport: CodexJsonTransport::start(command, args, endpoint)?,
        })
    }

    fn fetch_all_threads(&mut self) -> Result<Vec<CodexThread>, String> {
        let mut threads = Vec::new();
        let mut cursor: Option<String> = None;

        loop {
            if threads.len() >= Self::MAX_THREADS_TO_FETCH {
                break;
            }

            let mut params = serde_json::Map::new();
            if let Some(cursor) = &cursor {
                params.insert("cursor".to_string(), Value::String(cursor.clone()));
            }

            let result = self.request("thread/list", Value::Object(params))?;
            let response: CodexThreadListResult =
                serde_json::from_value(result).map_err(|error| {
                    format!("invalid thread/list response from codex app-server: {error}")
                })?;

            let remaining = Self::MAX_THREADS_TO_FETCH.saturating_sub(threads.len());
            for thread in response.data.into_iter().take(remaining) {
                let thread_id = thread.id.clone();
                match self.request(
                    "thread/read",
                    json!({
                        "threadId": thread_id,
                        "includeTurns": true,
                    }),
                ) {
                    Ok(read_result) => {
                        let read_response: CodexThreadReadResult =
                            serde_json::from_value(read_result).map_err(|error| {
                                format!(
                                    "invalid thread/read response from codex app-server: {error}"
                                )
                            })?;
                        threads.push(read_response.thread);
                    }
                    Err(_) => {
                        threads.push(thread);
                    }
                }
            }

            if let Some(next_cursor) = response.next_cursor {
                cursor = Some(next_cursor);
            } else {
                break;
            }
        }

        Ok(threads)
    }

    fn read_thread(&mut self, thread_id: &str, include_turns: bool) -> Result<CodexThread, String> {
        let result = self.request(
            "thread/read",
            json!({
                "threadId": thread_id,
                "includeTurns": include_turns,
            }),
        )?;
        let response: CodexThreadReadResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid thread/read response from codex app-server: {error}")
        })?;
        Ok(response.thread)
    }

    fn resume_thread(&mut self, thread_id: &str) -> Result<CodexThread, String> {
        let result = self.request(
            "thread/resume",
            json!({
                "threadId": thread_id,
            }),
        )?;
        let response: CodexThreadResumeResult =
            serde_json::from_value(result).map_err(|error| {
                format!("invalid thread/resume response from codex app-server: {error}")
            })?;
        Ok(response.thread)
    }

    fn start_turn(&mut self, thread_id: &str, prompt: &str) -> Result<CodexTurn, String> {
        let result = self.request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": [text_user_input(prompt)],
            }),
        )?;
        let response: CodexTurnStartResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid turn/start response from codex app-server: {error}")
        })?;
        Ok(response.turn)
    }

    fn steer_turn(
        &mut self,
        thread_id: &str,
        expected_turn_id: &str,
        instruction: &str,
    ) -> Result<String, String> {
        let result = self.request(
            "turn/steer",
            json!({
                "threadId": thread_id,
                "expectedTurnId": expected_turn_id,
                "input": [text_user_input(instruction)],
            }),
        )?;
        let response: CodexTurnSteerResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid turn/steer response from codex app-server: {error}")
        })?;
        Ok(response.turn_id)
    }

    fn interrupt_turn(&mut self, thread_id: &str, turn_id: &str) -> Result<(), String> {
        self.request(
            "turn/interrupt",
            json!({
                "threadId": thread_id,
                "turnId": turn_id,
            }),
        )?;
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.transport.request(method, params)
    }
}

#[derive(Debug)]
pub struct CodexNotificationStream {
    transport: CodexJsonTransport,
    normalizer: CodexNotificationNormalizer,
}

#[derive(Debug, Default)]
struct CodexNotificationNormalizer {
    active_turn_id_by_thread: HashMap<String, String>,
    items_by_event_id: HashMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexDeltaNotification {
    delta: String,
    #[serde(rename = "itemId")]
    item_id: String,
    #[serde(rename = "threadId")]
    thread_id: String,
    #[serde(rename = "turnId")]
    turn_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadStatusChangedNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    status: CodexThreadStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadRealtimeItemAddedNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    item: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    turn: CodexTurn,
}

impl CodexNotificationStream {
    pub fn start(command: &str, args: &[String], endpoint: Option<&str>) -> Result<Self, String> {
        Ok(Self {
            transport: CodexJsonTransport::start(command, args, endpoint)?,
            normalizer: CodexNotificationNormalizer::default(),
        })
    }

    pub fn next_event(&mut self) -> Result<Option<BridgeEventEnvelope<Value>>, String> {
        loop {
            let Some(message) = self.transport.next_message("notification")? else {
                return Ok(None);
            };

            if message.get("id").is_some() {
                continue;
            }

            let Some(method) = message.get("method").and_then(Value::as_str) else {
                continue;
            };
            let params = message.get("params").cloned().unwrap_or(Value::Null);

            if let Some(event) = self.normalizer.normalize(method, &params) {
                return Ok(Some(event));
            }
        }
    }
}

impl CodexNotificationNormalizer {
    fn normalize(&mut self, method: &str, params: &Value) -> Option<BridgeEventEnvelope<Value>> {
        match method {
            "turn/started" => {
                let notification: CodexTurnNotification =
                    serde_json::from_value(params.clone()).ok()?;
                self.active_turn_id_by_thread
                    .insert(notification.thread_id, notification.turn.id);
                None
            }
            "turn/completed" => {
                let notification: CodexTurnNotification =
                    serde_json::from_value(params.clone()).ok()?;
                if self
                    .active_turn_id_by_thread
                    .get(&notification.thread_id)
                    .is_some_and(|turn_id| turn_id == &notification.turn.id)
                {
                    self.active_turn_id_by_thread
                        .remove(&notification.thread_id);
                }
                None
            }
            "thread/status/changed" => {
                let notification: CodexThreadStatusChangedNotification =
                    serde_json::from_value(params.clone()).ok()?;
                let occurred_at = current_timestamp_string();
                Some(BridgeEventEnvelope::new(
                    format!("{}-status-{occurred_at}", notification.thread_id),
                    notification.thread_id,
                    BridgeEventKind::ThreadStatusChanged,
                    occurred_at,
                    json!({
                        "status": match map_thread_status(&map_codex_status_to_lifecycle_state(&notification.status.kind)) {
                            ThreadStatus::Idle => "idle",
                            ThreadStatus::Running => "running",
                            ThreadStatus::Completed => "completed",
                            ThreadStatus::Interrupted => "interrupted",
                            ThreadStatus::Failed => "failed",
                        },
                        "reason": "upstream_notification",
                    }),
                ))
            }
            "thread/realtime/itemAdded" => {
                let notification: CodexThreadRealtimeItemAddedNotification =
                    serde_json::from_value(params.clone()).ok()?;
                self.normalize_item_added(notification)
            }
            _ => parse_item_delta_method(method)
                .and_then(|(item_type, target)| self.normalize_delta(params, item_type, target)),
        }
    }

    fn normalize_item_added(
        &mut self,
        notification: CodexThreadRealtimeItemAddedNotification,
    ) -> Option<BridgeEventEnvelope<Value>> {
        let item_id = notification
            .item
            .get("id")
            .and_then(Value::as_str)?
            .to_string();
        let event_id = self.event_id_for_item(&notification.thread_id, &item_id);
        self.items_by_event_id
            .insert(event_id.clone(), notification.item.clone());

        let (kind, payload) = normalize_realtime_item_payload(&notification.item)?;
        if !should_publish_live_payload(kind, &payload) {
            return None;
        }
        Some(build_timeline_event_envelope(
            event_id,
            notification.thread_id,
            kind,
            current_timestamp_string(),
            payload,
        ))
    }

    fn normalize_delta(
        &mut self,
        params: &Value,
        item_type: &str,
        target: DeltaTarget,
    ) -> Option<BridgeEventEnvelope<Value>> {
        let notification: CodexDeltaNotification = serde_json::from_value(params.clone()).ok()?;
        let event_id = format!("{}-{}", notification.turn_id, notification.item_id);
        let payload = self
            .items_by_event_id
            .entry(event_id.clone())
            .or_insert_with(|| synthesize_realtime_item(item_type, &notification.item_id, target));

        apply_delta_to_item_payload(payload, &notification.delta, target);

        let (kind, normalized_payload) = normalize_realtime_item_payload(payload)?;
        if !should_publish_live_payload(kind, &normalized_payload) {
            return None;
        }
        Some(build_timeline_event_envelope(
            event_id,
            notification.thread_id,
            kind,
            current_timestamp_string(),
            normalized_payload,
        ))
    }

    fn event_id_for_item(&self, thread_id: &str, item_id: &str) -> String {
        self.active_turn_id_by_thread
            .get(thread_id)
            .map(|turn_id| format!("{turn_id}-{item_id}"))
            .unwrap_or_else(|| item_id.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DeltaTarget {
    Text,
    CommandOutput,
    FileDiff,
}

fn map_codex_thread_to_upstream_record(thread: &CodexThread) -> UpstreamThreadRecord {
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

fn map_codex_thread_to_timeline_events(thread: &CodexThread) -> Vec<UpstreamTimelineEvent> {
    let mut events = Vec::new();
    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let Some((kind, payload)) =
                normalize_codex_item_payload(item, Some(thread.cwd.as_str()))
            else {
                continue;
            };
            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));

            events.push(UpstreamTimelineEvent {
                id: format!("{}-{item_id}", turn.id),
                event_type: map_bridge_kind_to_event_type(kind).to_string(),
                happened_at: unix_timestamp_to_iso8601(thread.updated_at),
                summary_text: summarize_live_payload(kind, &payload),
                data: payload,
            });
        }
    }
    events
}

fn map_codex_status_to_lifecycle_state(status_kind: &str) -> String {
    match status_kind {
        "active" => "active".to_string(),
        "systemError" => "error".to_string(),
        _ => "idle".to_string(),
    }
}

fn parse_repository_name_from_origin(origin_url: &str) -> Option<String> {
    let trimmed = origin_url.trim_end_matches('/');
    let segment = trimmed
        .rsplit(['/', ':'])
        .next()
        .filter(|segment| !segment.is_empty())?;
    Some(segment.trim_end_matches(".git").to_string())
}

fn derive_repository_name_from_cwd(cwd: &str) -> Option<String> {
    Path::new(cwd)
        .file_name()
        .and_then(|name| name.to_str())
        .map(ToString::to_string)
}

fn map_thread_summary(upstream: &UpstreamThreadRecord) -> ThreadSummaryDto {
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

fn map_thread_detail(upstream: &UpstreamThreadRecord) -> ThreadDetailDto {
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

fn map_repository_context(upstream: &UpstreamThreadRecord) -> RepositoryContextDto {
    RepositoryContextDto {
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        remote: upstream.remote_name.clone(),
    }
}

fn map_git_status(upstream: &UpstreamThreadRecord) -> GitStatusDto {
    GitStatusDto {
        dirty: upstream.git_dirty,
        ahead_by: upstream.git_ahead_by,
        behind_by: upstream.git_behind_by,
    }
}

fn map_timeline_entry(upstream: &UpstreamTimelineEvent) -> ThreadTimelineEntryDto {
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

fn build_timeline_event_envelope(
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

fn map_thread_status(raw: &str) -> ThreadStatus {
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

fn map_event_kind(raw: &str) -> BridgeEventKind {
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

fn map_bridge_kind_to_event_type(kind: BridgeEventKind) -> &'static str {
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

fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
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

fn map_wire_thread_status_to_lifecycle_state(raw: &str) -> String {
    match raw {
        "running" => "active".to_string(),
        "completed" => "done".to_string(),
        "interrupted" => "halted".to_string(),
        "failed" => "error".to_string(),
        _ => "idle".to_string(),
    }
}

fn current_timestamp_string() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    unix_timestamp_to_iso8601(now)
}

fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
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

fn normalize_realtime_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    normalize_codex_item_payload(item, None)
}

fn should_publish_live_payload(kind: BridgeEventKind, payload: &Value) -> bool {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => {
            payload
                .get("text")
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("content")
                    .and_then(Value::as_array)
                    .is_some_and(|content| !content.is_empty())
        }
        BridgeEventKind::CommandDelta => {
            payload
                .get("output")
                .or_else(|| payload.get("aggregatedOutput"))
                .or_else(|| payload.get("command"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload.get("arguments").is_some()
        }
        BridgeEventKind::FileChange => {
            payload
                .get("resolved_unified_diff")
                .or_else(|| payload.get("output"))
                .or_else(|| payload.get("change"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("changes")
                    .and_then(Value::as_array)
                    .is_some_and(|changes| !changes.is_empty())
        }
        _ => true,
    }
}

fn normalize_codex_item_payload(
    item: &Value,
    workspace_path: Option<&str>,
) -> Option<(BridgeEventKind, Value)> {
    let item_type = canonicalize_codex_item_type(item.get("type").and_then(Value::as_str)?);
    match item_type {
        "userMessage" | "agentMessage" => Some((BridgeEventKind::MessageDelta, item.clone())),
        "plan" => Some((BridgeEventKind::PlanDelta, item.clone())),
        "commandExecution" => {
            let mut payload = item.clone();
            if let Some(output) = item.get("aggregatedOutput").and_then(Value::as_str)
                && let Some(object) = payload.as_object_mut()
            {
                object.insert("output".to_string(), Value::String(output.to_string()));
            }
            Some((BridgeEventKind::CommandDelta, payload))
        }
        "fileChange" => Some((BridgeEventKind::FileChange, item.clone())),
        "functionCall" | "customToolCall" => {
            normalize_codex_tool_invocation_item(item, workspace_path)
        }
        "functionCallOutput" | "customToolCallOutput" => normalize_codex_tool_output_item(item),
        _ => None,
    }
}

fn canonicalize_codex_item_type(item_type: &str) -> &str {
    match item_type {
        "function_call" => "functionCall",
        "function_call_output" => "functionCallOutput",
        "custom_tool_call" => "customToolCall",
        "custom_tool_call_output" => "customToolCallOutput",
        other => other,
    }
}

fn normalize_codex_tool_invocation_item(
    item: &Value,
    workspace_path: Option<&str>,
) -> Option<(BridgeEventKind, Value)> {
    let tool_name = item
        .get("name")
        .and_then(Value::as_str)
        .or_else(|| item.get("command").and_then(Value::as_str))
        .unwrap_or("command");
    let input = item
        .get("input")
        .cloned()
        .or_else(|| item.get("arguments").cloned())
        .unwrap_or(Value::Null);
    let input_text = value_to_text(&input).unwrap_or_default();
    let is_file_change = is_file_change_custom_tool(tool_name) || is_file_change_text(&input_text);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("command".to_string(), Value::String(tool_name.to_string()));
        if is_file_change {
            if !input_text.trim().is_empty() {
                object.insert("change".to_string(), Value::String(input_text.clone()));
            }
            if !object.contains_key("resolved_unified_diff")
                && let Some(resolved_diff) =
                    resolve_apply_patch_to_unified_diff(&input_text, workspace_path)
            {
                object.insert(
                    "resolved_unified_diff".to_string(),
                    Value::String(resolved_diff),
                );
            }
        } else if !object.contains_key("arguments") {
            object.insert("arguments".to_string(), input);
        }
    }

    Some((
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        payload,
    ))
}

fn normalize_codex_tool_output_item(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let output = item
        .get("output")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized_output = normalize_custom_tool_output(output);
    let is_file_change = is_file_change_text(&normalized_output);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("output".to_string(), Value::String(normalized_output));
    }

    Some((
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        payload,
    ))
}

fn parse_item_delta_method(method: &str) -> Option<(&str, DeltaTarget)> {
    let mut parts = method.split('/');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some("item"), Some(item_type), Some("delta"), None) => Some((
            item_type,
            match canonicalize_codex_item_type(item_type) {
                "agentMessage" | "userMessage" | "plan" => DeltaTarget::Text,
                "fileChange" => DeltaTarget::FileDiff,
                _ => DeltaTarget::Text,
            },
        )),
        (Some("item"), Some(item_type), Some("outputDelta"), None) => Some((
            item_type,
            match canonicalize_codex_item_type(item_type) {
                "fileChange" => DeltaTarget::FileDiff,
                _ => DeltaTarget::CommandOutput,
            },
        )),
        _ => None,
    }
}

fn synthesize_realtime_item(item_type: &str, item_id: &str, target: DeltaTarget) -> Value {
    match target {
        DeltaTarget::Text => json!({
            "id": item_id,
            "type": item_type,
            "text": "",
        }),
        DeltaTarget::CommandOutput => json!({
            "id": item_id,
            "type": item_type,
            "output": "",
            "aggregatedOutput": "",
            "status": "inProgress",
            "command": "",
            "cwd": "",
            "commandActions": [],
        }),
        DeltaTarget::FileDiff => json!({
            "id": item_id,
            "type": item_type,
            "resolved_unified_diff": "",
            "status": "inProgress",
            "changes": [],
        }),
    }
}

fn apply_delta_to_item_payload(item: &mut Value, delta: &str, target: DeltaTarget) {
    let Some(object) = item.as_object_mut() else {
        return;
    };

    match target {
        DeltaTarget::Text => {
            let next_text = format!(
                "{}{}",
                object
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta
            );
            object.insert("text".to_string(), Value::String(next_text));
        }
        DeltaTarget::CommandOutput => {
            let next_output = format!(
                "{}{}",
                object
                    .get("aggregatedOutput")
                    .or_else(|| object.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta
            );
            object.insert(
                "aggregatedOutput".to_string(),
                Value::String(next_output.clone()),
            );
            object.insert("output".to_string(), Value::String(next_output));
        }
        DeltaTarget::FileDiff => {
            let next_diff = format!(
                "{}{}",
                object
                    .get("resolved_unified_diff")
                    .or_else(|| object.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta
            );
            object.insert(
                "resolved_unified_diff".to_string(),
                Value::String(next_diff.clone()),
            );
            object.insert("output".to_string(), Value::String(next_diff));
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::fs;
    use std::path::PathBuf;

    use super::{
        CodexNotificationNormalizer, CodexThread, CodexThreadStatus, CodexTurn, ThreadApiService,
        ThreadSyncConfig, UpstreamThreadRecord, UpstreamTimelineEvent, should_resume_thread,
    };
    use serde_json::{Value, json};
    use shared_contracts::{
        AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadStatus,
        ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
    };

    #[test]
    fn list_and_detail_responses_normalize_upstream_thread_shapes() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-abc".to_string(),
                headline: "Normalize thread payloads".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: true,
                git_ahead_by: 1,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "read_only".to_string(),
                last_turn_summary: "started normalization".to_string(),
            }],
            HashMap::new(),
        );

        let list = service.list_response();
        assert_eq!(list.contract_version, CONTRACT_VERSION);
        assert_eq!(list.threads[0].thread_id, "thread-abc");
        assert_eq!(list.threads[0].status, ThreadStatus::Running);

        let detail = service
            .detail_response("thread-abc")
            .expect("detail response should exist");
        assert_eq!(detail.thread.access_mode, AccessMode::ReadOnly);
        assert_eq!(detail.thread.last_turn_summary, "started normalization");
    }

    #[test]
    fn timeline_page_response_normalizes_event_kinds() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-abc".to_string(),
                headline: "Normalize stream payloads".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "streaming".to_string(),
            }],
            HashMap::from([(
                "thread-abc".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-abc".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "command output".to_string(),
                    data: serde_json::json!({ "delta": "line" }),
                }],
            )]),
        );

        let timeline = service
            .timeline_page_response("thread-abc", None, 50)
            .expect("timeline response should exist");

        assert_eq!(timeline.contract_version, CONTRACT_VERSION);
        assert_eq!(timeline.entries.len(), 1);
        assert_eq!(timeline.entries[0].kind, BridgeEventKind::CommandDelta);
        assert_eq!(timeline.thread.thread_id, "thread-abc");
    }

    #[test]
    fn timeline_page_response_adds_exploration_annotations_without_mutating_payload() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-abc".to_string(),
                headline: "Normalize stream payloads".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "streaming".to_string(),
            }],
            HashMap::from([(
                "thread-abc".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "turn-123-tool-1".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "search output".to_string(),
                        data: json!({
                            "id": "tool-1",
                            "command": "exec_command",
                            "arguments": {"cmd": "rg -n timeline crates/bridge-core/src/thread_api.rs"},
                        }),
                    },
                    UpstreamTimelineEvent {
                        id: "turn-123-tool-2".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:01Z".to_string(),
                        summary_text: "read output".to_string(),
                        data: json!({
                            "id": "tool-2",
                            "command": "exec_command",
                            "arguments": {"cmd": "sed -n 1,20p crates/bridge-core/src/thread_api.rs"},
                        }),
                    },
                ],
            )]),
        );

        let timeline = service
            .timeline_page_response("thread-abc", None, 50)
            .expect("timeline response should exist");

        let search_annotations = timeline.entries[0]
            .annotations
            .as_ref()
            .expect("search entry should include annotations");
        assert_eq!(
            search_annotations.group_kind,
            Some(ThreadTimelineGroupKind::Exploration)
        );
        assert_eq!(
            search_annotations.group_id.as_deref(),
            Some("exploration:turn-123")
        );
        assert_eq!(
            search_annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Search)
        );
        assert_eq!(search_annotations.entry_label.as_deref(), Some("Search"));
        assert!(timeline.entries[0].payload.get("presentation").is_none());

        let read_annotations = timeline.entries[1]
            .annotations
            .as_ref()
            .expect("read entry should include annotations");
        assert_eq!(
            read_annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Read)
        );
        assert_eq!(
            read_annotations.entry_label.as_deref(),
            Some("Read thread_api.rs")
        );
        assert!(timeline.entries[1].payload.get("presentation").is_none());
    }

    #[test]
    fn timeline_page_response_for_existing_thread_without_events_returns_empty_payload() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-empty".to_string(),
                headline: "Thread without timeline events".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "No turns yet".to_string(),
            }],
            HashMap::new(),
        );

        let timeline = service
            .timeline_page_response("thread-empty", None, 50)
            .expect("existing thread should return timeline payload");

        assert_eq!(timeline.thread.thread_id, "thread-empty");
        assert!(timeline.entries.is_empty());
        assert_eq!(timeline.next_before, None);
        assert!(!timeline.has_more_before);
    }

    #[test]
    fn timeline_page_response_applies_before_cursor_and_limit() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-page".to_string(),
                headline: "Paged timeline".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "streaming".to_string(),
            }],
            HashMap::from([(
                "thread-page".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-1".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:01:00Z".to_string(),
                        summary_text: "one".to_string(),
                        data: json!({"delta": "one"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-2".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:02:00Z".to_string(),
                        summary_text: "two".to_string(),
                        data: json!({"delta": "two"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-3".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:03:00Z".to_string(),
                        summary_text: "three".to_string(),
                        data: json!({"delta": "three"}),
                    },
                ],
            )]),
        );

        let newest_page = service
            .timeline_page_response("thread-page", None, 2)
            .expect("timeline page should exist");
        assert_eq!(
            newest_page
                .entries
                .iter()
                .map(|entry| entry.event_id.as_str())
                .collect::<Vec<_>>(),
            vec!["evt-2", "evt-3"]
        );
        assert_eq!(newest_page.next_before.as_deref(), Some("evt-2"));
        assert!(newest_page.has_more_before);

        let older_page = service
            .timeline_page_response("thread-page", newest_page.next_before.as_deref(), 2)
            .expect("older page should exist");
        assert_eq!(
            older_page
                .entries
                .iter()
                .map(|entry| entry.event_id.as_str())
                .collect::<Vec<_>>(),
            vec!["evt-1"]
        );
        assert_eq!(older_page.next_before, None);
        assert!(!older_page.has_more_before);
    }

    #[test]
    fn reconcile_snapshot_preserves_mixed_event_order_for_equal_timestamps() {
        let thread = UpstreamThreadRecord {
            id: "thread-mixed".to_string(),
            headline: "Mixed events".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "mixed".to_string(),
        };

        let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], HashMap::new());
        let _ = service.reconcile_snapshot(
            vec![thread],
            HashMap::from([(
                "thread-mixed".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-2".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "message".to_string(),
                        data: json!({"delta": "message"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-10".to_string(),
                        event_type: "file_change_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "file".to_string(),
                        data: json!({"change": "file"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-1".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "command".to_string(),
                        data: json!({"output": "command"}),
                    },
                ],
            )]),
        );

        let page = service
            .timeline_page_response("thread-mixed", None, 50)
            .expect("timeline page should exist");
        assert_eq!(
            page.entries
                .iter()
                .map(|entry| entry.event_id.as_str())
                .collect::<Vec<_>>(),
            vec!["evt-2", "evt-10", "evt-1"]
        );
        assert_eq!(
            page.entries
                .iter()
                .map(|entry| entry.kind)
                .collect::<Vec<_>>(),
            vec![
                BridgeEventKind::MessageDelta,
                BridgeEventKind::FileChange,
                BridgeEventKind::CommandDelta,
            ]
        );
    }

    #[test]
    fn equal_timestamp_pagination_cursors_advance_past_internal_only_window() {
        let thread = UpstreamThreadRecord {
            id: "thread-page-stability".to_string(),
            headline: "Cursor stability".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "cursor".to_string(),
        };

        let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], HashMap::new());
        let _ = service.reconcile_snapshot(
            vec![thread],
            HashMap::from([(
                "thread-page-stability".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-1".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "oldest visible".to_string(),
                        data: json!({"delta": "oldest visible"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-2".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "internal-only-1".to_string(),
                        data: json!({"internal": true}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-10".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "internal-only-2".to_string(),
                        data: json!({"internal": true}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-11".to_string(),
                        event_type: "file_change_delta".to_string(),
                        happened_at: "2026-03-17T10:06:00Z".to_string(),
                        summary_text: "newest visible".to_string(),
                        data: json!({"change": "newest visible"}),
                    },
                ],
            )]),
        );

        let newest_page = service
            .timeline_page_response("thread-page-stability", None, 1)
            .expect("newest page should exist");
        assert_eq!(newest_page.entries[0].event_id, "evt-11");
        assert_eq!(newest_page.next_before.as_deref(), Some("evt-11"));

        let internal_only_page = service
            .timeline_page_response(
                "thread-page-stability",
                newest_page.next_before.as_deref(),
                2,
            )
            .expect("internal page should exist");
        assert_eq!(
            internal_only_page
                .entries
                .iter()
                .map(|entry| entry.event_id.as_str())
                .collect::<Vec<_>>(),
            vec!["evt-2", "evt-10"]
        );
        assert_eq!(internal_only_page.next_before.as_deref(), Some("evt-2"));

        let oldest_visible_page = service
            .timeline_page_response(
                "thread-page-stability",
                internal_only_page.next_before.as_deref(),
                2,
            )
            .expect("oldest visible page should exist");
        assert_eq!(oldest_visible_page.entries.len(), 1);
        assert_eq!(oldest_visible_page.entries[0].event_id, "evt-1");
        assert_eq!(oldest_visible_page.next_before, None);
        assert!(!oldest_visible_page.has_more_before);
    }

    #[test]
    fn turn_mutations_produce_normalized_result_and_events() {
        let mut service = ThreadApiService::sample();

        let dispatch = service
            .start_turn("thread-123", Some("Investigate websocket routing"))
            .expect("turn mutation should not fail")
            .expect("thread should exist");

        assert_eq!(dispatch.response.operation, "turn_start");
        assert_eq!(dispatch.response.thread_status, ThreadStatus::Running);
        assert_eq!(dispatch.events.len(), 2);
        assert_eq!(
            dispatch.events[0].kind,
            BridgeEventKind::ThreadStatusChanged
        );
        assert_eq!(dispatch.events[0].thread_id, "thread-123");
    }

    #[test]
    fn thread_not_found_errors_trigger_resume_retry() {
        assert!(should_resume_thread(
            "codex rpc request 'turn/start' failed: thread not found: thread-123"
        ));
        assert!(!should_resume_thread(
            "codex rpc request 'turn/start' failed: rate limited"
        ));
    }

    #[test]
    fn git_mutations_retarget_repo_context_by_thread() {
        let mut service = ThreadApiService::sample();

        let first = service
            .switch_branch("thread-123", "feature/stream-router")
            .expect("first thread should exist");
        let second = service
            .push_repo("thread-456", Some("origin"))
            .expect("second thread should exist");

        assert_eq!(
            first.response.repository.repository,
            "codex-mobile-companion"
        );
        assert_eq!(first.response.repository.branch, "feature/stream-router");
        assert_eq!(second.response.repository.repository, "codex-runtime-tools");
        assert_eq!(second.response.repository.remote, "origin");

        let first_status = service
            .git_status_response("thread-123")
            .expect("status should exist for thread-123");
        assert_eq!(first_status.repository.branch, "feature/stream-router");
    }

    #[test]
    fn archived_codex_sessions_load_as_thread_fallback() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-1","thread_name":"Investigate fallback","updated_at":"2026-03-19T09:00:00Z"}"#,
        )
        .expect("session index should be writable");
        fs::write(
            sessions_directory.join("rollout-2026-03-19T09-00-00-thread-archive-1.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-19T08:55:00Z","type":"session_meta","payload":{"id":"thread-archive-1","timestamp":"2026-03-19T08:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T08:56:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Working through archive fallback."}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T08:57:00Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"pwd\"]}"}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let (threads, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].id, "thread-archive-1");
        assert_eq!(threads[0].headline, "Investigate fallback");
        assert_eq!(threads[0].repository_name, "project");
        assert_eq!(threads[0].branch_name, "main");
        assert_eq!(threads[0].workspace_path, "/Users/test/workspace");
        assert_eq!(threads[0].source, "cli");

        let thread_timeline = timeline
            .get("thread-archive-1")
            .expect("timeline should exist for archived thread");
        assert_eq!(thread_timeline.len(), 2);
        assert_eq!(thread_timeline[0].event_type, "agent_message_delta");
        assert_eq!(thread_timeline[1].event_type, "command_output_delta");

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn archived_custom_tool_file_changes_map_to_file_change_events() {
        let codex_home = unique_test_codex_home();
        let workspace_directory = codex_home.join("workspace");
        fs::create_dir_all(workspace_directory.join("lib"))
            .expect("test workspace directory should exist");
        let workspace_file = workspace_directory.join("lib/main.dart");
        let mut workspace_lines = (1..95)
            .map(|index| format!("line {index}"))
            .collect::<Vec<_>>();
        workspace_lines.push("old".to_string());
        workspace_lines.push("line 96".to_string());
        fs::write(&workspace_file, format!("{}\n", workspace_lines.join("\n")))
            .expect("workspace file should be writable");

        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-tools","thread_name":"Apply patch fallback","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");

        let session_path =
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-tools.jsonl");
        let entries = vec![
            json!({
                "timestamp":"2026-03-19T09:55:00Z",
                "type":"session_meta",
                "payload":{
                    "id":"thread-archive-tools",
                    "timestamp":"2026-03-19T09:55:00Z",
                    "cwd":workspace_directory,
                    "source":"cli",
                    "git":{"branch":"main","repository_url":"git@github.com:example/project.git"}
                }
            }),
            json!({
                "timestamp":"2026-03-19T09:56:00Z",
                "type":"response_item",
                "payload":{
                    "type":"custom_tool_call",
                    "name":"apply_patch",
                    "call_id":"call-1",
                    "input":format!(
                        "*** Begin Patch\n*** Update File: {}\n@@\n-old\n+new\n*** End Patch\n",
                        workspace_file.display()
                    )
                }
            }),
            json!({
                "timestamp":"2026-03-19T09:57:00Z",
                "type":"response_item",
                "payload":{
                    "type":"custom_tool_call_output",
                    "call_id":"call-1",
                    "output":format!(
                        "{{\"output\":\"Success. Updated the following files:\\nM {}\\n\",\"metadata\":{{\"exit_code\":0}}}}",
                        workspace_file.display()
                    )
                }
            }),
        ];
        let content = entries
            .into_iter()
            .map(|entry| entry.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(session_path, format!("{content}\n")).expect("session log should be writable");

        let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        let thread_timeline = timeline
            .get("thread-archive-tools")
            .expect("timeline should exist for archived thread");
        assert_eq!(thread_timeline.len(), 2);
        assert_eq!(thread_timeline[0].event_type, "file_change_delta");
        assert_eq!(thread_timeline[1].event_type, "file_change_delta");
        assert_eq!(
            thread_timeline[0]
                .data
                .get("resolved_unified_diff")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            format!(
                "diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -95,1 +95,1 @@\n-old\n+new",
                path = workspace_file.display()
            )
        );
        assert_eq!(
            thread_timeline[1]
                .data
                .get("output")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            format!(
                "Success. Updated the following files:\nM {}\n",
                workspace_file.display()
            )
        );

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn archived_delete_file_patch_resolves_to_deleted_unified_diff() {
        let codex_home = unique_test_codex_home();
        let workspace_directory = codex_home.join("workspace");
        let target_directory = workspace_directory.join("apps/mobile/test/features/threads");
        fs::create_dir_all(&target_directory).expect("test workspace directory should exist");
        let deleted_file = target_directory.join("thread_live_timeline_regression_test.dart");
        fs::write(&deleted_file, "alpha\nbeta\ngamma\n")
            .expect("deleted file fixture should be writable");

        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-delete","thread_name":"Delete file fallback","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");

        let session_path =
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-delete.jsonl");
        let entries = vec![
            json!({
                "timestamp":"2026-03-19T09:55:00Z",
                "type":"session_meta",
                "payload":{
                    "id":"thread-archive-delete",
                    "timestamp":"2026-03-19T09:55:00Z",
                    "cwd":workspace_directory,
                    "source":"cli",
                    "git":{"branch":"main","repository_url":"git@github.com:example/project.git"}
                }
            }),
            json!({
                "timestamp":"2026-03-19T09:56:00Z",
                "type":"response_item",
                "payload":{
                    "type":"custom_tool_call",
                    "name":"apply_patch",
                    "call_id":"call-delete",
                    "input":format!(
                        "*** Begin Patch\n*** Delete File: {}\n*** End Patch\n",
                        deleted_file.display()
                    )
                }
            }),
        ];
        let content = entries
            .into_iter()
            .map(|entry| entry.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(session_path, format!("{content}\n")).expect("session log should be writable");

        let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        let thread_timeline = timeline
            .get("thread-archive-delete")
            .expect("timeline should exist for archived thread");
        assert_eq!(thread_timeline.len(), 1);
        assert_eq!(thread_timeline[0].event_type, "file_change_delta");
        assert_eq!(
            thread_timeline[0]
                .data
                .get("resolved_unified_diff")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            format!(
                "diff --git a/{path} b/{path}\n--- a/{path}\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-alpha\n-beta\n-gamma",
                path = deleted_file.display()
            )
        );

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn archived_sessions_hide_internal_messages_and_deduplicate_assistant_text() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-filtered","thread_name":"Filter internal records","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");
        fs::write(
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-filtered.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-filtered","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<collaboration_mode>Default</collaboration_mode>"}]}}"#,
                "\n",
                r##"{"timestamp":"2026-03-19T09:56:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/test/workspace"}]}}"##,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:01.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the duplicated thread messages.\n"}]}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:02Z","type":"event_msg","payload":{"type":"user_message","message":"Fix the duplicated thread messages.\n"}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Tracing the archive parser now."}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tracing the archive parser now."}]}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:05Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        let thread_timeline = timeline
            .get("thread-archive-filtered")
            .expect("timeline should exist for archived thread");

        assert_eq!(thread_timeline.len(), 3);
        assert_eq!(thread_timeline[0].event_type, "agent_message_delta");
        assert_eq!(
            thread_timeline[0]
                .data
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            "userMessage"
        );
        assert_eq!(thread_timeline[1].event_type, "agent_message_delta");
        assert_eq!(
            thread_timeline[1]
                .data
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            "assistant"
        );
        assert_eq!(thread_timeline[2].event_type, "command_output_delta");

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn archived_sessions_keep_visible_user_messages_when_event_msg_is_missing() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-legacy","thread_name":"Legacy archive session","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");
        fs::write(
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-legacy.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-legacy","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain the reconnect issue.\n"}]}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tracing the reconnect path."}]}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        let thread_timeline = timeline
            .get("thread-archive-legacy")
            .expect("timeline should exist for archived thread");

        assert_eq!(thread_timeline.len(), 2);
        assert_eq!(thread_timeline[0].data["type"], "userMessage");
        assert_eq!(thread_timeline[1].data["type"], "agentMessage");

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn archive_loader_can_fetch_requested_thread_outside_latest_archive_window() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");

        let mut session_index_entries = Vec::new();
        for index in 0..12 {
            let thread_id = if index == 11 {
                "thread-target".to_string()
            } else {
                format!("thread-{index}")
            };
            session_index_entries.push(format!(
                "{{\"id\":\"{thread_id}\",\"thread_name\":\"Thread {index}\",\"updated_at\":\"2026-03-19T10:{index:02}:00Z\"}}"
            ));

            fs::write(
                sessions_directory.join(format!(
                    "rollout-2026-03-19T10-{index:02}-00-{thread_id}.jsonl"
                )),
                format!(
                    "{{\"timestamp\":\"2026-03-19T10:{index:02}:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{thread_id}\",\"timestamp\":\"2026-03-19T10:{index:02}:00Z\",\"cwd\":\"/Users/test/workspace\",\"source\":\"cli\",\"git\":{{\"branch\":\"main\",\"repository_url\":\"git@github.com:example/project.git\"}}}}}}\n\
{{\"timestamp\":\"2026-03-19T10:{index:02}:30Z\",\"type\":\"response_item\",\"payload\":{{\"type\":\"function_call_output\",\"output\":\"Command: echo target-{index}\\nOutput:\\ntarget-{index}\"}}}}\n",
                ),
            )
            .expect("session log should be writable");
        }

        fs::write(
            codex_home.join("session_index.jsonl"),
            session_index_entries.join("\n"),
        )
        .expect("session index should be writable");

        let requested_ids = HashSet::from(["thread-target".to_string()]);
        let (_, timeline_by_thread_id) = super::load_thread_snapshot_from_codex_archive_for_ids(
            &codex_home,
            Some(&requested_ids),
        )
        .expect("requested archive snapshot should load");

        let timeline = timeline_by_thread_id
            .get("thread-target")
            .expect("requested thread timeline should be present");
        assert_eq!(timeline.len(), 1);
        assert_eq!(timeline[0].event_type, "command_output_delta");
        assert!(
            timeline[0]
                .data
                .get("output")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .contains("target-11")
        );

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    #[ignore]
    fn debug_local_archive_thread_event_mix() {
        let codex_home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .expect("HOME should be set")
            .join(".codex");
        let thread_id = std::env::var("CODEX_DEBUG_THREAD_ID")
            .unwrap_or_else(|_| "019d0b18-30e3-7240-9e27-e6766967d061".to_string());
        let requested_ids = HashSet::from([thread_id.clone()]);
        let (_, timeline_by_thread_id) = super::load_thread_snapshot_from_codex_archive_for_ids(
            &codex_home,
            Some(&requested_ids),
        )
        .expect("archive snapshot should load");

        let timeline = timeline_by_thread_id
            .get(&thread_id)
            .expect("timeline should exist");
        let mut counts = HashMap::new();
        for event in timeline {
            *counts.entry(event.event_type.clone()).or_insert(0usize) += 1;
        }
        eprintln!("timeline count={} counts={counts:?}", timeline.len());
        let latest_page = timeline.iter().rev().take(80).cloned().collect::<Vec<_>>();
        let mut latest_counts = HashMap::new();
        for event in latest_page.iter().rev() {
            *latest_counts
                .entry(event.event_type.clone())
                .or_insert(0usize) += 1;
        }
        eprintln!(
            "latest_page_count={} counts={latest_counts:?}",
            latest_page.len()
        );
        for event in latest_page.iter().take(15) {
            eprintln!(
                "latest page event: {} {}",
                event.event_type, event.summary_text
            );
        }
        for event in timeline
            .iter()
            .filter(|event| event.event_type != "agent_message_delta")
            .take(5)
        {
            eprintln!(
                "non-message event: {} {}",
                event.event_type, event.summary_text
            );
        }
    }

    #[test]
    #[ignore]
    fn debug_live_snapshot_thread_event_mix() {
        let thread_id = std::env::var("CODEX_DEBUG_THREAD_ID")
            .unwrap_or_else(|_| "019d0b18-30e3-7240-9e27-e6766967d061".to_string());
        let service = ThreadApiService::from_codex_app_server(
            "/Users/lubomirmolin/.bun/bin/codex",
            &[],
            None,
        )
        .expect("live snapshot should load");
        let timeline = service
            .timeline_by_thread_id
            .get(&thread_id)
            .expect("timeline should exist");
        let mut counts = HashMap::new();
        for event in timeline {
            *counts.entry(event.event_type.clone()).or_insert(0usize) += 1;
        }
        eprintln!("live snapshot count={} counts={counts:?}", timeline.len());
        let latest_page = timeline.iter().rev().take(80).cloned().collect::<Vec<_>>();
        let mut latest_counts = HashMap::new();
        for event in latest_page.iter().rev() {
            *latest_counts
                .entry(event.event_type.clone())
                .or_insert(0usize) += 1;
        }
        eprintln!(
            "live latest_page_count={} counts={latest_counts:?}",
            latest_page.len()
        );
        for event in latest_page.iter().take(15) {
            eprintln!(
                "live latest page event: {} {}",
                event.event_type, event.summary_text
            );
        }
        for event in timeline
            .iter()
            .filter(|event| event.event_type != "agent_message_delta")
            .take(5)
        {
            eprintln!(
                "live non-message event: {} {}",
                event.event_type, event.summary_text
            );
        }
    }

    #[test]
    fn merge_thread_snapshots_supplements_rpc_with_archive_tool_events() {
        let rpc_snapshot = (
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Inspect snapshot merge".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Inspecting".to_string(),
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-user".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:01:00Z".to_string(),
                        summary_text: "Check the timeline".to_string(),
                        data: json!({"type": "userMessage", "content": [{"text": "Check the timeline"}]}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-agent".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:02:00Z".to_string(),
                        summary_text: "Tracing now".to_string(),
                        data: json!({"type": "agentMessage", "text": "Tracing now"}),
                    },
                ],
            )]),
        );
        let archive_snapshot = (
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Inspect snapshot merge".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:07:00Z".to_string(),
                source: "archive".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Edited files".to_string(),
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "archive-user".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:01:00Z".to_string(),
                        summary_text: "Check the timeline".to_string(),
                        data: json!({"type": "userMessage", "content": [{"text": "Check the timeline"}]}),
                    },
                    UpstreamTimelineEvent {
                        id: "archive-file-change".to_string(),
                        event_type: "file_change_delta".to_string(),
                        happened_at: "2026-03-17T10:03:00Z".to_string(),
                        summary_text: "Edited files via apply_patch".to_string(),
                        data: json!({
                            "change": "*** Begin Patch\n*** Update File: /workspace/codex-mobile-companion/lib/main.dart\n*** End Patch",
                            "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart",
                        }),
                    },
                ],
            )]),
        );

        let (_, timeline_by_thread_id) =
            super::merge_thread_snapshots(rpc_snapshot, archive_snapshot);
        let timeline = timeline_by_thread_id
            .get("thread-123")
            .expect("merged timeline should exist");

        assert_eq!(timeline.len(), 3);
        assert_eq!(timeline[0].id, "archive-user");
        assert_eq!(timeline[1].id, "evt-agent");
        assert_eq!(timeline[2].id, "archive-file-change");
        assert_eq!(timeline[2].event_type, "file_change_delta");
        assert_eq!(
            timeline[2].data["resolved_unified_diff"],
            "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart"
        );
    }

    #[test]
    fn sync_thread_from_upstream_refreshes_only_requested_thread() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-target","thread_name":"Fresh target title","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");
        fs::write(
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-target.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-target","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Fresh target body."}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let mut service = ThreadApiService {
            thread_records: vec![
                UpstreamThreadRecord {
                    id: "thread-target".to_string(),
                    headline: "Stale target title".to_string(),
                    lifecycle_state: "done".to_string(),
                    workspace_path: "/workspace/stale-target".to_string(),
                    repository_name: "stale-target".to_string(),
                    branch_name: "main".to_string(),
                    remote_name: "origin".to_string(),
                    git_dirty: false,
                    git_ahead_by: 0,
                    git_behind_by: 0,
                    created_at: "2026-03-17T10:00:00Z".to_string(),
                    updated_at: "2026-03-17T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    approval_mode: "control_with_approvals".to_string(),
                    last_turn_summary: "stale target summary".to_string(),
                },
                UpstreamThreadRecord {
                    id: "thread-other".to_string(),
                    headline: "Unrelated thread".to_string(),
                    lifecycle_state: "done".to_string(),
                    workspace_path: "/workspace/other".to_string(),
                    repository_name: "other".to_string(),
                    branch_name: "main".to_string(),
                    remote_name: "origin".to_string(),
                    git_dirty: false,
                    git_ahead_by: 0,
                    git_behind_by: 0,
                    created_at: "2026-03-17T10:00:00Z".to_string(),
                    updated_at: "2026-03-17T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    approval_mode: "control_with_approvals".to_string(),
                    last_turn_summary: "other summary".to_string(),
                },
            ],
            timeline_by_thread_id: HashMap::from([
                (
                    "thread-target".to_string(),
                    vec![UpstreamTimelineEvent {
                        id: "stale-target-event".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:00:00Z".to_string(),
                        summary_text: "stale target event".to_string(),
                        data: json!({"delta": "stale target event", "role": "assistant"}),
                    }],
                ),
                (
                    "thread-other".to_string(),
                    vec![UpstreamTimelineEvent {
                        id: "other-event".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:00:00Z".to_string(),
                        summary_text: "other event".to_string(),
                        data: json!({"delta": "other event", "role": "assistant"}),
                    }],
                ),
            ]),
            next_event_sequence: 10,
            sync_config: Some(ThreadSyncConfig {
                codex_command: "/definitely/missing/codex".to_string(),
                codex_args: Vec::new(),
                codex_endpoint: None,
                codex_home: codex_home.clone(),
            }),
        };

        service
            .sync_thread_from_upstream("thread-target")
            .expect("thread sync should fall back to archive");

        let refreshed_target = service
            .thread_records
            .iter()
            .find(|thread| thread.id == "thread-target")
            .expect("target thread should remain present");
        assert_eq!(refreshed_target.headline, "Fresh target title");
        assert_eq!(refreshed_target.last_turn_summary, "Fresh target body.");

        let untouched_other = service
            .thread_records
            .iter()
            .find(|thread| thread.id == "thread-other")
            .expect("other thread should remain present");
        assert_eq!(untouched_other.headline, "Unrelated thread");
        assert_eq!(untouched_other.last_turn_summary, "other summary");

        let target_timeline = service
            .timeline_by_thread_id
            .get("thread-target")
            .expect("target timeline should exist");
        assert_eq!(target_timeline.len(), 1);
        assert_eq!(target_timeline[0].summary_text, "Fresh target body.");

        let other_timeline = service
            .timeline_by_thread_id
            .get("thread-other")
            .expect("other timeline should still exist");
        assert_eq!(other_timeline.len(), 1);
        assert_eq!(other_timeline[0].id, "other-event");

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn reconcile_snapshot_publishes_status_and_new_timeline_events() {
        let mut service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Investigate bridge sync".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Running".to_string(),
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-existing".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:05:00Z".to_string(),
                    summary_text: "Existing assistant output".to_string(),
                    data: json!({"delta": "existing"}),
                }],
            )]),
        );

        let events = service.reconcile_snapshot(
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Investigate bridge sync".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:06:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Completed".to_string(),
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-existing".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:05:00Z".to_string(),
                        summary_text: "Existing assistant output".to_string(),
                        data: json!({"delta": "existing"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-new".to_string(),
                        event_type: "command_output_delta".to_string(),
                        happened_at: "2026-03-17T10:06:30Z".to_string(),
                        summary_text: "New command output".to_string(),
                        data: json!({"command": "pwd", "delta": "/workspace"}),
                    },
                ],
            )]),
        );

        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, BridgeEventKind::ThreadStatusChanged);
        assert_eq!(events[0].payload["status"], "completed");
        assert_eq!(events[1].event_id, "evt-new");
        assert_eq!(events[1].kind, BridgeEventKind::CommandDelta);
    }

    #[test]
    fn reconcile_snapshot_preserves_live_only_events_missing_from_snapshot() {
        let thread = UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Inspect reconcile merge".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Inspecting".to_string(),
        };
        let mut service = ThreadApiService::with_seed_data(
            vec![thread.clone()],
            HashMap::from([(
                "thread-123".to_string(),
                vec![
                    UpstreamTimelineEvent {
                        id: "evt-message".to_string(),
                        event_type: "agent_message_delta".to_string(),
                        happened_at: "2026-03-17T10:01:00Z".to_string(),
                        summary_text: "Tracing now".to_string(),
                        data: json!({"type": "agentMessage", "text": "Tracing now"}),
                    },
                    UpstreamTimelineEvent {
                        id: "evt-file-change".to_string(),
                        event_type: "file_change_delta".to_string(),
                        happened_at: "2026-03-17T10:02:00Z".to_string(),
                        summary_text: "Edited lib/main.dart".to_string(),
                        data: json!({
                            "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart",
                        }),
                    },
                ],
            )]),
        );

        let events = service.reconcile_snapshot(
            vec![UpstreamThreadRecord {
                updated_at: "2026-03-17T10:06:00Z".to_string(),
                ..thread
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-message".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Tracing now".to_string(),
                    data: json!({"type": "agentMessage", "text": "Tracing now"}),
                }],
            )]),
        );

        assert!(events.is_empty());

        let timeline = service
            .timeline_page_response("thread-123", None, 50)
            .expect("timeline response should exist");
        assert_eq!(timeline.entries.len(), 2);
        assert_eq!(timeline.entries[1].kind, BridgeEventKind::FileChange);
        assert_eq!(
            timeline.entries[1].payload["resolved_unified_diff"],
            "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart"
        );
    }

    #[test]
    fn reconcile_snapshot_does_not_republish_existing_events() {
        let thread = UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Running".to_string(),
        };
        let timeline = HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-existing".to_string(),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-17T10:05:00Z".to_string(),
                summary_text: "Existing assistant output".to_string(),
                data: json!({"delta": "existing"}),
            }],
        )]);
        let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], timeline.clone());

        let events = service.reconcile_snapshot(vec![thread], timeline);

        assert!(events.is_empty());
    }

    #[test]
    fn reconcile_snapshot_republishes_changed_events_with_stable_upstream_ids() {
        let thread = UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Streaming".to_string(),
        };
        let mut service = ThreadApiService::with_seed_data(
            vec![thread.clone()],
            HashMap::from([(
                "thread-123".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-streaming-message".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:05:00Z".to_string(),
                    summary_text: "Hel".to_string(),
                    data: json!({
                        "type": "agentMessage",
                        "text": "Hel",
                    }),
                }],
            )]),
        );

        let events = service.reconcile_snapshot(
            vec![UpstreamThreadRecord {
                updated_at: "2026-03-17T10:05:02Z".to_string(),
                ..thread
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-streaming-message".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:05:02Z".to_string(),
                    summary_text: "Hello from the streamed update".to_string(),
                    data: json!({
                        "type": "agentMessage",
                        "text": "Hello from the streamed update",
                    }),
                }],
            )]),
        );

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_id, "evt-streaming-message");
        assert_eq!(events[0].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[0].payload["text"], "Hello from the streamed update");
    }

    #[test]
    fn codex_notification_normalizer_accumulates_agent_message_deltas() {
        let mut normalizer = CodexNotificationNormalizer::default();

        assert!(
            normalizer
                .normalize(
                    "turn/started",
                    &json!({
                        "threadId": "thread-123",
                        "turn": {
                            "id": "turn-123",
                            "status": "inProgress",
                            "items": [],
                        }
                    }),
                )
                .is_none()
        );
        assert!(
            normalizer
                .normalize(
                    "thread/realtime/itemAdded",
                    &json!({
                        "threadId": "thread-123",
                        "item": {
                            "id": "msg-1",
                            "type": "agentMessage",
                            "text": "",
                        }
                    }),
                )
                .is_none()
        );

        let first = normalizer
            .normalize(
                "item/agentMessage/delta",
                &json!({
                    "delta": "Hel",
                    "itemId": "msg-1",
                    "threadId": "thread-123",
                    "turnId": "turn-123",
                }),
            )
            .expect("first delta should produce an event");
        assert_eq!(first.event_id, "turn-123-msg-1");
        assert_eq!(first.payload["text"], "Hel");

        let second = normalizer
            .normalize(
                "item/agentMessage/delta",
                &json!({
                    "delta": "lo",
                    "itemId": "msg-1",
                    "threadId": "thread-123",
                    "turnId": "turn-123",
                }),
            )
            .expect("second delta should produce an event");
        assert_eq!(second.event_id, "turn-123-msg-1");
        assert_eq!(second.payload["text"], "Hello");
    }

    #[test]
    fn codex_notification_normalizer_maps_custom_tool_item_added_to_file_change() {
        let mut normalizer = CodexNotificationNormalizer::default();

        let event = normalizer
            .normalize(
                "thread/realtime/itemAdded",
                &json!({
                    "threadId": "thread-123",
                    "item": {
                        "id": "tool-1",
                        "type": "customToolCall",
                        "name": "apply_patch",
                        "input": "*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n",
                    }
                }),
            )
            .expect("custom tool call should produce a file change event");

        assert_eq!(event.kind, BridgeEventKind::FileChange);
        assert_eq!(event.payload["command"], "apply_patch");
        assert!(
            event.payload["change"]
                .as_str()
                .unwrap_or_default()
                .contains("*** Update File: lib/main.dart")
        );
    }

    #[test]
    fn codex_notification_normalizer_adds_exploration_annotations_for_tool_invocations() {
        let mut normalizer = CodexNotificationNormalizer::default();

        assert!(
            normalizer
                .normalize(
                    "turn/started",
                    &json!({
                        "threadId": "thread-123",
                        "turn": {
                            "id": "turn-123",
                            "status": "inProgress",
                            "items": [],
                        }
                    }),
                )
                .is_none()
        );

        let event = normalizer
            .normalize(
                "thread/realtime/itemAdded",
                &json!({
                    "threadId": "thread-123",
                    "item": {
                        "id": "tool-1",
                        "type": "functionCall",
                        "name": "exec_command",
                        "arguments": "{\"cmd\":\"rg -n websocket crates/bridge-core/src/thread_api.rs\"}"
                    }
                }),
            )
            .expect("tool invocation should produce a command event");

        let annotations = event
            .annotations
            .as_ref()
            .expect("live command event should include annotations");
        assert_eq!(
            annotations.group_kind,
            Some(ThreadTimelineGroupKind::Exploration)
        );
        assert_eq!(
            annotations.group_id.as_deref(),
            Some("exploration:turn-123")
        );
        assert_eq!(
            annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Search)
        );
        assert_eq!(annotations.entry_label.as_deref(), Some("Search"));
        assert!(event.payload.get("presentation").is_none());
    }

    #[test]
    fn codex_notification_normalizer_maps_custom_tool_output_deltas() {
        let mut normalizer = CodexNotificationNormalizer::default();

        let event = normalizer
            .normalize(
                "item/customToolCallOutput/outputDelta",
                &json!({
                    "delta": "Success. Updated the following files:\nM lib/main.dart\n",
                    "itemId": "tool-2",
                    "threadId": "thread-123",
                    "turnId": "turn-123",
                }),
            )
            .expect("custom tool output delta should produce an event");

        assert_eq!(event.kind, BridgeEventKind::FileChange);
        assert_eq!(
            event.payload["output"],
            "Success. Updated the following files:\nM lib/main.dart\n"
        );
    }

    #[test]
    fn timeline_page_response_adds_exploration_annotations_for_background_commands() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Investigate bridge sync".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Reading files".to_string(),
            }],
            HashMap::from([(
                "thread-123".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-read".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Background terminal finished".to_string(),
                    data: json!({
                        "output": "Command: sed -n '1,120p' apps/mobile/lib/features/threads/domain/parsed_command_output.dart\nOutput:\nBackground terminal finished with sed -n '1,120p' apps/mobile/lib/features/threads/domain/parsed_command_output.dart",
                    }),
                }],
            )]),
        );

        let page = service
            .timeline_page_response("thread-123", None, 50)
            .expect("timeline page should exist");

        let annotations = page.entries[0]
            .annotations
            .as_ref()
            .expect("background command should include annotations");
        assert_eq!(
            annotations.group_kind,
            Some(ThreadTimelineGroupKind::Exploration)
        );
        assert_eq!(
            annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Read)
        );
        assert_eq!(
            annotations.entry_label.as_deref(),
            Some("Read parsed_command_output.dart")
        );
        assert!(page.entries[0].payload.get("presentation").is_none());
    }

    #[test]
    fn codex_notification_normalizer_keeps_exploration_annotations_on_command_output_deltas() {
        let mut normalizer = CodexNotificationNormalizer::default();

        assert!(
            normalizer
                .normalize(
                    "turn/started",
                    &json!({
                        "threadId": "thread-123",
                        "turn": {
                            "id": "turn-123",
                            "status": "inProgress",
                            "items": [],
                        }
                    }),
                )
                .is_none()
        );
        let _ = normalizer.normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "cmd-1",
                    "type": "commandExecution",
                    "command": "rg -n \"thread-detail\" apps/mobile/lib/features/threads",
                    "aggregatedOutput": "",
                    "output": "",
                }
            }),
        );

        let event = normalizer
            .normalize(
                "item/commandExecution/outputDelta",
                &json!({
                    "delta": "apps/mobile/lib/features/threads/presentation/thread_detail_page.dart:143: _maybeAutoLoadEarlierHistory()",
                    "itemId": "cmd-1",
                    "threadId": "thread-123",
                    "turnId": "turn-123",
                }),
            )
            .expect("command output delta should produce an event");

        let annotations = event
            .annotations
            .as_ref()
            .expect("command output delta should keep annotations");
        assert_eq!(event.kind, BridgeEventKind::CommandDelta);
        assert_eq!(
            annotations.group_kind,
            Some(ThreadTimelineGroupKind::Exploration)
        );
        assert_eq!(
            annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Search)
        );
        assert!(event.payload.get("presentation").is_none());
    }

    #[test]
    fn apply_live_event_replaces_existing_timeline_entry_with_same_event_id() {
        let mut service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Investigate bridge sync".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Streaming".to_string(),
            }],
            HashMap::new(),
        );

        service.apply_live_event(BridgeEventEnvelope::new(
            "turn-123-msg-1",
            "thread-123",
            BridgeEventKind::MessageDelta,
            "101",
            json!({
                "id": "msg-1",
                "type": "agentMessage",
                "text": "Hel",
            }),
        ));
        service.apply_live_event(BridgeEventEnvelope::new(
            "turn-123-msg-1",
            "thread-123",
            BridgeEventKind::MessageDelta,
            "102",
            json!({
                "id": "msg-1",
                "type": "agentMessage",
                "text": "Hello",
            }),
        ));

        let timeline = service
            .timeline_page_response("thread-123", None, 50)
            .expect("timeline response should exist");
        assert_eq!(timeline.entries.len(), 1);
        assert_eq!(timeline.entries[0].event_id, "turn-123-msg-1");
        assert_eq!(timeline.entries[0].payload["text"], "Hello");

        let detail = service
            .detail_response("thread-123")
            .expect("detail response should exist");
        assert_eq!(detail.thread.updated_at, "102");
        assert_eq!(detail.thread.last_turn_summary, "Hello");
    }

    #[test]
    fn archived_sessions_preserve_user_message_images() {
        let codex_home = unique_test_codex_home();
        let sessions_directory = codex_home.join("sessions/2026/03/19");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            codex_home.join("session_index.jsonl"),
            r#"{"id":"thread-archive-images","thread_name":"Archive message images","updated_at":"2026-03-19T10:00:00Z"}"#,
        )
        .expect("session index should be writable");
        fs::write(
            sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-images.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-images","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-19T09:56:00Z","type":"event_msg","payload":{"type":"user_message","message":"Here is the screenshot.\n","images":["data:image/png;base64,AAA"]}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
            .expect("archive fallback should load");

        let thread_timeline = timeline
            .get("thread-archive-images")
            .expect("timeline should exist for archived thread");

        assert_eq!(thread_timeline.len(), 1);
        assert_eq!(thread_timeline[0].data["type"], "userMessage");
        assert_eq!(
            thread_timeline[0].data["content"][0]["text"],
            "Here is the screenshot."
        );
        assert_eq!(
            thread_timeline[0].data["content"][1]["image_url"],
            "data:image/png;base64,AAA"
        );

        let _ = fs::remove_dir_all(codex_home);
    }

    #[test]
    fn codex_rpc_timeline_skips_unknown_internal_items() {
        let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
            id: "thread-123".to_string(),
            name: Some("Inspect RPC timeline".to_string()),
            preview: Some("Preview".to_string()),
            status: CodexThreadStatus {
                kind: "active".to_string(),
            },
            cwd: "/Users/test/workspace".to_string(),
            git_info: None,
            created_at: 1,
            updated_at: 2,
            source: json!("cli"),
            turns: vec![CodexTurn {
                id: "turn-123".to_string(),
                items: vec![
                    json!({"id":"sys-1","type":"systemMessage","text":"<collaboration_mode>Default</collaboration_mode>"}),
                    json!({"id":"user-1","type":"userMessage","content":[{"text":"Ship the fix"}]}),
                    json!({"id":"assistant-1","type":"agentMessage","text":"Inspecting the issue."}),
                ],
            }],
        });

        assert_eq!(timeline.len(), 2);
        assert_eq!(timeline[0].data["type"], "userMessage");
        assert_eq!(timeline[1].data["type"], "agentMessage");
    }

    #[test]
    fn codex_rpc_timeline_maps_tool_calls_to_command_and_file_change_events() {
        let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
            id: "thread-123".to_string(),
            name: Some("Inspect RPC timeline".to_string()),
            preview: Some("Preview".to_string()),
            status: CodexThreadStatus {
                kind: "active".to_string(),
            },
            cwd: "/Users/test/workspace".to_string(),
            git_info: None,
            created_at: 1,
            updated_at: 2,
            source: json!("cli"),
            turns: vec![CodexTurn {
                id: "turn-123".to_string(),
                items: vec![
                    json!({
                        "id":"tool-1",
                        "type":"functionCall",
                        "name":"exec_command",
                        "arguments":"{\"cmd\":\"pwd\"}"
                    }),
                    json!({
                        "id":"tool-2",
                        "type":"customToolCall",
                        "name":"apply_patch",
                        "input":"*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n"
                    }),
                    json!({
                        "id":"tool-3",
                        "type":"customToolCallOutput",
                        "output":"Success. Updated the following files:\nM lib/main.dart\n"
                    }),
                ],
            }],
        });

        assert_eq!(timeline.len(), 3);
        assert_eq!(timeline[0].event_type, "command_output_delta");
        assert_eq!(timeline[0].data["command"], "exec_command");
        assert_eq!(timeline[1].event_type, "file_change_delta");
        assert_eq!(timeline[1].data["command"], "apply_patch");
        assert_eq!(timeline[2].event_type, "file_change_delta");
        assert_eq!(
            timeline[2].data["output"],
            "Success. Updated the following files:\nM lib/main.dart\n"
        );
    }

    fn unique_test_codex_home() -> PathBuf {
        let unique = format!(
            "bridge-core-codex-home-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time before unix epoch")
                .as_nanos()
        );

        std::env::temp_dir().join(unique)
    }
}
