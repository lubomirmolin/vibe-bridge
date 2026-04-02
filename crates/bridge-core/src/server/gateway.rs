use base64::Engine;
use chrono::{SecondsFormat, TimeZone, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
    GitStatusDto, ModelOptionDto, PendingUserInputDto, ProviderKind, ReasoningEffortOptionDto,
    ThreadDetailDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto, ThreadTimelineExplorationKind,
    ThreadTimelineGroupKind, TurnMutationAcceptedDto,
};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};
use tungstenite::{Message, WebSocket, accept};
use uuid::Uuid;

use crate::codex_runtime::CodexRuntimeMode;
use crate::codex_transport::CodexJsonTransport;
use crate::server::config::BridgeCodexConfig;
use crate::server::state::parse_pending_user_input_payload;
use crate::thread_api::{
    CodexNotificationNormalizer, CodexNotificationStream, ThreadApiService, is_provider_thread_id,
    load_archive_timeline_entries_for_session_path, load_archive_timeline_entries_for_thread,
    map_thread_client_kind_from_source, native_thread_id_for_provider, provider_thread_id,
};

#[derive(Debug, Clone)]
pub struct CodexGateway {
    config: BridgeCodexConfig,
    reserved_transports: Arc<Mutex<HashMap<String, ReservedTransport>>>,
    claude_thread_workspaces: Arc<Mutex<HashMap<String, String>>>,
    active_claude_processes: Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    interrupted_claude_threads: Arc<Mutex<HashSet<String>>>,
}

#[derive(Debug)]
struct ReservedTransport {
    reserved_at: Instant,
    transport: CodexJsonTransport,
}

