mod claude;
mod codex;
mod legacy_archive;
pub(crate) mod mapping;
#[cfg(test)]
mod tests;

use base64::Engine;
use chrono::{SecondsFormat, TimeZone, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
    GitStatusDto, ModelOptionDto, PendingUserInputDto, ProviderKind, ReasoningEffortOptionDto,
    ThreadDetailDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto, TurnMode, TurnMutationAcceptedDto,
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
use crate::thread_identity::{
    is_provider_thread_id, native_thread_id_for_provider, provider_thread_id,
};

#[derive(Debug, Clone)]
pub struct CodexGateway {
    config: BridgeCodexConfig,
    codex_thread_actors: Arc<codex::actor::CodexThreadActors>,
    claude_thread_workspaces: Arc<Mutex<HashMap<String, String>>>,
    active_claude_processes: Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    interrupted_claude_threads: Arc<Mutex<HashSet<String>>>,
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

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GatewayThreadLifecycleState {
    pub active_turn_id: Option<String>,
    pub stream_active: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GatewayTurnStreamActivity {
    pub saw_user_message: bool,
    pub saw_assistant_message: bool,
    pub saw_workflow_event: bool,
    pub saw_turn_completed: bool,
}

impl GatewayTurnStreamActivity {
    pub fn requires_completion_snapshot_refresh(&self) -> bool {
        !(self.saw_user_message && (self.saw_assistant_message || self.saw_workflow_event))
    }
}

#[derive(Debug, Clone)]
pub struct TurnStartRequest {
    pub request_id: Option<String>,
    pub prompt: String,
    pub images: Vec<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: TurnMode,
    pub permission_mode: Option<String>,
    pub client_turn_intent_id: Option<String>,
}

#[derive(Debug, Clone)]
pub enum GatewayTurnControlRequest {
    CodexApproval {
        request_id: Value,
        method: String,
        params: Value,
    },
    CodexRequestUserInput {
        request_id: Value,
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
pub(crate) struct CodexThread {
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
    const THREAD_TITLE_MAX_CHARS: usize = 80;

    pub fn new(config: BridgeCodexConfig) -> Self {
        Self {
            config,
            codex_thread_actors: Arc::new(codex::actor::CodexThreadActors::default()),
            claude_thread_workspaces: Arc::new(Mutex::new(HashMap::new())),
            active_claude_processes: Arc::new(Mutex::new(HashMap::new())),
            interrupted_claude_threads: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub fn model_catalog(&self, provider: ProviderKind) -> Vec<ModelOptionDto> {
        match provider {
            ProviderKind::Codex => codex::fallback_model_options(),
            ProviderKind::ClaudeCode => claude::fallback_claude_model_options(),
        }
    }

    pub fn desktop_ipc_socket_path(&self) -> Option<PathBuf> {
        self.config.desktop_ipc_socket_path.clone()
    }

    pub fn ensure_notification_stream<F, G>(
        &self,
        thread_id: &str,
        on_event: F,
        on_stale_rollout: G,
    ) -> Result<(), String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + Sync + 'static,
        G: Fn(String) + Send + Sync + 'static,
    {
        if !is_provider_thread_id(thread_id, ProviderKind::Codex) {
            return Ok(());
        }

        let config = self.config.clone();
        let actor = self.codex_thread_actors.actor(thread_id, &config);
        actor.ensure_notification_stream(Arc::new(on_event), Arc::new(on_stale_rollout))
    }
}
