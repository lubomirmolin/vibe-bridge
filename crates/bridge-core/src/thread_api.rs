use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadApiService {
    thread_records: Vec<UpstreamThreadRecord>,
    timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    next_event_sequence: u64,
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
        }
    }

    pub fn from_codex_app_server(command: &str, args: &[String]) -> Result<Self, String> {
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

        Ok(Self::with_seed_data(thread_records, timeline_by_thread_id))
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
        let event_id = format!("evt-live-{}", self.next_event_sequence);
        let occurred_at = self.next_timestamp();

        BridgeEventEnvelope::new(event_id, thread_id.to_string(), kind, occurred_at, payload)
    }

    fn next_timestamp(&mut self) -> String {
        let sequence = self.next_event_sequence;
        self.next_event_sequence += 1;

        let minute = (sequence / 60) % 60;
        let second = sequence % 60;
        format!("2026-03-17T22:{minute:02}:{second:02}Z")
    }
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
            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));

            events.push(UpstreamTimelineEvent {
                id: format!("{}-{item_id}", turn.id),
                event_type: map_codex_item_type_to_event_type(item_type).to_string(),
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

fn map_codex_item_type_to_event_type(item_type: &str) -> &'static str {
    match item_type {
        "plan" => "plan_delta",
        "commandExecution" => "command_output_delta",
        "fileChange" => "file_change_delta",
        _ => "agent_message_delta",
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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{ThreadApiService, UpstreamThreadRecord, UpstreamTimelineEvent};
    use shared_contracts::{AccessMode, BridgeEventKind, CONTRACT_VERSION, ThreadStatus};

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
}