#[derive(Debug, Clone)]
pub struct GatewayBootstrap {
    pub summaries: Vec<ThreadSummaryDto>,
    pub models: Vec<ModelOptionDto>,
    pub message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct GatewayTurnMutation {
    pub response: TurnMutationAcceptedDto,
    pub turn_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TurnStartRequest {
    pub prompt: String,
    pub images: Vec<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub permission_mode: Option<String>,
}

#[derive(Debug, Clone)]
pub enum GatewayTurnControlRequest {
    CodexApproval {
        request_id: Value,
        method: String,
        params: Value,
    },
    ClaudeCanUseTool {
        request_id: String,
        request: Value,
    },
    ClaudeControlCancel {
        request_id: String,
    },
}

#[derive(Debug, Deserialize)]
struct CodexThreadListResult {
    data: Vec<CodexThread>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadReadResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexThreadResumeResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexThreadStartResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexTurnStartResult {
    turn: CodexTurnHandle,
}

#[derive(Debug, Deserialize)]
struct CodexTurnHandle {
    id: String,
}

#[derive(Debug, Deserialize)]
struct CodexThread {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    preview: Option<String>,
    status: CodexThreadStatus,
    cwd: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(rename = "gitInfo")]
    git_info: Option<CodexGitInfo>,
    #[serde(rename = "createdAt", default)]
    created_at: i64,
    #[serde(rename = "updatedAt")]
    updated_at: i64,
    #[serde(default)]
    source: Value,
    #[serde(default)]
    turns: Vec<CodexTurn>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadStatus {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Deserialize)]
struct CodexGitInfo {
    branch: Option<String>,
    #[serde(rename = "originUrl")]
    origin_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexTurn {
    id: String,
    #[serde(default)]
    items: Vec<Value>,
}

impl CodexGateway {
    const MAX_THREADS_TO_FETCH: usize = 100;
    const RESERVED_TRANSPORT_TTL: Duration = Duration::from_secs(120);
    const THREAD_TITLE_MAX_CHARS: usize = 80;

    pub fn new(config: BridgeCodexConfig) -> Self {
        Self {
            config,
            reserved_transports: Arc::new(Mutex::new(HashMap::new())),
            claude_thread_workspaces: Arc::new(Mutex::new(HashMap::new())),
            active_claude_processes: Arc::new(Mutex::new(HashMap::new())),
            interrupted_claude_threads: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub async fn bootstrap(&self) -> Result<GatewayBootstrap, String> {
        let config = self.config.clone();
        tokio::task::spawn_blocking(move || {
            let mut transport = connect_read_transport(&config)?;
            let summaries = fetch_thread_summaries(&mut transport, &config)?;
            let models = fetch_model_catalog(&mut transport);
            Ok(GatewayBootstrap {
                summaries,
                models,
                message: None,
            })
        })
        .await
        .map_err(|error| format!("codex bootstrap task failed: {error}"))?
    }

    pub async fn fetch_thread_snapshot(
        &self,
        thread_id: &str,
    ) -> Result<ThreadSnapshotDto, String> {
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || {
            if !is_provider_thread_id(&thread_id, ProviderKind::Codex) {
                return fetch_thread_snapshot_from_archive(&config, &thread_id);
            }
            let mut transport = take_reserved_transport(&reserved_transports, &thread_id)
                .unwrap_or(connect_read_transport(&config)?);
            let snapshot = match read_thread_with_resume(&mut transport, &thread_id, true) {
                Ok(payload) => map_thread_snapshot(payload.thread),
                Err(error) if error.contains("not found") => {
                    return fetch_thread_snapshot_from_archive(&config, &thread_id);
                }
                Err(error) => return Err(error),
            };
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex thread snapshot task failed: {error}"))?
    }

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        if provider == ProviderKind::ClaudeCode {
            return self.create_claude_thread(workspace).await;
        }
        let config = self.config.clone();
        let workspace = workspace.to_string();
        let model = model.map(str::to_string);
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || -> Result<ThreadSnapshotDto, String> {
            let mut transport = connect_transport(&config)?;
            let mut params = serde_json::Map::new();
            params.insert("cwd".to_string(), Value::String(workspace));
            if let Some(model) = model {
                params.insert("model".to_string(), Value::String(model));
            }

            let response = transport.request("thread/start", Value::Object(params))?;
            let payload: CodexThreadStartResult = serde_json::from_value(response)
                .map_err(|error| format!("invalid thread/start response from codex: {error}"))?;
            let reserved_thread_id = provider_thread_id(ProviderKind::Codex, &payload.thread.id);
            let thread = match read_thread_with_resume(&mut transport, &payload.thread.id, true) {
                Ok(thread) => thread,
                Err(error) if should_read_without_turns(&error) => {
                    read_thread_with_resume(&mut transport, &payload.thread.id, false)?
                }
                Err(error) if should_resume_thread(&error) => {
                    let snapshot = map_thread_snapshot(payload.thread);
                    reserve_transport(&reserved_transports, reserved_thread_id, transport);
                    return Ok(snapshot);
                }
                Err(error) => return Err(error),
            };
            let snapshot = map_thread_snapshot(thread.thread);
            reserve_transport(&reserved_transports, reserved_thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex create_thread task failed: {error}"))?
    }

    async fn create_claude_thread(&self, workspace: &str) -> Result<ThreadSnapshotDto, String> {
        let normalized_workspace = workspace.trim();
        if normalized_workspace.is_empty() {
            return Err("workspace path cannot be empty".to_string());
        }

        let thread_id = provider_thread_id(ProviderKind::ClaudeCode, &Uuid::new_v4().to_string());
        let snapshot = build_claude_placeholder_snapshot(&thread_id, normalized_workspace);
        self.claude_thread_workspaces
            .lock()
            .expect("claude thread workspace lock should not be poisoned")
            .insert(thread_id, normalized_workspace.to_string());
        Ok(snapshot)
    }

    pub fn model_catalog(&self, provider: ProviderKind) -> Vec<ModelOptionDto> {
        match provider {
            ProviderKind::Codex => fallback_model_options(),
            ProviderKind::ClaudeCode => fallback_claude_model_options(),
        }
    }

    pub fn notification_stream(&self) -> Result<CodexNotificationStream, String> {
        let endpoint = match self.config.mode {
            CodexRuntimeMode::Spawn => None,
            _ => self.config.endpoint.as_deref(),
        };
        CodexNotificationStream::start(&self.config.command, &self.config.args, endpoint)
    }

    pub fn desktop_ipc_socket_path(&self) -> Option<PathBuf> {
        self.config.desktop_ipc_socket_path.clone()
    }

    pub fn start_turn_streaming<F, G, H, I>(
        &self,
        thread_id: &str,
        request: TurnStartRequest,
        on_event: F,
        on_control_request: H,
        on_turn_completed: G,
        on_stream_finished: I,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
        H: Fn(GatewayTurnControlRequest) -> Result<Option<Value>, String> + Send + Sync + 'static,
        G: Fn(String) + Send + 'static,
        I: Fn(String) + Send + Sync + 'static,
    {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            return self.start_claude_turn_streaming(
                thread_id,
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
            );
        }

        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let TurnStartRequest {
            prompt,
            images,
            model,
            effort,
            permission_mode: _,
        } = request;
        let reserved_transports = Arc::clone(&self.reserved_transports);
        let on_control_request = Arc::new(on_control_request);
        let on_stream_finished = Arc::new(on_stream_finished);
        let (result_tx, result_rx) = mpsc::sync_channel(1);

        std::thread::spawn(move || {
            let reserved_transport = take_reserved_transport(&reserved_transports, &thread_id);
            let had_reserved_transport = reserved_transport.is_some();
            let mut transport = match reserved_transport {
                Some(transport) => transport,
                None => match connect_transport(&config) {
                    Ok(transport) => transport,
                    Err(error) => {
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                },
            };

            let payload = if had_reserved_transport {
                match start_turn(
                    &mut transport,
                    &thread_id,
                    &prompt,
                    &images,
                    model.as_deref(),
                    effort.as_deref(),
                ) {
                    Ok(payload) => payload,
                    Err(error) if should_resume_thread(&error) => {
                        match start_turn_with_resume(
                            &mut transport,
                            &thread_id,
                            &prompt,
                            &images,
                            model.as_deref(),
                            effort.as_deref(),
                        ) {
                            Ok(payload) => payload,
                            Err(error) => {
                                reserve_transport(
                                    &reserved_transports,
                                    thread_id.clone(),
                                    transport,
                                );
                                let _ = result_tx.send(Err(error));
                                return;
                            }
                        }
                    }
                    Err(error) => {
                        reserve_transport(&reserved_transports, thread_id.clone(), transport);
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                }
            } else {
                match start_turn_with_resume(
                    &mut transport,
                    &thread_id,
                    &prompt,
                    &images,
                    model.as_deref(),
                    effort.as_deref(),
                ) {
                    Ok(payload) => payload,
                    Err(error) => {
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                }
            };

            let result = GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.clone(),
                    thread_status: ThreadStatus::Running,
                    message: format!("turn {} started", payload.turn.id),
                    turn_id: Some(payload.turn.id.clone()),
                },
                turn_id: Some(payload.turn.id),
            };
            if result_tx.send(Ok(result.clone())).is_err() {
                on_stream_finished(thread_id.clone());
                return;
            }

            let mut normalizer = CodexNotificationNormalizer::default();
            loop {
                let message = match transport.next_message("turn stream") {
                    Ok(Some(message)) => message,
                    Ok(None) => break,
                    Err(_) => break,
                };
                if let Some(request_id) = message.get("id").cloned() {
                    let Some(method) = message.get("method").and_then(Value::as_str) else {
                        continue;
                    };
                    let params = message.get("params").cloned().unwrap_or(Value::Null);
                    match on_control_request(GatewayTurnControlRequest::CodexApproval {
                        request_id: request_id.clone(),
                        method: method.to_string(),
                        params,
                    }) {
                        Ok(Some(response_payload)) => {
                            if let Err(error) = transport.respond(&request_id, response_payload) {
                                eprintln!(
                                    "failed to send codex control response for {thread_id}: {error}"
                                );
                                break;
                            }
                        }
                        Ok(None) => {}
                        Err(error) => {
                            let _ = transport.respond_error(&request_id, -32000, &error);
                        }
                    }
                    continue;
                }

                let Some(method) = message.get("method").and_then(Value::as_str) else {
                    continue;
                };
                let params = message.get("params").cloned().unwrap_or(Value::Null);

                if let Some(event) = normalizer.normalize(method, &params)
                    && event.thread_id == thread_id
                {
                    on_event(event);
                }

                if method == "turn/completed" {
                    on_turn_completed(thread_id.clone());
                    break;
                }
            }
            on_stream_finished(thread_id.clone());
        });

        result_rx
            .recv()
            .map_err(|error| format!("failed to receive codex turn-start result: {error}"))?
    }

    fn start_claude_turn_streaming<F, G, H, I>(
        &self,
        thread_id: &str,
        request: TurnStartRequest,
        on_event: F,
        on_control_request: H,
        on_turn_completed: G,
        _on_stream_finished: I,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
        H: Fn(GatewayTurnControlRequest) -> Result<Option<Value>, String> + Send + Sync + 'static,
        G: Fn(String) + Send + 'static,
        I: Fn(String) + Send + Sync + 'static,
    {
        if !is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            return Err(format!("thread {thread_id} is not a Claude Code thread"));
        }

        let thread_id = thread_id.to_string();
        let native_thread_id = native_thread_id_for_provider(&thread_id, ProviderKind::ClaudeCode)
            .ok_or_else(|| format!("thread {thread_id} is not a Claude Code thread"))?
            .to_string();
        let workspace = self
            .claude_thread_workspaces
            .lock()
            .expect("claude thread workspace lock should not be poisoned")
            .get(&thread_id)
            .cloned()
            .or_else(|| {
                fetch_thread_snapshot_from_archive(&self.config, &thread_id)
                    .ok()
                    .map(|snapshot| snapshot.thread.workspace)
            })
            .ok_or_else(|| format!("workspace for Claude thread {thread_id} is unavailable"))?;
        let active_claude_processes = Arc::clone(&self.active_claude_processes);
        let interrupted_claude_threads = Arc::clone(&self.interrupted_claude_threads);
        let on_control_request = Arc::new(on_control_request);
        let (result_tx, result_rx) = mpsc::sync_channel(1);

        std::thread::spawn(move || {
            let session_exists = claude_session_archive_path(&workspace, &native_thread_id)
                .is_some_and(|path| path.is_file());
            let (sdk_listener, sdk_url) = match bind_claude_sdk_listener() {
                Ok(listener) => listener,
                Err(error) => {
                    let _ = result_tx.send(Err(error));
                    return;
                }
            };
            let mut command = Command::new("claude");
            command
                .current_dir(&workspace)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .env("CLAUDE_CODE_ENVIRONMENT_KIND", "bridge")
                .arg("--print")
                .arg("--verbose")
                .arg("--include-partial-messages")
                .arg("--output-format")
                .arg("stream-json")
                .arg("--input-format")
                .arg("stream-json")
                .arg("--replay-user-messages")
                .arg("--sdk-url")
                .arg(&sdk_url)
                .arg("--permission-mode")
                .arg(request.permission_mode.as_deref().unwrap_or("default"));
            if session_exists {
                command.arg("--resume").arg(&native_thread_id);
            } else {
                command.arg("--session-id").arg(&native_thread_id);
            }
            if let Some(model) = request
                .model
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                command.arg("--model").arg(model);
            }
            if let Some(effort) = request
                .effort
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                command.arg("--effort").arg(effort);
            }

            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) => {
                    let _ = result_tx.send(Err(format!("failed to start claude: {error}")));
                    return;
                }
            };
            let stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => {
                    let _ = result_tx.send(Err("Claude process did not expose stdout".to_string()));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let stdin = match child.stdin.take() {
                Some(stdin) => stdin,
                None => {
                    let _ = result_tx.send(Err("Claude process did not expose stdin".to_string()));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let stderr = child.stderr.take();
            let input_line = match build_claude_input_message(&request.prompt, &request.images) {
                Ok(line) => line,
                Err(error) => {
                    let _ = result_tx.send(Err(error));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let child_handle = Arc::new(Mutex::new(child));
            active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .insert(thread_id.clone(), Arc::clone(&child_handle));

            let stdin_handle = Arc::new(Mutex::new(stdin));
            let stdout_reader = std::thread::spawn(move || {
                let mut stdout_output = String::new();
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else {
                        break;
                    };
                    stdout_output.push_str(&line);
                    stdout_output.push('\n');
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                }
                stdout_output
            });
            let stderr_reader = std::thread::spawn(move || {
                let mut stderr_output = String::new();
                if let Some(mut stderr) = stderr {
                    let _ = stderr.read_to_string(&mut stderr_output);
                }
                stderr_output
            });
            let mut sdk_socket =
                match accept_claude_sdk_connection(&sdk_listener, &child_handle, &thread_id) {
                    Ok(socket) => socket,
                    Err(error) => {
                        remove_claude_process(&active_claude_processes, &thread_id);
                        let stdout_output = stdout_reader.join().unwrap_or_default();
                        let stderr_output = stderr_reader.join().unwrap_or_default();
                        if !stdout_output.trim().is_empty() {
                            eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
                        }
                        if !stderr_output.trim().is_empty() {
                            eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
                        }
                        let _ = result_tx.send(Err(summarize_claude_process_failure(
                            error,
                            &stdout_output,
                            &stderr_output,
                        )));
                        return;
                    }
                };
            let initialize_request_id = Uuid::new_v4().to_string();
            if let Err(error) = write_claude_sdk_control_request(
                &mut sdk_socket,
                &initialize_request_id,
                &native_thread_id,
                json!({
                    "subtype": "initialize",
                }),
            ) {
                let _ = child_handle
                    .lock()
                    .expect("claude child lock should not be poisoned")
                    .kill();
                remove_claude_process(&active_claude_processes, &thread_id);
                let stdout_output = stdout_reader.join().unwrap_or_default();
                let stderr_output = stderr_reader.join().unwrap_or_default();
                if !stdout_output.trim().is_empty() {
                    eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
                }
                if !stderr_output.trim().is_empty() {
                    eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
                }
                let _ = result_tx.send(Err(summarize_claude_process_failure(
                    error,
                    &stdout_output,
                    &stderr_output,
                )));
                return;
            }

            let turn_id = format!("claude-turn-{native_thread_id}");
            let accepted = GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.clone(),
                    thread_status: ThreadStatus::Running,
                    message: format!("turn {turn_id} started"),
                    turn_id: Some(turn_id.clone()),
                },
                turn_id: Some(turn_id),
            };
            let mut did_ack = false;
            let mut did_report_turn_start = false;
            let mut did_emit_completion = false;
            let mut did_emit_assistant_output = false;
            let mut did_send_input = false;
            let mut current_assistant_message_id: Option<String> = None;
            let mut current_assistant_text = String::new();

            loop {
                let value = match read_claude_sdk_message(&mut sdk_socket) {
                    Ok(Some(value)) => value,
                    Ok(None) => break,
                    Err(error) => {
                        eprintln!("failed to read Claude SDK message for {thread_id}: {error}");
                        break;
                    }
                };
                if let Some(request_id) = parse_claude_control_request_id(&value) {
                    let request = value
                        .get("request")
                        .cloned()
                        .unwrap_or(Value::Object(serde_json::Map::new()));
                    match request.get("subtype").and_then(Value::as_str) {
                        Some("can_use_tool") => {
                            match on_control_request(GatewayTurnControlRequest::ClaudeCanUseTool {
                                request_id: request_id.clone(),
                                request,
                            }) {
                                Ok(Some(response_payload)) => {
                                    if let Err(error) = write_claude_stdin_control_response(
                                        &stdin_handle,
                                        &request_id,
                                        response_payload,
                                    ) {
                                        eprintln!(
                                            "failed to write Claude stdin control response for {thread_id}: {error}"
                                        );
                                        break;
                                    }
                                }
                                Ok(None) => {}
                                Err(error) => {
                                    if let Err(write_error) =
                                        write_claude_stdin_control_error_response(
                                            &stdin_handle,
                                            &request_id,
                                            &error,
                                        )
                                    {
                                        eprintln!(
                                            "failed to write Claude stdin control error response for {thread_id}: {write_error}"
                                        );
                                        break;
                                    }
                                }
                            }
                        }
                        _ => {
                            if let Err(error) = write_claude_stdin_control_error_response(
                                &stdin_handle,
                                &request_id,
                                "unsupported control request subtype",
                            ) {
                                eprintln!(
                                    "failed to write Claude stdin control error response for {thread_id}: {error}"
                                );
                                break;
                            }
                        }
                    }
                    continue;
                }

                if let Some(cancel_request_id) = parse_claude_control_cancel_request_id(&value) {
                    let _ = on_control_request(GatewayTurnControlRequest::ClaudeControlCancel {
                        request_id: cancel_request_id,
                    });
                    continue;
                }

                if !did_ack
                    && value.get("type").and_then(Value::as_str) == Some("system")
                    && value.get("subtype").and_then(Value::as_str) == Some("init")
                {
                    if result_tx.send(Ok(accepted.clone())).is_err() {
                        remove_claude_process(&active_claude_processes, &thread_id);
                        return;
                    }
                    did_report_turn_start = true;
                    did_ack = true;
                }

                if value.get("type").and_then(Value::as_str) == Some("control_response") {
                    let Some(response) = value.get("response") else {
                        continue;
                    };
                    let Some(request_id) = response.get("request_id").and_then(Value::as_str)
                    else {
                        continue;
                    };
                    if request_id != initialize_request_id {
                        continue;
                    }
                    if response.get("subtype").and_then(Value::as_str) != Some("success") {
                        let error = response
                            .get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("Claude SDK initialization failed")
                            .to_string();
                        let _ = result_tx.send(Err(error));
                        did_report_turn_start = true;
                        break;
                    }
                    if !did_send_input {
                        if let Err(error) =
                            write_claude_turn_input(&stdin_handle, input_line.as_bytes())
                        {
                            let _ = result_tx.send(Err(error));
                            did_report_turn_start = true;
                            break;
                        }
                        did_send_input = true;
                    }
                    if !did_ack {
                        if result_tx.send(Ok(accepted.clone())).is_err() {
                            remove_claude_process(&active_claude_processes, &thread_id);
                            return;
                        }
                        did_report_turn_start = true;
                        did_ack = true;
                    }
                    continue;
                }

                if let Some(event) = build_claude_assistant_event(&thread_id, &value) {
                    did_emit_assistant_output = true;
                    on_event(event);
                }

                if let Some(message_id) = parse_claude_message_start(&value) {
                    current_assistant_message_id = Some(message_id);
                    current_assistant_text.clear();
                }

                if let Some(delta) = parse_claude_text_delta(&value)
                    && let Some(message_id) = current_assistant_message_id.as_deref()
                {
                    current_assistant_text.push_str(&delta);
                    did_emit_assistant_output = true;
                    on_event(build_claude_partial_assistant_event(
                        &thread_id,
                        message_id,
                        &current_assistant_text,
                    ));
                }

                if let Some(status_event) = build_claude_status_event(&thread_id, &value) {
                    if !did_ack {
                        let _ = result_tx.send(Ok(accepted.clone()));
                        did_report_turn_start = true;
                    }
                    on_event(status_event);
                    did_emit_completion = true;
                    on_turn_completed(thread_id.clone());
                    break;
                }
            }

            let exit_status = child_handle
                .lock()
                .expect("claude child lock should not be poisoned")
                .wait();
            remove_claude_process(&active_claude_processes, &thread_id);
            let stdout_output = stdout_reader.join().unwrap_or_default();
            let stderr_output = stderr_reader.join().unwrap_or_default();
            if !stdout_output.trim().is_empty() {
                eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
            }
            if !stderr_output.trim().is_empty() {
                eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
            }

            if !did_emit_completion {
                let was_interrupted = interrupted_claude_threads
                    .lock()
                    .expect("interrupted claude thread lock should not be poisoned")
                    .remove(&thread_id);
                let status = if was_interrupted {
                    ThreadStatus::Interrupted
                } else {
                    ThreadStatus::Failed
                };
                let reason = if was_interrupted {
                    "interrupt_requested"
                } else {
                    "claude_process_exited"
                };
                on_event(build_thread_status_event(&thread_id, status, reason));
                on_turn_completed(thread_id.clone());
            }

            if !did_report_turn_start {
                let exit_message = match exit_status {
                    Ok(status) if !status.success() => format!(
                        "Claude process exited with status {}",
                        status.code().unwrap_or_default()
                    ),
                    Ok(_) if did_emit_assistant_output => "Claude turn completed".to_string(),
                    Ok(_) if !did_send_input => {
                        "Claude exited before the SDK bridge accepted the turn".to_string()
                    }
                    Ok(_) => "Claude exited before the turn was accepted".to_string(),
                    Err(error) => format!("failed waiting for Claude process: {error}"),
                };
                let message = if let Some(summary) = summarize_claude_stderr(&stderr_output)
                    .or_else(|| summarize_claude_stdout(&stdout_output))
                {
                    format!("{exit_message}: {summary}")
                } else {
                    exit_message
                };
                let _ = result_tx.send(Err(message));
            }
        });

        result_rx
            .recv()
            .map_err(|error| format!("failed to receive Claude turn-start result: {error}"))?
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<GatewayTurnMutation, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            let thread_id = thread_id.to_string();
            let active_process = self
                .active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .get(&thread_id)
                .cloned()
                .ok_or_else(|| format!("no active Claude turn found for thread {thread_id}"))?;
            self.interrupted_claude_threads
                .lock()
                .expect("interrupted claude thread lock should not be poisoned")
                .insert(thread_id.clone());
            active_process
                .lock()
                .expect("claude child lock should not be poisoned")
                .kill()
                .map_err(|error| format!("failed to interrupt Claude turn: {error}"))?;
            return Ok(GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id,
                    thread_status: ThreadStatus::Interrupted,
                    message: "interrupt requested".to_string(),
                    turn_id: None,
                },
                turn_id: None,
            });
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let turn_id = turn_id.to_string();
        tokio::task::spawn_blocking(move || -> Result<GatewayTurnMutation, String> {
            let native_thread_id =
                native_thread_id_for_provider(&thread_id, ProviderKind::Codex)
                    .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
            let mut transport = connect_transport(&config)?;
            transport.request(
                "turn/interrupt",
                serde_json::json!({
                    "threadId": native_thread_id,
                    "turnId": turn_id,
                }),
            )?;
            Ok(GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id,
                    thread_status: ThreadStatus::Interrupted,
                    message: "interrupt requested".to_string(),
                    turn_id: None,
                },
                turn_id: None,
            })
        })
        .await
        .map_err(|error| format!("codex interrupt_turn task failed: {error}"))?
    }

    pub async fn resolve_active_turn_id(&self, thread_id: &str) -> Result<String, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            let thread_id = thread_id.to_string();
            return self
                .active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .contains_key(&thread_id)
                .then_some(thread_id.clone())
                .ok_or_else(|| format!("no active Claude turn found for thread {thread_id}"));
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || -> Result<String, String> {
            let mut transport = take_reserved_transport(&reserved_transports, &thread_id)
                .unwrap_or(connect_read_transport(&config)?);
            let payload = read_thread_with_resume(&mut transport, &thread_id, true)?;
            let active_turn_id = payload
                .thread
                .turns
                .last()
                .map(|turn| turn.id.clone())
                .ok_or_else(|| format!("no active turn found for thread {thread_id}"))?;
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(active_turn_id)
        })
        .await
        .map_err(|error| format!("codex resolve_active_turn_id task failed: {error}"))?
    }

