use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto,
    ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
};

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
pub struct ThreadTimelineResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub events: Vec<ThreadTimelineEntryDto>,
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

    pub fn from_codex_app_server(command: &str, args: &[String]) -> Result<Self, String> {
        let codex_home = resolve_codex_home_dir()?;
        let (thread_records, timeline_by_thread_id) =
            load_thread_snapshot(command, args, &codex_home)?;

        Ok(Self {
            thread_records,
            timeline_by_thread_id,
            next_event_sequence: 10,
            sync_config: Some(ThreadSyncConfig {
                codex_command: command.to_string(),
                codex_args: args.to_vec(),
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
            &sync_config.codex_home,
        )?;
        self.thread_records = thread_records;
        self.timeline_by_thread_id = timeline_by_thread_id;
        Ok(())
    }

    pub fn reconcile_from_upstream(&mut self) -> Result<Vec<BridgeEventEnvelope<Value>>, String> {
        let Some(sync_config) = &self.sync_config else {
            return Ok(Vec::new());
        };

        let (thread_records, timeline_by_thread_id) = load_thread_snapshot(
            &sync_config.codex_command,
            &sync_config.codex_args,
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

        for thread in &thread_records {
            if let Some(previous_thread) = previous_threads.get(&thread.id) {
                if previous_thread.lifecycle_state != thread.lifecycle_state {
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
            }

            let previous_event_ids = previous_timeline
                .get(&thread.id)
                .map(|events| {
                    events
                        .iter()
                        .map(|event| (event.id.as_str(), event))
                        .collect::<HashMap<_, _>>()
                })
                .unwrap_or_default();

            if let Some(next_events) = timeline_by_thread_id.get(&thread.id) {
                for event in next_events {
                    if let Some(previous_event) = previous_event_ids.get(event.id.as_str())
                        && *previous_event == event
                    {
                        continue;
                    }

                    events.push(BridgeEventEnvelope::new(
                        event.id.clone(),
                        thread.id.clone(),
                        map_event_kind(&event.event_type),
                        event.happened_at.clone(),
                        event.data.clone(),
                    ));
                }
            }
        }

        self.thread_records = thread_records;
        self.timeline_by_thread_id = timeline_by_thread_id;
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

    pub fn timeline_response(&self, thread_id: &str) -> Option<ThreadTimelineResponse> {
        if !self
            .thread_records
            .iter()
            .any(|thread| thread.id == thread_id)
        {
            return None;
        }

        let events = self
            .timeline_by_thread_id
            .get(thread_id)
            .cloned()
            .unwrap_or_default();
        Some(ThreadTimelineResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            events: events.iter().map(map_timeline_entry).collect::<Vec<_>>(),
        })
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

    pub fn steer_turn(
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

    pub fn interrupt_turn(&mut self, thread_id: &str) -> Option<MutationDispatch> {
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

        BridgeEventEnvelope::new(
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
    codex_home: &Path,
) -> Result<ThreadSnapshot, String> {
    let rpc_result = load_thread_snapshot_from_codex_rpc(command, args);
    if let Ok((thread_records, timeline_by_thread_id)) = &rpc_result
        && !thread_records.is_empty()
    {
        return Ok((thread_records.clone(), timeline_by_thread_id.clone()));
    }

    let archive_result = load_thread_snapshot_from_codex_archive(codex_home);
    match (rpc_result, archive_result) {
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

fn load_thread_snapshot_from_codex_rpc(
    command: &str,
    args: &[String],
) -> Result<ThreadSnapshot, String> {
    let mut client = CodexRpcClient::start(command, args)?;
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

fn load_thread_snapshot_from_codex_archive(codex_home: &Path) -> Result<ThreadSnapshot, String> {
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
    entries.truncate(CodexRpcClient::MAX_THREADS_TO_FETCH);

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
                if let Some(text) = item.get("text").and_then(Value::as_str) {
                    if !text.trim().is_empty() {
                        content.push(json!({
                            "type": "text",
                            "text_type": item_type,
                            "text": text,
                        }));
                    }
                }
            }
            "input_image" | "image" => {
                if let Some(image_url) = item.get("image_url").and_then(Value::as_str) {
                    if !image_url.trim().is_empty() {
                        content.push(json!({
                            "type": "image",
                            "image_url": image_url,
                        }));
                    }
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
    next_id: i64,
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl CodexRpcClient {
    const MAX_THREADS_TO_FETCH: usize = 50;

    fn start(command: &str, args: &[String]) -> Result<Self, String> {
        let mut command_args = if args.is_empty() {
            vec!["app-server".to_string()]
        } else {
            args.to_vec()
        };

        if !command_args.iter().any(|arg| arg == "--listen") {
            command_args.push("--listen".to_string());
            command_args.push("stdio://".to_string());
        }

        let mut child = Command::new(command)
            .args(command_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                format!("failed to spawn codex app-server via '{command}': {error}")
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdout".to_string())?;

        let mut client = Self {
            next_id: 1,
            child,
            stdin,
            stdout: BufReader::new(stdout),
        };

        client.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "bridge-core",
                    "version": CONTRACT_VERSION,
                }
            }),
        )?;

        Ok(client)
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

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;

        let payload = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        let line = serde_json::to_string(&payload).map_err(|error| {
            format!("failed to serialize codex rpc request '{method}': {error}")
        })?;

        writeln!(self.stdin, "{line}")
            .map_err(|error| format!("failed to write codex rpc request '{method}': {error}"))?;
        self.stdin
            .flush()
            .map_err(|error| format!("failed to flush codex rpc request '{method}': {error}"))?;

        let mut response_line = String::new();
        loop {
            response_line.clear();
            let bytes_read = self.stdout.read_line(&mut response_line).map_err(|error| {
                format!("failed to read codex rpc response for '{method}': {error}")
            })?;

            if bytes_read == 0 {
                return Err(format!(
                    "codex app-server closed stdout while waiting for '{method}'"
                ));
            }

            let response: Value = serde_json::from_str(response_line.trim()).map_err(|error| {
                format!("failed to parse codex rpc response for '{method}' as JSON: {error}")
            })?;

            if response.get("id").and_then(Value::as_i64) != Some(id) {
                continue;
            }

            if let Some(error) = response.get("error") {
                return Err(format!(
                    "codex rpc request '{method}' failed: {}",
                    error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown error")
                ));
            }

            return response.get("result").cloned().ok_or_else(|| {
                format!("codex rpc response for '{method}' did not include result")
            });
        }
    }
}

impl Drop for CodexRpcClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug)]
pub struct CodexNotificationStream {
    child: Child,
    _stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
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
    pub fn start(command: &str, args: &[String]) -> Result<Self, String> {
        let mut command_args = if args.is_empty() {
            vec!["app-server".to_string()]
        } else {
            args.to_vec()
        };

        if !command_args.iter().any(|arg| arg == "--listen") {
            command_args.push("--listen".to_string());
            command_args.push("stdio://".to_string());
        }

        let mut child = Command::new(command)
            .args(command_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                format!("failed to spawn codex app-server via '{command}': {error}")
            })?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdout".to_string())?;
        let mut stdout = BufReader::new(stdout);

        let initialize_payload = json!({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "bridge-core",
                    "version": CONTRACT_VERSION,
                }
            },
        });
        let line = serde_json::to_string(&initialize_payload)
            .map_err(|error| format!("failed to serialize initialize request: {error}"))?;
        writeln!(stdin, "{line}")
            .map_err(|error| format!("failed to write initialize request: {error}"))?;
        stdin
            .flush()
            .map_err(|error| format!("failed to flush initialize request: {error}"))?;

        let mut response_line = String::new();
        loop {
            response_line.clear();
            let bytes_read = stdout
                .read_line(&mut response_line)
                .map_err(|error| format!("failed to read initialize response: {error}"))?;
            if bytes_read == 0 {
                return Err("codex app-server closed stdout during initialize".to_string());
            }

            let response: Value = serde_json::from_str(response_line.trim())
                .map_err(|error| format!("failed to parse initialize response as JSON: {error}"))?;

            if response.get("id").and_then(Value::as_i64) != Some(1) {
                continue;
            }

            if let Some(error) = response.get("error") {
                return Err(format!(
                    "codex rpc initialize failed: {}",
                    error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown error")
                ));
            }

            break;
        }

        Ok(Self {
            child,
            _stdin: stdin,
            stdout,
            normalizer: CodexNotificationNormalizer::default(),
        })
    }

    pub fn next_event(&mut self) -> Result<Option<BridgeEventEnvelope<Value>>, String> {
        let mut line = String::new();
        loop {
            line.clear();
            let bytes_read = self
                .stdout
                .read_line(&mut line)
                .map_err(|error| format!("failed to read codex notification: {error}"))?;
            if bytes_read == 0 {
                return Ok(None);
            }

            let message: Value = match serde_json::from_str(line.trim()) {
                Ok(message) => message,
                Err(_) => continue,
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

impl Drop for CodexNotificationStream {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
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
                let occurred_at = current_epoch_millis_string();
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
            "item/agentMessage/delta" => self.normalize_delta(
                params,
                BridgeEventKind::MessageDelta,
                "agentMessage",
                DeltaTarget::Text,
            ),
            "item/plan/delta" => self.normalize_delta(
                params,
                BridgeEventKind::PlanDelta,
                "plan",
                DeltaTarget::Text,
            ),
            "item/commandExecution/outputDelta" => self.normalize_delta(
                params,
                BridgeEventKind::CommandDelta,
                "commandExecution",
                DeltaTarget::CommandOutput,
            ),
            "item/fileChange/outputDelta" => self.normalize_delta(
                params,
                BridgeEventKind::FileChange,
                "fileChange",
                DeltaTarget::FileDiff,
            ),
            _ => None,
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

        Some(BridgeEventEnvelope::new(
            event_id,
            notification.thread_id,
            kind,
            current_epoch_millis_string(),
            payload,
        ))
    }

    fn normalize_delta(
        &mut self,
        params: &Value,
        kind: BridgeEventKind,
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

        Some(BridgeEventEnvelope::new(
            event_id,
            notification.thread_id,
            kind,
            current_epoch_millis_string(),
            payload.clone(),
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
        created_at: thread.created_at.to_string(),
        updated_at: thread.updated_at.to_string(),
        source,
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: thread.preview.clone().unwrap_or_default(),
    }
}

fn map_codex_thread_to_timeline_events(thread: &CodexThread) -> Vec<UpstreamTimelineEvent> {
    let mut events = Vec::new();
    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let item_type = item
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let Some(event_type) = map_codex_item_type_to_event_type(item_type) else {
                continue;
            };
            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));

            events.push(UpstreamTimelineEvent {
                id: format!("{}-{item_id}", turn.id),
                event_type: event_type.to_string(),
                happened_at: thread.updated_at.to_string(),
                summary_text: summarize_codex_item(item_type, item),
                data: item.clone(),
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

fn map_codex_item_type_to_event_type(item_type: &str) -> Option<&'static str> {
    match item_type {
        "agentMessage" | "userMessage" => Some("agent_message_delta"),
        "plan" => Some("plan_delta"),
        "commandExecution" => Some("command_output_delta"),
        "fileChange" => Some("file_change_delta"),
        _ => None,
    }
}

fn summarize_codex_item(item_type: &str, item: &Value) -> String {
    match item_type {
        "agentMessage" => item
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("Agent message")
            .to_string(),
        "userMessage" => item
            .get("content")
            .and_then(Value::as_array)
            .and_then(|content| content.first())
            .and_then(|first| first.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("User message")
            .to_string(),
        "plan" => item
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or("Plan update")
            .to_string(),
        "commandExecution" => "Command output update".to_string(),
        "fileChange" => "File change update".to_string(),
        _ => format!("{item_type} event"),
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
    ThreadTimelineEntryDto {
        event_id: upstream.id.clone(),
        kind: map_event_kind(&upstream.event_type),
        occurred_at: upstream.happened_at.clone(),
        summary: upstream.summary_text.clone(),
        payload: upstream.data.clone(),
    }
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

fn current_epoch_millis_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}

fn normalize_realtime_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let item_type = item.get("type").and_then(Value::as_str)?;
    match item_type {
        "userMessage" | "agentMessage" => Some((BridgeEventKind::MessageDelta, item.clone())),
        "plan" => Some((BridgeEventKind::PlanDelta, item.clone())),
        "commandExecution" => {
            let mut payload = item.clone();
            if let Some(output) = item.get("aggregatedOutput").and_then(Value::as_str) {
                if let Some(object) = payload.as_object_mut() {
                    object.insert("output".to_string(), Value::String(output.to_string()));
                }
            }
            Some((BridgeEventKind::CommandDelta, payload))
        }
        "fileChange" => Some((BridgeEventKind::FileChange, item.clone())),
        _ => None,
    }
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
        BridgeEventKind::CommandDelta => payload
            .get("output")
            .or_else(|| payload.get("aggregatedOutput"))
            .and_then(Value::as_str)
            .is_some_and(|text| !text.trim().is_empty()),
        BridgeEventKind::FileChange => {
            payload
                .get("resolved_unified_diff")
                .or_else(|| payload.get("output"))
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
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;

    use super::{
        CodexNotificationNormalizer, CodexThread, CodexThreadStatus, CodexTurn, ThreadApiService,
        UpstreamThreadRecord, UpstreamTimelineEvent,
    };
    use serde_json::{Value, json};
    use shared_contracts::{
        AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadStatus,
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
    fn timeline_response_normalizes_event_kinds() {
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
            .timeline_response("thread-abc")
            .expect("timeline response should exist");

        assert_eq!(timeline.contract_version, CONTRACT_VERSION);
        assert_eq!(timeline.events.len(), 1);
        assert_eq!(timeline.events[0].kind, BridgeEventKind::CommandDelta);
    }

    #[test]
    fn timeline_response_for_existing_thread_without_events_returns_empty_payload() {
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
            .timeline_response("thread-empty")
            .expect("existing thread should return timeline payload");

        assert_eq!(timeline.thread_id, "thread-empty");
        assert!(timeline.events.is_empty());
    }

    #[test]
    fn turn_mutations_produce_normalized_result_and_events() {
        let mut service = ThreadApiService::sample();

        let dispatch = service
            .start_turn("thread-123", Some("Investigate websocket routing"))
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
            .timeline_response("thread-123")
            .expect("timeline response should exist");
        assert_eq!(timeline.events.len(), 1);
        assert_eq!(timeline.events[0].event_id, "turn-123-msg-1");
        assert_eq!(timeline.events[0].payload["text"], "Hello");

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
