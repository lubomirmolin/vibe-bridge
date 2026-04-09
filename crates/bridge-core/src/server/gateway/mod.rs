mod claude;
mod codex;
mod mapping;
mod models;

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

use self::models::{fallback_claude_model_options, fallback_model_options};

#[cfg(test)]
use self::claude::{
    build_claude_input_message, build_claude_message_content, claude_project_slug,
    claude_session_archive_path, parse_data_url_image, summarize_claude_stderr,
};
#[cfg(test)]
use self::codex::{
    build_turn_start_input, extract_generated_thread_title, fetch_thread_summaries_from_archive,
    normalize_generated_thread_title,
};
#[cfg(test)]
use self::mapping::{
    derive_repository_name_from_cwd, map_thread_snapshot, map_thread_summary,
    normalize_codex_item_payload, parse_repository_name_from_origin,
    prefer_archive_timeline_when_rpc_lacks_tool_events,
};
#[cfg(test)]
use self::models::parse_model_options;

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

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        match provider {
            ProviderKind::Codex => self.create_codex_thread(workspace, model).await,
            ProviderKind::ClaudeCode => self.create_claude_thread(workspace).await,
        }
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
            self.start_claude_turn_streaming(
                thread_id,
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
            )
        } else {
            self.start_codex_turn_streaming(
                thread_id,
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
            )
        }
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<GatewayTurnMutation, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            self.interrupt_claude_turn(thread_id)
        } else {
            self.interrupt_codex_turn(thread_id, turn_id).await
        }
    }

    pub async fn resolve_active_turn_id(&self, thread_id: &str) -> Result<String, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            self.resolve_active_claude_turn_id(thread_id)
        } else {
            self.resolve_codex_active_turn_id(thread_id).await
        }
    }
}

fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

fn should_read_without_turns(error: &str) -> bool {
    error.contains("includeTurns is unavailable before first user message")
        || error.contains("is not materialized yet")
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
    fn web_search_item_normalizes_to_command_delta() {
        let item = json!({
            "id": "web-1",
            "type": "webSearch",
            "action": {
                "type": "search",
                "query": "GitHub R2Explorer README",
                "queries": ["GitHub R2Explorer README"]
            }
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("web search should normalize");
        assert_eq!(kind, BridgeEventKind::CommandDelta);
        assert_eq!(payload["command"], "web_search");
        assert_eq!(payload["action"], "search");
        assert_eq!(payload["output"], "search: GitHub R2Explorer README");
    }

    #[test]
    fn custom_tool_output_preserves_apply_patch_command() {
        let item = json!({
            "id": "tool-3",
            "type": "customToolCallOutput",
            "name": "apply_patch",
            "output": "{\"output\":\"Success. Updated the following files:\\nM lib/main.dart\\n\",\"metadata\":{\"exit_code\":0}}"
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("custom tool output should normalize");
        assert_eq!(kind, BridgeEventKind::FileChange);
        assert_eq!(payload["command"], "apply_patch");
        assert_eq!(
            payload["resolved_unified_diff"],
            "Success. Updated the following files:\nM lib/main.dart\n"
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