    pub async fn set_thread_name(&self, thread_id: &str, name: &str) -> Result<(), String> {
        if !is_provider_thread_id(thread_id, ProviderKind::Codex) {
            return Err(format!(
                "thread {thread_id} belongs to a read-only provider; renaming is only implemented for codex threads"
            ));
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let name = name.trim().to_string();
        tokio::task::spawn_blocking(move || -> Result<(), String> {
            if name.is_empty() {
                return Ok(());
            }

            let native_thread_id =
                native_thread_id_for_provider(&thread_id, ProviderKind::Codex)
                    .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
            let mut transport = connect_transport(&config)?;
            transport.request(
                "thread/name/set",
                json!({
                    "threadId": native_thread_id,
                    "name": name,
                }),
            )?;
            Ok(())
        })
        .await
        .map_err(|error| format!("codex set_thread_name task failed: {error}"))?
    }

    pub async fn generate_thread_title_candidate(
        &self,
        workspace: &str,
        prompt: &str,
        model: Option<&str>,
    ) -> Result<Option<String>, String> {
        let config = self.config.clone();
        let workspace = workspace.to_string();
        let prompt = prompt.to_string();
        let model = model.map(str::to_string);
        tokio::task::spawn_blocking(move || -> Result<Option<String>, String> {
            let normalized_prompt = prompt.trim();
            if normalized_prompt.is_empty() {
                return Ok(None);
            }

            let mut transport = connect_transport(&config)?;
            let title_thread_id =
                start_ephemeral_read_only_thread(&mut transport, &workspace, model.as_deref())?;
            let turn = start_structured_turn(
                &mut transport,
                &title_thread_id,
                &build_thread_title_prompt(normalized_prompt),
                build_thread_title_output_schema(),
                model.as_deref(),
                Some("low"),
            )?;
            let agent_message = read_structured_agent_message(
                &mut transport,
                &title_thread_id,
                &turn.turn.id,
                "thread title generation",
            )?;
            Ok(extract_generated_thread_title(agent_message.as_deref()))
        })
        .await
        .map_err(|error| format!("codex generate_thread_title task failed: {error}"))?
    }
}

fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

fn should_read_without_turns(error: &str) -> bool {
    error.contains("includeTurns is unavailable before first user message")
        || error.contains("is not materialized yet")
}

fn read_thread_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    match read_thread(transport, thread_id, include_turns) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            resume_thread(transport, thread_id)?;
            read_thread(transport, thread_id, include_turns)
        }
        Err(error) => Err(error),
    }
}

fn read_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/read",
        serde_json::json!({
            "threadId": native_thread_id,
            "includeTurns": include_turns,
        }),
    )?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/read response from codex: {error}"))
}

fn resume_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
) -> Result<CodexThread, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/resume",
        serde_json::json!({
            "threadId": native_thread_id,
        }),
    )?;
    let payload: CodexThreadResumeResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/resume response from codex: {error}"))?;
    Ok(payload.thread)
}

fn start_turn_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    match start_turn(transport, thread_id, prompt, images, model, effort) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            if let Err(resume_error) = resume_thread(transport, thread_id)
                && !resume_error.contains("no rollout found")
            {
                return Err(resume_error);
            }
            start_turn(transport, thread_id, prompt, images, model, effort)
        }
        Err(error) => Err(error),
    }
}

fn start_ephemeral_read_only_thread(
    transport: &mut CodexJsonTransport,
    workspace: &str,
    model: Option<&str>,
) -> Result<String, String> {
    let mut params = serde_json::Map::new();
    params.insert("cwd".to_string(), Value::String(workspace.to_string()));
    params.insert(
        "approvalPolicy".to_string(),
        Value::String("never".to_string()),
    );
    params.insert(
        "sandbox".to_string(),
        Value::String("read-only".to_string()),
    );
    params.insert("ephemeral".to_string(), Value::Bool(true));
    params.insert("persistExtendedHistory".to_string(), Value::Bool(false));
    params.insert("experimentalRawEvents".to_string(), Value::Bool(false));
    params.insert(
        "config".to_string(),
        json!({
            "web_search": "disabled",
            "model_reasoning_effort": "low",
        }),
    );
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }

    let response = transport.request("thread/start", Value::Object(params))?;
    let payload: CodexThreadStartResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/start response from codex: {error}"))?;
    Ok(payload.thread.id)
}

fn start_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let mut params = serde_json::Map::new();
    params.insert(
        "threadId".to_string(),
        Value::String(native_thread_id.to_string()),
    );
    params.insert("input".to_string(), build_turn_start_input(prompt, images));
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

fn start_structured_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    output_schema: Value,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_string(), Value::String(thread_id.to_string()));
    params.insert("input".to_string(), build_turn_start_input(prompt, &[]));
    params.insert("summary".to_string(), Value::String("auto".to_string()));
    params.insert("outputSchema".to_string(), output_schema);
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

fn build_turn_start_input(prompt: &str, images: &[String]) -> Value {
    let mut input = Vec::new();
    if !prompt.trim().is_empty() {
        input.push(serde_json::json!({
            "type": "text",
            "text": prompt,
            "text_elements": [],
        }));
    }
    for image in images
        .iter()
        .map(|image| image.trim())
        .filter(|image| !image.is_empty())
    {
        input.push(serde_json::json!({
            "type": "image",
            "url": image,
        }));
    }

    Value::Array(input)
}

fn read_structured_agent_message(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    turn_id: &str,
    context: &str,
) -> Result<Option<String>, String> {
    let mut latest_agent_message: Option<String> = None;

    while let Some(message) = transport.next_message(context)? {
        if message.get("id").is_some() {
            continue;
        }

        let Some(method) = message.get("method").and_then(Value::as_str) else {
            continue;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        match method {
            "item/agentMessage/delta" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let delta = params
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if delta.is_empty() {
                    continue;
                }
                let next_value = latest_agent_message
                    .take()
                    .unwrap_or_default()
                    .chars()
                    .chain(delta.chars())
                    .collect::<String>();
                latest_agent_message = Some(next_value);
            }
            "item/completed" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let Some(item) = params.get("item") else {
                    continue;
                };
                if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                    continue;
                }
                latest_agent_message = item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(ToString::to_string);
            }
            "turn/completed" => {
                if params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != thread_id
                {
                    continue;
                }
                if params
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != turn_id
                {
                    continue;
                }
                let status = params
                    .get("turn")
                    .and_then(|turn| turn.get("status"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if status != "completed" {
                    return Ok(None);
                }
                return Ok(latest_agent_message);
            }
            _ => {}
        }
    }

    Ok(latest_agent_message)
}

fn build_thread_title_prompt(prompt: &str) -> String {
    [
        "Generate a concise thread title for the user's request.",
        "Write the result into the structured response field title.",
        "Rules:",
        "- Keep the title under 80 characters.",
        "- Use plain text only in the title field.",
        "- Prefer an imperative title when the request is actionable.",
        "- Preserve important product or framework names like Flutter, Rust, macOS, Android, iOS, Codex, and Tailscale.",
        "- Do not include quotes, markdown, trailing punctuation, or filler words like 'Please' or 'Help me'.",
        "",
        "User request:",
        prompt,
    ]
    .join("\n")
}

fn build_thread_title_output_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "title": {
                "type": "string",
                "minLength": 4,
                "maxLength": CodexGateway::THREAD_TITLE_MAX_CHARS,
            }
        },
        "required": ["title"],
    })
}

fn extract_generated_thread_title(agent_message: Option<&str>) -> Option<String> {
    let agent_message = agent_message?.trim();
    if agent_message.is_empty() {
        return None;
    }

    let parsed = serde_json::from_str::<Value>(agent_message).ok();
    let raw_title = parsed
        .as_ref()
        .and_then(|value| value.get("title"))
        .and_then(Value::as_str)
        .unwrap_or(agent_message);
    normalize_generated_thread_title(raw_title)
}

fn normalize_generated_thread_title(raw_title: &str) -> Option<String> {
    let normalized_whitespace = raw_title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim_matches(|ch: char| ch == '"' || ch == '\'' || ch == '`')
        .trim();
    if trimmed.is_empty() || is_placeholder_thread_title(trimmed) {
        return None;
    }

    let mut title = trimmed.to_string();
    if title.chars().count() > CodexGateway::THREAD_TITLE_MAX_CHARS {
        title = title
            .chars()
            .take(CodexGateway::THREAD_TITLE_MAX_CHARS)
            .collect::<String>()
            .trim()
            .to_string();
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

fn connect_transport(config: &BridgeCodexConfig) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Attach => {
            CodexJsonTransport::start(&config.command, &config.args, config.endpoint.as_deref())
        }
        CodexRuntimeMode::Spawn => CodexJsonTransport::start(&config.command, &config.args, None),
        CodexRuntimeMode::Auto => {
            if let Some(endpoint) = config.endpoint.as_deref()
                && let Ok(transport) =
                    CodexJsonTransport::start(&config.command, &config.args, Some(endpoint))
            {
                return Ok(transport);
            }
            CodexJsonTransport::start(&config.command, &config.args, None)
        }
    }
}

fn connect_read_transport(config: &BridgeCodexConfig) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Spawn => connect_transport(config),
        CodexRuntimeMode::Attach | CodexRuntimeMode::Auto => {
            CodexJsonTransport::start(&config.command, &config.args, None)
                .or_else(|_| connect_transport(config))
        }
    }
}

fn take_reserved_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: &str,
) -> Option<CodexJsonTransport> {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.remove(thread_id).map(|entry| entry.transport)
}

fn reserve_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: String,
    transport: CodexJsonTransport,
) {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.insert(
        thread_id,
        ReservedTransport {
            reserved_at: Instant::now(),
            transport,
        },
    );
}

fn prune_reserved_transports(reserved: &mut HashMap<String, ReservedTransport>) {
    reserved.retain(|_, entry| entry.reserved_at.elapsed() <= CodexGateway::RESERVED_TRANSPORT_TTL);
}

fn fetch_thread_summaries(
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
                .map(map_thread_summary),
        );

        if let Some(next_cursor) = payload.next_cursor {
            cursor = Some(next_cursor);
        } else {
            break;
        }
    }

    Ok(summaries)
}

fn fetch_thread_summaries_from_archive(
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

fn fetch_thread_snapshot_from_archive(
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

fn fetch_model_catalog(transport: &mut CodexJsonTransport) -> Vec<ModelOptionDto> {
    match transport.request(
        "model/list",
        serde_json::json!({
            "cursor": Value::Null,
            "limit": 50,
            "includeHidden": false,
        }),
    ) {
        Ok(response) => {
            let models = parse_model_options(response);
            if models.is_empty() {
                fallback_model_options()
            } else {
                models
            }
        }
        Err(_) => fallback_model_options(),
    }
}

fn fallback_claude_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "claude-sonnet-4-6".to_string(),
            model: "claude-sonnet-4-6".to_string(),
            display_name: "Claude Sonnet 4.6".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-6".to_string(),
            model: "claude-opus-4-6".to_string(),
            display_name: "Claude Opus 4.6".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-sonnet-4-5".to_string(),
            model: "claude-sonnet-4-5".to_string(),
            display_name: "Claude Sonnet 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-5".to_string(),
            model: "claude-opus-4-5".to_string(),
            display_name: "Claude Opus 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
    ]
}

fn fallback_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "gpt-5".to_string(),
            model: "gpt-5".to_string(),
            display_name: "GPT-5".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "gpt-5-mini".to_string(),
            model: "gpt-5-mini".to_string(),
            display_name: "GPT-5 Mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "o4-mini".to_string(),
            model: "o4-mini".to_string(),
            display_name: "o4-mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
    ]
}

fn claude_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
    vec![
        ReasoningEffortOptionDto {
            reasoning_effort: "low".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "medium".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "high".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "max".to_string(),
            description: None,
        },
    ]
}

fn fallback_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
    vec![
        ReasoningEffortOptionDto {
            reasoning_effort: "low".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "medium".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "high".to_string(),
            description: None,
        },
    ]
}

fn build_claude_placeholder_snapshot(thread_id: &str, workspace: &str) -> ThreadSnapshotDto {
    let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let git_context = detect_git_context(workspace);
    let repository = git_context.repository.clone();
    let branch = git_context.branch.clone();
    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            native_thread_id: native_thread_id_for_provider(thread_id, ProviderKind::ClaudeCode)
                .unwrap_or(thread_id)
                .to_string(),
            provider: ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "New thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: workspace.to_string(),
            repository: repository.clone(),
            branch: branch.clone(),
            created_at: timestamp.clone(),
            updated_at: timestamp,
            source: "bridge".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: Some(GitStatusDto {
            workspace: workspace.to_string(),
            repository,
            branch,
            remote: git_context.remote,
            dirty: false,
            ahead_by: 0,
            behind_by: 0,
        }),
        pending_user_input: None,
    }
}

#[derive(Debug, Clone)]
struct WorkspaceGitContext {
    repository: String,
    branch: String,
    remote: Option<String>,
}

fn detect_git_context(workspace: &str) -> WorkspaceGitContext {
    let repository = run_git_output(workspace, ["rev-parse", "--show-toplevel"])
        .ok()
        .as_deref()
        .and_then(derive_repository_name_from_path)
        .or_else(|| derive_repository_name_from_cwd(workspace))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = run_git_output(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let remote = run_git_output(workspace, ["remote", "get-url", "origin"])
        .ok()
        .filter(|value| !value.trim().is_empty());

    WorkspaceGitContext {
        repository,
        branch,
        remote,
    }
}

fn run_git_output<I, S>(workspace: &str, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let output = Command::new("git")
        .arg("-C")
        .arg(workspace)
        .args(args)
        .output()
        .map_err(|error| format!("failed to run git: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn derive_repository_name_from_path(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn claude_session_archive_path(workspace: &str, session_id: &str) -> Option<PathBuf> {
    let claude_home = std::env::var_os("CLAUDE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude")))?;
    Some(
        claude_home
            .join("projects")
            .join(claude_project_slug(workspace))
            .join(format!("{session_id}.jsonl")),
    )
}

fn claude_project_slug(workspace: &str) -> String {
    workspace
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '-'
            }
        })
        .collect()
}

fn build_claude_input_message(prompt: &str, images: &[String]) -> Result<String, String> {
    let content = build_claude_message_content(prompt, images)?;
    serde_json::to_string(&json!({
        "type": "user",
        "message": {
            "role": "user",
            "content": content,
        },
        "parent_tool_use_id": Value::Null,
    }))
    .map(|line| format!("{line}\n"))
    .map_err(|error| format!("failed to encode Claude turn input: {error}"))
}

fn build_claude_message_content(prompt: &str, images: &[String]) -> Result<Value, String> {
    let trimmed_prompt = prompt.trim();
    if images.is_empty() {
        return Ok(Value::String(trimmed_prompt.to_string()));
    }

    let mut blocks = Vec::new();
    if !trimmed_prompt.is_empty() {
        blocks.push(json!({
            "type": "text",
            "text": trimmed_prompt,
        }));
    }
    for (index, image) in images.iter().enumerate() {
        let parsed = parse_data_url_image(image)
            .map_err(|error| format!("image attachment {} is invalid: {error}", index + 1))?;
        blocks.push(json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": parsed.mime_type,
                "data": parsed.base64_data,
            },
        }));
    }

    Ok(Value::Array(blocks))
}

struct ParsedDataUrlImage {
    mime_type: String,
    base64_data: String,
}

fn parse_data_url_image(data_url: &str) -> Result<ParsedDataUrlImage, String> {
    let trimmed = data_url.trim();
    let Some((metadata, payload)) = trimmed.split_once(',') else {
        return Err("data URL is missing a payload".to_string());
    };
    if !metadata.starts_with("data:") {
        return Err("image must be a data URL".to_string());
    }
    if !metadata.contains(";base64") {
        return Err("image data URL must be base64-encoded".to_string());
    }

    let mime_type = metadata
        .trim_start_matches("data:")
        .split(';')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "image data URL is missing a MIME type".to_string())?;
    if !matches!(
        mime_type,
        "image/jpeg" | "image/png" | "image/gif" | "image/webp"
    ) {
        return Err(format!(
            "unsupported MIME type {mime_type}; Claude Code currently supports image/jpeg, image/png, image/gif, and image/webp"
        ));
    }

    let base64_data = payload.trim();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .map_err(|error| format!("invalid base64 payload: {error}"))?;
    if decoded.is_empty() {
        return Err("image payload is empty".to_string());
    }

    Ok(ParsedDataUrlImage {
        mime_type: mime_type.to_string(),
        base64_data: base64_data.to_string(),
    })
}

fn summarize_claude_stderr(stderr_output: &str) -> Option<String> {
    let lines = stderr_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    if lines.is_empty() {
        return None;
    }

    let preferred = lines
        .iter()
        .copied()
        .find(|line| looks_like_claude_error_summary(line))
        .map(|line| truncate_for_mobile_error(line, 240));
    if preferred.is_some() {
        return preferred;
    }

    let fallback = lines
        .iter()
        .copied()
        .find(|line| !looks_like_claude_stack_noise(line))
        .map(|line| truncate_for_mobile_error(line, 240));
    if fallback.is_some() {
        return fallback;
    }

    Some("Claude CLI crashed before it returned a usable error message.".to_string())
}

fn looks_like_claude_error_summary(line: &str) -> bool {
    let normalized = line.to_ascii_lowercase();
    normalized.starts_with("error:")
        || normalized.contains("invalid session")
        || normalized.contains("already in use")
        || normalized.contains("permission denied")
        || normalized.contains("not found")
        || normalized.contains("unsupported")
        || normalized.contains("authentication")
        || normalized.contains("rate limit")
        || normalized.contains("timed out")
}

fn looks_like_claude_stack_noise(line: &str) -> bool {
    if line.starts_with("file://") || line.starts_with("at ") || line.starts_with("node:") {
        return true;
    }

    let punctuation_count = line
        .chars()
        .filter(|ch| matches!(ch, '{' | '}' | '(' | ')' | ';' | '=' | ',' | '[' | ']'))
        .count();
    (line.len() > 160 && punctuation_count > 20)
        || (punctuation_count > 8
            && (line.starts_with("`)}")
                || line.contains(".error.")
                || line.contains("function ")
                || line.contains("exports=")))
}

fn truncate_for_mobile_error(line: &str, max_chars: usize) -> String {
    let mut trimmed = line.trim().to_string();
    if trimmed.chars().count() <= max_chars {
        return trimmed;
    }

    trimmed = trimmed.chars().take(max_chars.saturating_sub(3)).collect();
    trimmed.push_str("...");
    trimmed
}

fn build_claude_assistant_event(
    thread_id: &str,
    value: &Value,
) -> Option<BridgeEventEnvelope<Value>> {
    if value.get("type").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let message = value.get("message")?;
    let message_id = message.get("id").and_then(Value::as_str)?.trim();
    if message_id.is_empty() {
        return None;
    }
    let text = claude_message_text(message)?;
    if text.trim().is_empty() {
        return None;
    }

    Some(BridgeEventEnvelope::new(
        message_id.to_string(),
        thread_id.to_string(),
        BridgeEventKind::MessageDelta,
        Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        json!({
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "text": text,
        }),
    ))
}

fn build_claude_partial_assistant_event(
    thread_id: &str,
    message_id: &str,
    text: &str,
) -> BridgeEventEnvelope<Value> {
    BridgeEventEnvelope::new(
        message_id.to_string(),
        thread_id.to_string(),
        BridgeEventKind::MessageDelta,
        Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        json!({
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "text": text,
        }),
    )
}

fn parse_claude_message_start(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("stream_event") {
        return None;
    }
    let event = value.get("event")?;
    if event.get("type").and_then(Value::as_str) != Some("message_start") {
        return None;
    }
    event
        .get("message")?
        .get("id")?
        .as_str()
        .map(ToString::to_string)
}

fn parse_claude_text_delta(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("stream_event") {
        return None;
    }
    let event = value.get("event")?;
    if event.get("type").and_then(Value::as_str) != Some("content_block_delta") {
        return None;
    }
    if event.get("delta")?.get("type")?.as_str() != Some("text_delta") {
        return None;
    }
    event
        .get("delta")?
        .get("text")?
        .as_str()
        .map(ToString::to_string)
}

fn parse_claude_control_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn parse_claude_control_cancel_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_cancel_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn bind_claude_sdk_listener() -> Result<(TcpListener, String), String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|error| format!("failed to bind local Claude SDK bridge listener: {error}"))?;
    let address = listener
        .local_addr()
        .map_err(|error| format!("failed to inspect local Claude SDK bridge listener: {error}"))?;
    Ok((listener, format!("ws://127.0.0.1:{}", address.port())))
}

fn accept_claude_sdk_connection(
    listener: &TcpListener,
    child_handle: &Arc<Mutex<Child>>,
    thread_id: &str,
) -> Result<WebSocket<TcpStream>, String> {
    listener.set_nonblocking(true).map_err(|error| {
        format!("failed to configure local Claude SDK bridge listener for {thread_id}: {error}")
    })?;

    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).map_err(|error| {
                    format!(
                        "failed to switch Claude SDK bridge stream to blocking mode for {thread_id}: {error}"
                    )
                })?;
                let _ = stream.set_nodelay(true);
                return accept(stream).map_err(|error| {
                    format!("failed to accept Claude SDK bridge websocket for {thread_id}: {error}")
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                let exited = child_handle
                    .lock()
                    .expect("claude child lock should not be poisoned")
                    .try_wait()
                    .map_err(|wait_error| {
                        format!(
                            "failed to poll Claude child while waiting for SDK bridge for {thread_id}: {wait_error}"
                        )
                    })?
                    .is_some();
                if exited {
                    return Err(format!(
                        "Claude exited before it connected to the local SDK bridge for {thread_id}"
                    ));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(error) => {
                return Err(format!(
                    "failed to accept Claude SDK bridge connection for {thread_id}: {error}"
                ));
            }
        }
    }
}

fn read_claude_sdk_message(socket: &mut WebSocket<TcpStream>) -> Result<Option<Value>, String> {
    loop {
        let message = socket
            .read()
            .map_err(|error| format!("failed reading Claude SDK websocket frame: {error}"))?;
        match message {
            Message::Text(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) => return Ok(Some(value)),
                    Err(_) => continue,
                }
            }
            Message::Binary(bytes) => {
                let text = String::from_utf8(bytes.to_vec()).map_err(|error| {
                    format!("failed decoding Claude SDK websocket frame: {error}")
                })?;
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) => return Ok(Some(value)),
                    Err(_) => continue,
                }
            }
            Message::Ping(payload) => {
                socket
                    .send(Message::Pong(payload))
                    .map_err(|error| format!("failed responding to Claude SDK ping: {error}"))?;
            }
            Message::Pong(_) | Message::Frame(_) => {}
            Message::Close(_) => return Ok(None),
        }
    }
}

fn write_claude_sdk_message(
    socket: &mut WebSocket<TcpStream>,
    payload: &Value,
    context: &str,
) -> Result<(), String> {
    let frame = serde_json::to_string(payload)
        .map_err(|error| format!("failed to serialize Claude SDK {context}: {error}"))?;
    socket
        .send(Message::Text(format!("{frame}\n").into()))
        .map_err(|error| format!("failed to write Claude SDK {context}: {error}"))
}

fn write_claude_sdk_control_request(
    socket: &mut WebSocket<TcpStream>,
    request_id: &str,
    session_id: &str,
    request: Value,
) -> Result<(), String> {
    write_claude_sdk_message(
        socket,
        &json!({
            "type": "control_request",
            "session_id": session_id,
            "request_id": request_id,
            "request": request,
        }),
        "control request",
    )
}

fn write_claude_stdin_message(
    stdin: &Arc<Mutex<ChildStdin>>,
    payload: &Value,
    context: &str,
) -> Result<(), String> {
    let frame = serde_json::to_string(payload)
        .map_err(|error| format!("failed to serialize Claude stdin {context}: {error}"))?;
    let mut stdin = stdin
        .lock()
        .expect("claude stdin lock should not be poisoned");
    stdin
        .write_all(frame.as_bytes())
        .map_err(|error| format!("failed to write Claude stdin {context}: {error}"))?;
    stdin
        .write_all(b"\n")
        .map_err(|error| format!("failed to terminate Claude stdin {context}: {error}"))?;
    stdin
        .flush()
        .map_err(|error| format!("failed to flush Claude stdin {context}: {error}"))
}

fn write_claude_stdin_control_response(
    stdin: &Arc<Mutex<ChildStdin>>,
    request_id: &str,
    response_payload: Value,
) -> Result<(), String> {
    write_claude_stdin_message(
        stdin,
        &json!({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": response_payload,
            },
        }),
        "control response",
    )
}

fn write_claude_stdin_control_error_response(
    stdin: &Arc<Mutex<ChildStdin>>,
    request_id: &str,
    error_message: &str,
) -> Result<(), String> {
    write_claude_stdin_message(
        stdin,
        &json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": request_id,
                "error": error_message,
            },
        }),
        "control error response",
    )
}

fn write_claude_turn_input(stdin: &Arc<Mutex<ChildStdin>>, bytes: &[u8]) -> Result<(), String> {
    let mut stdin = stdin
        .lock()
        .expect("claude stdin lock should not be poisoned");
    stdin
        .write_all(bytes)
        .map_err(|error| format!("failed to write Claude turn input: {error}"))?;
    stdin
        .flush()
        .map_err(|error| format!("failed to flush Claude turn input: {error}"))
}

fn summarize_claude_stdout(stdout_output: &str) -> Option<String> {
    stdout_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .find(|line| looks_like_claude_error_summary(line))
        .map(|line| truncate_for_mobile_error(line, 240))
}

fn summarize_claude_process_failure(
    base_message: String,
    stdout_output: &str,
    stderr_output: &str,
) -> String {
    if let Some(summary) =
        summarize_claude_stderr(stderr_output).or_else(|| summarize_claude_stdout(stdout_output))
    {
        format!("{base_message}: {summary}")
    } else {
        base_message
    }
}

fn claude_message_text(message: &Value) -> Option<String> {
    let content = message.get("content")?.as_array()?;
    let text = content
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn build_claude_status_event(thread_id: &str, value: &Value) -> Option<BridgeEventEnvelope<Value>> {
    if value.get("type").and_then(Value::as_str) != Some("result") {
        return None;
    }

    let is_error = value
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let status = if is_error {
        ThreadStatus::Failed
    } else {
        ThreadStatus::Completed
    };
    let reason = if is_error {
        "claude_result_error"
    } else {
        "claude_result"
    };
    Some(build_thread_status_event(thread_id, status, reason))
}

fn build_thread_status_event(
    thread_id: &str,
    status: ThreadStatus,
    reason: &str,
) -> BridgeEventEnvelope<Value> {
    let occurred_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    BridgeEventEnvelope::new(
        format!("{thread_id}-status-{occurred_at}"),
        thread_id.to_string(),
        BridgeEventKind::ThreadStatusChanged,
        occurred_at,
        json!({
            "status": match status {
                ThreadStatus::Idle => "idle",
                ThreadStatus::Running => "running",
                ThreadStatus::Completed => "completed",
                ThreadStatus::Interrupted => "interrupted",
                ThreadStatus::Failed => "failed",
            },
            "reason": reason,
        }),
    )
}

fn remove_claude_process(
    active_claude_processes: &Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    thread_id: &str,
) {
    active_claude_processes
        .lock()
        .expect("active claude process lock should not be poisoned")
        .remove(thread_id);
}

fn parse_model_options(result: Value) -> Vec<ModelOptionDto> {
    let Some(items) = result.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };

    items.iter().filter_map(parse_model_option).collect()
}

fn parse_model_option(item: &Value) -> Option<ModelOptionDto> {
    let model = value_text(item.get("model")).or_else(|| value_text(item.get("id")))?;
    let id = value_text(item.get("id")).unwrap_or_else(|| model.clone());
    let display_name = value_text(item.get("displayName"))
        .or_else(|| value_text(item.get("display_name")))
        .unwrap_or_else(|| model.clone());
    let description = value_text(item.get("description")).unwrap_or_default();
    let default_reasoning_effort = value_text(item.get("defaultReasoningEffort"))
        .or_else(|| value_text(item.get("default_reasoning_effort")));
    let supported_reasoning_efforts = parse_reasoning_efforts(
        item.get("supportedReasoningEfforts")
            .or_else(|| item.get("supported_reasoning_efforts")),
    );
    let is_default = item
        .get("isDefault")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            item.get("is_default")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });

    Some(ModelOptionDto {
        id,
        model,
        display_name,
        description,
        is_default,
        default_reasoning_effort,
        supported_reasoning_efforts,
    })
}

fn parse_reasoning_efforts(value: Option<&Value>) -> Vec<ReasoningEffortOptionDto> {
    let Some(items) = value.and_then(Value::as_array) else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(|item| {
            let effort = value_text(item.get("reasoningEffort"))
                .or_else(|| value_text(item.get("reasoning_effort")))?;
            let description = value_text(item.get("description"));
            Some(ReasoningEffortOptionDto {
                reasoning_effort: effort,
                description,
            })
        })
        .collect()
}

fn value_text(value: Option<&Value>) -> Option<String> {
    let value = value?;
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn is_placeholder_thread_title(title: &str) -> bool {
    let normalized = title.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "untitled thread"
        || normalized == "new thread"
        || normalized == "fresh session"
}

fn map_thread_summary(thread: CodexThread) -> ThreadSummaryDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .and_then(|git| git.branch)
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();

    ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: format!("codex:{}", thread.id),
        native_thread_id: thread.id,
        provider: ProviderKind::Codex,
        client: map_thread_client_kind_from_source(thread.source.as_str().unwrap_or("unknown")),
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd,
        repository,
        branch,
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
    }
}

fn map_thread_snapshot(thread: CodexThread) -> ThreadSnapshotDto {
    let detail = map_thread_detail(&thread);
    let pending_user_input = pending_user_input_from_thread(&thread);
    let entries = {
        let rpc_entries = map_thread_timeline_entries(&thread);
        let archive_entries = thread
            .path
            .as_deref()
            .map(std::path::Path::new)
            .filter(|path| path.is_absolute() && path.exists())
            .map(|path| load_archive_timeline_entries_for_session_path(&thread.id, path))
            .unwrap_or_else(|| load_archive_timeline_entries_for_thread(&thread.id));
        prefer_archive_timeline_when_rpc_lacks_tool_events(rpc_entries, archive_entries)
    };
    let git_status = Some(map_git_status(&thread));

    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail,
        entries,
        approvals: Vec::<ApprovalSummaryDto>::new(),
        git_status,
        pending_user_input,
    }
}

fn pending_user_input_from_thread(thread: &CodexThread) -> Option<PendingUserInputDto> {
    for turn in thread.turns.iter().rev() {
        for item in turn.items.iter().rev() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
                continue;
            };
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&payload) {
                let Some(message_text) = payload_primary_text(&payload) else {
                    continue;
                };
                if let Some(questionnaire) =
                    parse_pending_user_input_payload(message_text, &thread.id)
                {
                    return Some(questionnaire);
                }
                continue;
            }

            return None;
        }
    }

    None
}

fn prefer_archive_timeline_when_rpc_lacks_tool_events(
    rpc_entries: Vec<ThreadTimelineEntryDto>,
    archive_entries: Vec<ThreadTimelineEntryDto>,
) -> Vec<ThreadTimelineEntryDto> {
    if has_tool_events(&rpc_entries) {
        return rpc_entries;
    }

    if has_tool_events(&archive_entries) {
        return archive_entries;
    }

    rpc_entries
}

fn has_tool_events(entries: &[ThreadTimelineEntryDto]) -> bool {
    entries.iter().any(|entry| {
        matches!(
            entry.kind,
            BridgeEventKind::CommandDelta | BridgeEventKind::FileChange
        )
    })
}

fn map_thread_detail(thread: &CodexThread) -> ThreadDetailDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .as_ref()
        .and_then(|git| git.branch.clone())
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();
    let active_turn_id = (map_thread_status(&thread.status.kind) == ThreadStatus::Running)
        .then(|| thread.turns.last().map(|turn| turn.id.clone()))
        .flatten();

    ThreadDetailDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: format!("codex:{}", thread.id),
        native_thread_id: thread.id.clone(),
        provider: ProviderKind::Codex,
        client: map_thread_client_kind_from_source(thread.source.as_str().unwrap_or("unknown")),
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd.clone(),
        repository,
        branch,
        created_at: unix_timestamp_to_iso8601(thread.created_at),
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
        source: thread.source.as_str().unwrap_or("unknown").to_string(),
        access_mode: AccessMode::ControlWithApprovals,
        last_turn_summary: thread.preview.clone().unwrap_or_default(),
        active_turn_id,
    }
}

fn map_git_status(thread: &CodexThread) -> GitStatusDto {
    GitStatusDto {
        workspace: thread.cwd.clone(),
        repository: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.as_deref())
            .and_then(parse_repository_name_from_origin)
            .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
            .unwrap_or_else(|| "unknown-repository".to_string()),
        branch: thread
            .git_info
            .as_ref()
            .and_then(|git| git.branch.clone())
            .unwrap_or_else(|| "unknown".to_string()),
        remote: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.clone()),
        dirty: false,
        ahead_by: 0,
        behind_by: 0,
    }
}

fn map_thread_timeline_entries(thread: &CodexThread) -> Vec<ThreadTimelineEntryDto> {
    let mut entries = Vec::new();

    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
                continue;
            };
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&payload) {
                continue;
            }

            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));
            let event_id = format!("{}-{item_id}", turn.id);

            entries.push(ThreadTimelineEntryDto {
                event_id: event_id.clone(),
                kind,
                occurred_at: codex_item_occurred_at(item, &turn.id, thread.updated_at),
                summary: summarize_live_payload(kind, &payload),
                annotations: timeline_annotations_for_event(&event_id, kind, &payload),
                payload,
            });
        }
    }

    entries
}

fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
    let millis = if timestamp.abs() >= 1_000_000_000_000 {
        timestamp
    } else {
        timestamp.saturating_mul(1000)
    };

    Utc.timestamp_millis_opt(millis)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn map_thread_status(kind: &str) -> ThreadStatus {
    match kind {
        "idle" => ThreadStatus::Idle,
        "active" => ThreadStatus::Running,
        "systemError" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
}

fn parse_repository_name_from_origin(origin_url: &str) -> Option<String> {
    let trimmed = origin_url.trim().trim_end_matches('/');
    let repository = trimmed
        .rsplit(['/', ':'])
        .next()?
        .trim_end_matches(".git")
        .trim();
    (!repository.is_empty()).then(|| repository.to_string())
}

fn derive_repository_name_from_cwd(cwd: &str) -> Option<String> {
    cwd.rsplit('/')
        .find(|segment| !segment.trim().is_empty())
        .map(|segment| segment.trim().to_string())
}

fn codex_item_occurred_at(item: &Value, turn_id: &str, thread_updated_at: i64) -> String {
    codex_timestamp_from_item(item)
        .or_else(|| uuid_v7_timestamp_to_iso8601(turn_id))
        .unwrap_or_else(|| unix_timestamp_to_iso8601(thread_updated_at))
}

fn codex_timestamp_from_item(item: &Value) -> Option<String> {
    const KEYS: [&str; 8] = [
        "timestamp",
        "occurredAt",
        "updatedAt",
        "createdAt",
        "startedAt",
        "completedAt",
        "startTime",
        "endTime",
    ];

    KEYS.iter()
        .filter_map(|key| item.get(*key))
        .find_map(value_to_timestamp)
}

fn value_to_timestamp(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else if let Ok(parsed_numeric) = trimmed.parse::<i64>() {
                Some(unix_timestamp_to_iso8601(parsed_numeric))
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => number.as_i64().map(unix_timestamp_to_iso8601).or_else(|| {
            number
                .as_u64()
                .map(|value| unix_timestamp_to_iso8601(value as i64))
        }),
        _ => None,
    }
}

fn uuid_v7_timestamp_to_iso8601(value: &str) -> Option<String> {
    let compact = value.chars().filter(|ch| *ch != '-').collect::<String>();
    if compact.len() != 32 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }
    if compact
        .chars()
        .nth(12)
        .is_none_or(|version| !version.eq_ignore_ascii_case(&'7'))
    {
        return None;
    }

    let millis = i64::from_str_radix(&compact[0..12], 16).ok()?;
    Some(unix_timestamp_to_iso8601(millis))
}

fn normalize_codex_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let item_type = canonicalize_codex_item_type(item.get("type").and_then(Value::as_str)?);
    match item_type {
        "userMessage" => Some((
            BridgeEventKind::MessageDelta,
            normalize_message_item(item, "user"),
        )),
        "agentMessage" => Some((
            BridgeEventKind::MessageDelta,
            normalize_message_item(item, "assistant"),
        )),
        "plan" => Some((BridgeEventKind::PlanDelta, normalize_plan_item(item))),
        "commandExecution" => Some((BridgeEventKind::CommandDelta, normalize_command_item(item))),
        "fileChange" => Some((
            BridgeEventKind::FileChange,
            normalize_file_change_item(item),
        )),
        "functionCall" | "customToolCall" => normalize_codex_tool_invocation_item(item),
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

fn normalize_codex_tool_invocation_item(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let tool_name = item
        .get("name")
        .and_then(Value::as_str)
        .or_else(|| item.get("command").and_then(Value::as_str))
        .unwrap_or("command");
    if tool_name == "update_plan"
        && let Some(payload) = normalize_update_plan_tool_item(item)
    {
        return Some((BridgeEventKind::PlanDelta, payload));
    }
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
                object.insert("change".to_string(), Value::String(input_text));
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
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    ))
}

fn normalize_update_plan_tool_item(item: &Value) -> Option<Value> {
    let plan_input = parse_update_plan_input(
        item.get("input")
            .or_else(|| item.get("arguments"))
            .unwrap_or(&Value::Null),
    )?;
    let steps = normalize_update_plan_steps(&plan_input);
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
    let text =
        render_update_plan_text(explanation.as_deref(), &steps, completed_count, total_count);

    let mut payload = json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
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

fn parse_update_plan_input(input: &Value) -> Option<Value> {
    match input {
        Value::String(text) => serde_json::from_str::<Value>(text).ok(),
        Value::Object(_) => Some(input.clone()),
        _ => None,
    }
}

fn normalize_update_plan_steps(plan_input: &Value) -> Vec<Value> {
    plan_input
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
        .collect()
}

fn render_update_plan_text(
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
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    ))
}

fn normalize_message_item(item: &Value, role: &str) -> Value {
    let mut payload = serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "message",
        "role": role,
        "text": extract_message_text(item),
    });

    let images = extract_message_images(item);
    if !images.is_empty()
        && let Some(object) = payload.as_object_mut()
    {
        object.insert(
            "images".to_string(),
            Value::Array(images.into_iter().map(Value::String).collect()),
        );
    }

    payload
}

fn normalize_plan_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "plan",
        "text": item.get("text").and_then(Value::as_str).unwrap_or_default(),
    })
}

fn normalize_command_item(item: &Value) -> Value {
    let arguments = item
        .get("arguments")
        .cloned()
        .or_else(|| item.get("input").cloned())
        .unwrap_or(Value::Null);

    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "command",
        "command": item
            .get("command")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "arguments": arguments,
        "output": item
            .get("output")
            .or_else(|| item.get("aggregatedOutput"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "cmd": item.get("cmd").and_then(Value::as_str),
        "workdir": item.get("cwd").and_then(Value::as_str),
    })
}

fn normalize_file_change_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "file_change",
        "resolved_unified_diff": item
            .get("resolved_unified_diff")
            .or_else(|| item.get("output"))
            .or_else(|| item.get("change"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "path": extract_file_change_path(item),
    })
}

fn extract_message_text(item: &Value) -> String {
    if let Some(text) = item.get("text").and_then(Value::as_str) {
        return text.to_string();
    }

    item.get("content")
        .and_then(Value::as_array)
        .map(|content| {
            content
                .iter()
                .filter_map(|entry| entry.get("text").and_then(Value::as_str))
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn extract_message_images(item: &Value) -> Vec<String> {
    item.get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            entry
                .get("image_url")
                .or_else(|| entry.get("url"))
                .or_else(|| entry.get("path"))
                .and_then(Value::as_str)
        })
        .filter(|image| !image.trim().is_empty())
        .map(ToString::to_string)
        .collect()
}

fn extract_file_change_path(item: &Value) -> String {
    item.get("path")
        .or_else(|| item.get("file"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .or_else(|| {
            item.get("changes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find_map(|change| change.get("path").and_then(Value::as_str))
                .map(ToString::to_string)
        })
        .unwrap_or_default()
}

fn is_file_change_custom_tool(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "apply_patch" | "replace_file_content" | "multi_replace_file_content"
    ) || tool_name.contains("edit_file")
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

fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_archive_message)
        .unwrap_or(false)
}

fn payload_primary_text(payload: &Value) -> Option<&str> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed);
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
        .filter(|text| !text.is_empty())
}

fn is_hidden_archive_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("You are running in mobile plan intake mode.")
        || trimmed.starts_with("You are continuing a mobile planning workflow.")
        || trimmed.contains("<codex-plan-questions>")
}

fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::UserInputRequested => payload
            .get("title")
            .or_else(|| payload.get("detail"))
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

fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
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

#[cfg(test)]
mod tests {
    use super::{
        CodexGateway, CodexGitInfo, CodexThread, CodexThreadStatus, CodexTurn, TurnStartRequest,
        build_claude_input_message, build_claude_message_content, build_turn_start_input,
        claude_project_slug, claude_session_archive_path, derive_repository_name_from_cwd,
        extract_generated_thread_title, fetch_thread_summaries_from_archive, map_thread_snapshot,
        map_thread_summary, normalize_codex_item_payload, normalize_generated_thread_title,
        parse_data_url_image, parse_model_options, parse_repository_name_from_origin,
        prefer_archive_timeline_when_rpc_lacks_tool_events, summarize_claude_stderr,
    };
    use crate::codex_runtime::CodexRuntimeMode;
    use crate::server::config::BridgeCodexConfig;
    use serde_json::{Value, json};
    use shared_contracts::{BridgeEventKind, ProviderKind, ThreadTimelineEntryDto};
    use std::fs;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    #[test]
    fn parses_repository_name_from_origin_url() {
        assert_eq!(
            parse_repository_name_from_origin("git@github.com:openai/codex.git"),
            Some("codex".to_string())
        );
    }

    #[test]
    fn derives_repository_name_from_workspace_path() {
        assert_eq!(
            derive_repository_name_from_cwd("/Users/test/project"),
            Some("project".to_string())
        );
    }

    #[test]
    fn function_call_command_payload_preserves_arguments_for_mobile_formatting() {
        let item = json!({
            "id": "tool-1",
            "type": "functionCall",
            "name": "exec_command",
            "arguments": "{\"cmd\":\"flutter analyze\"}",
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("function call should normalize");
        assert_eq!(kind, BridgeEventKind::CommandDelta);
        assert_eq!(payload["command"], "exec_command");
        assert_eq!(payload["arguments"], "{\"cmd\":\"flutter analyze\"}");
    }

    #[test]
    fn update_plan_function_call_normalizes_to_plan_delta() {
        let item = json!({
            "id": "tool-2",
            "type": "functionCall",
            "name": "update_plan",
            "arguments": "{\"plan\":[{\"step\":\"Inspect bridge payload\",\"status\":\"completed\"},{\"step\":\"Add Flutter card\",\"status\":\"in_progress\"}]}"
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("update_plan should normalize");
        assert_eq!(kind, BridgeEventKind::PlanDelta);
        assert_eq!(payload["type"], "plan");
        assert_eq!(payload["completed_count"], 1);
        assert_eq!(payload["total_count"], 2);
        assert_eq!(
            payload["text"].as_str(),
            Some("1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card")
        );
    }

    #[test]
    fn summarize_claude_stderr_prefers_human_readable_error_lines() {
        let stderr =
            "Error: Session ID 123 is already in use.\n    at main (file:///tmp/cli.js:1:1)";
        assert_eq!(
            summarize_claude_stderr(stderr).as_deref(),
            Some("Error: Session ID 123 is already in use.")
        );
    }

    #[test]
    fn summarize_claude_stderr_hides_minified_stack_noise() {
        let stderr = "file:///Users/test/node_modules/@anthropic-ai/claude-code/cli.js:489\n`)},Q.code=Z.error.code,Q.errors=Z.error.errors;else Q.message=Z.error.message;";
        assert_eq!(
            summarize_claude_stderr(stderr).as_deref(),
            Some("Claude CLI crashed before it returned a usable error message.")
        );
    }

    #[test]
    fn claude_project_slug_normalizes_workspace_path() {
        assert_eq!(
            claude_project_slug("/Users/test/Library/Application Support/CodexBar/ClaudeProbe"),
            "-Users-test-Library-Application-Support-CodexBar-ClaudeProbe"
        );
    }

    #[test]
    fn claude_session_archive_path_uses_claude_home_override() {
        let _env_lock = crate::test_support::lock_test_env();
        let claude_home =
            std::env::temp_dir().join(format!("gateway-claude-session-{}", std::process::id()));
        let previous_claude_home = std::env::var_os("CLAUDE_HOME");

        unsafe {
            std::env::set_var("CLAUDE_HOME", &claude_home);
        }

        let session_path = claude_session_archive_path(
            "/Users/test/Library/Application Support/CodexBar/ClaudeProbe",
            "session-123",
        )
        .expect("Claude session path should resolve");

        assert_eq!(
            session_path,
            claude_home
                .join("projects")
                .join("-Users-test-Library-Application-Support-CodexBar-ClaudeProbe")
                .join("session-123.jsonl")
        );

        unsafe {
            if let Some(previous_claude_home) = previous_claude_home {
                std::env::set_var("CLAUDE_HOME", previous_claude_home);
            } else {
                std::env::remove_var("CLAUDE_HOME");
            }
        }
    }

    #[test]
    fn turn_start_input_includes_text_and_image_parts() {
        let input = build_turn_start_input(
            "Describe this image",
            &["data:image/png;base64,AAA".to_string()],
        );

        assert_eq!(
            input,
            json!([
                {
                    "type": "text",
                    "text": "Describe this image",
                    "text_elements": [],
                },
                {
                    "type": "image",
                    "url": "data:image/png;base64,AAA",
                }
            ])
        );
    }

    #[test]
    fn parse_data_url_image_decodes_png_payload() {
        let parsed = parse_data_url_image("data:image/png;base64,QUJD")
            .expect("data URL image should decode");

        assert_eq!(parsed.mime_type, "image/png");
        assert_eq!(parsed.base64_data, "QUJD");
    }

    #[test]
    fn build_claude_message_content_emits_native_image_blocks() {
        let content = build_claude_message_content(
            "Describe the screenshot",
            &["data:image/png;base64,QUJD".to_string()],
        )
        .expect("Claude turn content should prepare");

        assert_eq!(
            content,
            json!([
                {
                    "type": "text",
                    "text": "Describe the screenshot",
                },
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": "QUJD",
                    },
                }
            ])
        );
    }

    #[test]
    fn build_claude_input_message_emits_sdk_user_message_ndjson() {
        let line = build_claude_input_message(
            "Describe the screenshot",
            &["data:image/png;base64,QUJD".to_string()],
        )
        .expect("Claude turn input line should encode");

        let decoded: Value = serde_json::from_str(line.trim()).expect("line should decode");
        assert_eq!(decoded["type"], "user");
        assert_eq!(decoded["message"]["role"], "user");
        assert_eq!(
            decoded["message"]["content"][1]["source"]["media_type"],
            "image/png"
        );
        assert_eq!(decoded["message"]["content"][1]["source"]["data"], "QUJD");
    }

    #[test]
    fn normalize_message_item_preserves_image_urls_from_codex_content() {
        let item = json!({
            "id": "msg-1",
            "type": "userMessage",
            "content": [
                {
                    "type": "text",
                    "text": "Screenshot attached",
                },
                {
                    "type": "image",
                    "url": "data:image/png;base64,AAA",
                }
            ],
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("message should normalize");
        assert_eq!(kind, BridgeEventKind::MessageDelta);
        assert_eq!(payload["role"], "user");
        assert_eq!(payload["images"], json!(["data:image/png;base64,AAA"]));
    }

    #[test]
    fn map_thread_snapshot_surfaces_pending_plan_questions_without_protocol_messages() {
        let snapshot = map_thread_snapshot(CodexThread {
            id: "thread-plan".to_string(),
            name: Some("Plan mode".to_string()),
            preview: Some("preview".to_string()),
            status: CodexThreadStatus {
                kind: "idle".to_string(),
            },
            cwd: "/workspace/repo".to_string(),
            path: None,
            git_info: Some(CodexGitInfo {
                branch: Some("main".to_string()),
                origin_url: Some("git@github.com:example/repo.git".to_string()),
            }),
            created_at: 1_710_000_000,
            updated_at: 1_710_000_300,
            source: Value::String("cli".to_string()),
            turns: vec![CodexTurn {
                id: "turn-plan".to_string(),
                items: vec![
                    json!({
                        "id": "msg-hidden-user",
                        "type": "userMessage",
                        "text": "You are running in mobile plan intake mode.\nReturn only one XML-like block.",
                    }),
                    json!({
                        "id": "msg-hidden-assistant",
                        "type": "agentMessage",
                        "text": "<codex-plan-questions>{\"title\":\"Clarify the implementation\",\"detail\":\"Pick a focus.\",\"questions\":[{\"question_id\":\"scope\",\"prompt\":\"What should the test cover first?\",\"options\":[{\"option_id\":\"core\",\"label\":\"Core flows\",\"description\":\"Focus on pairing and thread navigation.\",\"is_recommended\":true},{\"option_id\":\"plan\",\"label\":\"Plan mode\",\"description\":\"Focus on plan mode only.\",\"is_recommended\":false},{\"option_id\":\"polish\",\"label\":\"UI polish\",\"description\":\"Focus on layout and copy.\",\"is_recommended\":false}]}]}</codex-plan-questions>",
                    }),
                ],
            }],
        });

        assert!(snapshot.entries.is_empty());
        let pending_user_input = snapshot
            .pending_user_input
            .expect("pending user input should be reconstructed");
        assert_eq!(pending_user_input.title, "Clarify the implementation");
        assert_eq!(pending_user_input.questions.len(), 1);
        assert_eq!(pending_user_input.questions[0].question_id, "scope");
    }

    #[test]
    fn parses_model_catalog_from_codex_response() {
        let models = parse_model_options(json!({
            "data": [
                {
                    "id": "gpt-5.4",
                    "model": "gpt-5.4",
                    "displayName": "GPT-5.4",
                    "description": "Best reasoning",
                    "isDefault": true,
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        {"reasoningEffort": "medium"},
                        {"reasoningEffort": "high"}
                    ]
                }
            ]
        }));

        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "gpt-5.4");
        assert_eq!(models[0].display_name, "GPT-5.4");
        assert!(models[0].is_default);
        assert_eq!(models[0].default_reasoning_effort.as_deref(), Some("high"));
        assert_eq!(models[0].supported_reasoning_efforts.len(), 2);
    }

    #[test]
    fn generated_thread_title_is_normalized() {
        assert_eq!(
            normalize_generated_thread_title("  \"Fix stale thread state.\"  "),
            Some("Fix stale thread state".to_string())
        );
        assert_eq!(normalize_generated_thread_title("Untitled thread"), None);
    }

    #[test]
    fn generated_thread_title_prefers_structured_json_field() {
        assert_eq!(
            extract_generated_thread_title(Some(r#"{"title":"Add todo list to Flutter app"}"#)),
            Some("Add todo list to Flutter app".to_string())
        );
    }

    #[test]
    fn thread_summary_ignores_preview_when_name_is_missing() {
        let summary = map_thread_summary(CodexThread {
            id: "thread-1".to_string(),
            name: None,
            preview: Some("This should stay a preview".to_string()),
            status: super::CodexThreadStatus {
                kind: "idle".to_string(),
            },
            cwd: "/Users/test/project".to_string(),
            path: None,
            git_info: Some(super::CodexGitInfo {
                branch: Some("main".to_string()),
                origin_url: Some("git@github.com:openai/codex-mobile-companion.git".to_string()),
            }),
            created_at: 0,
            updated_at: 0,
            source: json!("cli"),
            turns: Vec::new(),
        });

        assert_eq!(summary.title, "Untitled thread");
    }

    #[test]
    fn archive_timeline_is_preferred_when_rpc_has_only_messages() {
        let rpc_entries = vec![ThreadTimelineEntryDto {
            event_id: "evt-msg".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
            summary: "assistant message".to_string(),
            payload: json!({"text":"assistant message"}),
            annotations: None,
        }];

        let archive_entries = vec![
            ThreadTimelineEntryDto {
                event_id: "evt-msg-archive".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
                summary: "assistant message".to_string(),
                payload: json!({"text":"assistant message"}),
                annotations: None,
            },
            ThreadTimelineEntryDto {
                event_id: "evt-cmd".to_string(),
                kind: BridgeEventKind::CommandDelta,
                occurred_at: "2026-03-21T10:00:01.000Z".to_string(),
                summary: "Called exec_command".to_string(),
                payload: json!({"command":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}),
                annotations: None,
            },
        ];

        let selected =
            prefer_archive_timeline_when_rpc_lacks_tool_events(rpc_entries, archive_entries);

        assert_eq!(selected.len(), 2);
        assert_eq!(selected[1].kind, BridgeEventKind::CommandDelta);
    }

    #[test]
    fn archive_fallback_surfaces_threads_when_live_list_is_empty() {
        let _env_lock = crate::test_support::lock_test_env();
        let codex_home =
            std::env::temp_dir().join(format!("gateway-archive-fallback-{}", std::process::id()));
        let claude_home = std::env::temp_dir().join(format!(
            "gateway-claude-archive-fallback-{}",
            std::process::id()
        ));
        let sessions_directory = codex_home.join("sessions/2026/03/23");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::create_dir_all(&claude_home).expect("test Claude home directory should exist");
        fs::write(
            sessions_directory.join("rollout-2026-03-23T18-04-18-thread-archive-no-index.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-23T18:04:20.876Z","type":"session_meta","payload":{"id":"thread-archive-no-index","timestamp":"2026-03-23T18:04:18.254Z","cwd":"/home/lubo/codex-mobile-companion/apps/linux-shell","source":"cli","git":{"branch":"main","repository_url":"git@github.com:openai/codex-mobile-companion.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-23T18:04:21.018Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let previous_codex_home = std::env::var_os("CODEX_HOME");
        let previous_claude_home = std::env::var_os("CLAUDE_HOME");
        unsafe {
            std::env::set_var("CODEX_HOME", &codex_home);
            std::env::set_var("CLAUDE_HOME", &claude_home);
        }

        let summaries = fetch_thread_summaries_from_archive(&BridgeCodexConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: None,
            command: "definitely-missing-codex".to_string(),
            args: vec!["app-server".to_string()],
            desktop_ipc_socket_path: None,
        })
        .expect("archive fallback should load thread summaries");

        unsafe {
            if let Some(previous_codex_home) = previous_codex_home {
                std::env::set_var("CODEX_HOME", previous_codex_home);
            } else {
                std::env::remove_var("CODEX_HOME");
            }
            if let Some(previous_claude_home) = previous_claude_home {
                std::env::set_var("CLAUDE_HOME", previous_claude_home);
            } else {
                std::env::remove_var("CLAUDE_HOME");
            }
        }
        let _ = fs::remove_dir_all(&codex_home);
        let _ = fs::remove_dir_all(&claude_home);

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].thread_id, "codex:thread-archive-no-index");
        assert_eq!(summaries[0].repository, "codex-mobile-companion");
    }

    #[test]
    #[ignore = "requires a live local Codex app-server"]
    fn live_create_thread_and_stream_turn_response() {
        let runtime = tokio::runtime::Runtime::new().expect("runtime should build");
        runtime.block_on(async {
            let workspace = std::env::var("CODEX_LIVE_TEST_WORKSPACE")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| {
                    std::env::current_dir()
                        .expect("cwd should resolve")
                        .display()
                        .to_string()
                });
            let codex_bin = std::env::var("CODEX_LIVE_TEST_CODEX_BIN")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "codex".to_string());

            let gateway = CodexGateway::new(BridgeCodexConfig {
                mode: CodexRuntimeMode::Spawn,
                endpoint: None,
                command: codex_bin,
                args: vec!["app-server".to_string()],
                desktop_ipc_socket_path: None,
            });

            let create_started_at = Instant::now();
            let snapshot = tokio::time::timeout(
                Duration::from_secs(10),
                gateway.create_thread(ProviderKind::Codex, &workspace, None),
            )
            .await
            .expect("create_thread should not hang")
            .expect("create_thread should succeed");
            assert!(
                !snapshot.thread.thread_id.trim().is_empty(),
                "create_thread returned an empty thread id"
            );
            assert_eq!(snapshot.thread.workspace, workspace);
            eprintln!(
                "LIVE_GATEWAY_CREATE thread_id={} create_ms={}",
                snapshot.thread.thread_id,
                create_started_at.elapsed().as_millis()
            );

            let token = format!("LIVE_GATEWAY_TOKEN_{}", snapshot.thread.thread_id);
            let prompt = format!("Reply with exactly {token}");
            let (event_tx, event_rx) = mpsc::channel();
            gateway
                .start_turn_streaming(
                    &snapshot.thread.thread_id,
                    TurnStartRequest {
                        prompt: prompt.clone(),
                        images: Vec::new(),
                        model: None,
                        effort: None,
                        permission_mode: None,
                    },
                    move |event| {
                        let _ = event_tx.send(event);
                    },
                    |_| Ok(None),
                    |_| {},
                    |_| {},
                )
                .expect("turn should start");

            let wait_deadline = Instant::now() + Duration::from_secs(60);
            let mut saw_token = false;
            while Instant::now() < wait_deadline {
                let Ok(event) = event_rx.recv_timeout(Duration::from_secs(5)) else {
                    continue;
                };
                if event.kind != BridgeEventKind::MessageDelta {
                    continue;
                }

                let payload_text =
                    serde_json::to_string(&event.payload).expect("payload should serialize");
                if payload_text.contains(&token) {
                    saw_token = true;
                    break;
                }
            }

            assert!(
                saw_token,
                "did not observe assistant stream payload containing {token}"
            );
        });
    }
}
