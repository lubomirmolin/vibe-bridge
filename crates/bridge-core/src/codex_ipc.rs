use std::collections::{HashMap, VecDeque};
use std::env;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadSnapshotDto,
    ThreadStatus, ThreadTimelineEntryDto,
};

use crate::server::gateway::mapping::{
    derive_repository_name_from_cwd, map_thread_client_kind_from_source,
    normalize_codex_item_payload, should_publish_live_payload,
};
use crate::server::timeline_events::{
    build_timeline_event_envelope, current_timestamp_string, summarize_live_payload,
    unix_timestamp_to_iso8601,
};

const IPC_FRAME_MAX_BYTES: u32 = 256 * 1024 * 1024;
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopIpcConfig {
    pub socket_path: PathBuf,
}

impl DesktopIpcConfig {
    pub fn detect(override_path: Option<PathBuf>) -> Option<Self> {
        override_path
            .or_else(detect_default_socket_path)
            .map(|socket_path| Self { socket_path })
    }
}

#[derive(Debug)]
pub struct DesktopIpcClient {
    stream: UnixStream,
    client_id: String,
    pending_broadcasts: VecDeque<DesktopIpcBroadcast>,
}

enum DesktopIpcFrameRead {
    Timeout,
    Payload(Vec<u8>),
    Closed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum DesktopIpcEnvelope {
    Request(DesktopIpcRequest),
    Response(DesktopIpcResponse),
    Broadcast(DesktopIpcBroadcast),
    ClientDiscoveryRequest(Value),
    ClientDiscoveryResponse(Value),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopIpcRequest {
    request_id: String,
    source_client_id: String,
    version: u32,
    method: String,
    params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "resultType", rename_all = "kebab-case")]
enum DesktopIpcResponse {
    #[serde(rename_all = "camelCase")]
    Success {
        request_id: String,
        method: String,
        handled_by_client_id: String,
        result: Value,
    },
    #[serde(rename_all = "camelCase")]
    Error { request_id: String, error: String },
}

impl DesktopIpcResponse {
    fn request_id(&self) -> &str {
        match self {
            Self::Success { request_id, .. } | Self::Error { request_id, .. } => request_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopIpcBroadcast {
    pub method: String,
    pub source_client_id: String,
    pub version: u32,
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DesktopThreadStreamStateChangedParams {
    pub conversation_id: String,
    pub change: DesktopStreamChange,
    pub version: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DesktopStreamChange {
    Snapshot {
        #[serde(rename = "conversationState")]
        conversation_state: Value,
    },
    Patches {
        patches: Vec<DesktopImmerPatch>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DesktopImmerPatch {
    pub op: DesktopImmerOp,
    pub path: Vec<DesktopImmerPathSegment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DesktopImmerOp {
    Add,
    Remove,
    Replace,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum DesktopImmerPathSegment {
    Index(usize),
    Key(String),
}

impl DesktopIpcClient {
    pub fn connect(config: &DesktopIpcConfig) -> Result<Self, String> {
        let stream = UnixStream::connect(&config.socket_path).map_err(|error| {
            format!(
                "failed to connect desktop IPC socket {}: {error}",
                config.socket_path.display()
            )
        })?;
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .map_err(|error| format!("failed to configure desktop IPC read timeout: {error}"))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|error| format!("failed to configure desktop IPC write timeout: {error}"))?;

        let mut client = Self {
            stream,
            client_id: "initializing-client".to_string(),
            pending_broadcasts: VecDeque::new(),
        };
        client.initialize()?;
        Ok(client)
    }

    pub fn next_thread_stream_state_changed(
        &mut self,
    ) -> Result<Option<DesktopThreadStreamStateChangedParams>, String> {
        loop {
            let Some(broadcast) = self.next_broadcast()? else {
                return Ok(None);
            };
            if broadcast.method != "thread-stream-state-changed" {
                continue;
            }
            return serde_json::from_value::<DesktopThreadStreamStateChangedParams>(
                broadcast.params,
            )
            .map(Some)
            .map_err(|error| {
                format!("failed to decode desktop IPC thread-stream-state-changed: {error}")
            });
        }
    }

    pub fn external_resume_thread(&mut self, thread_id: &str) -> Result<(), String> {
        self.send_request(
            "external-resume-thread",
            1,
            json!({
                "conversationId": thread_id,
            }),
        )
        .map(|_| ())
    }

    fn initialize(&mut self) -> Result<(), String> {
        let response = self.send_request("initialize", 1, json!({ "clientType": "mobile" }))?;
        let client_id = response
            .get("clientId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "desktop IPC initialize response did not include clientId".to_string())?
            .to_string();
        self.client_id = client_id;
        Ok(())
    }

    fn send_request(&mut self, method: &str, version: u32, params: Value) -> Result<Value, String> {
        let request_id = format!(
            "bridge-ipc-{}",
            NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        );
        let request = DesktopIpcEnvelope::Request(DesktopIpcRequest {
            request_id: request_id.clone(),
            source_client_id: self.client_id.clone(),
            version,
            method: method.to_string(),
            params,
        });
        self.write_frame(&request)?;

        loop {
            let Some(envelope) = self.read_envelope()? else {
                continue;
            };
            match envelope {
                DesktopIpcEnvelope::Response(response) if response.request_id() == request_id => {
                    return match response {
                        DesktopIpcResponse::Success {
                            method: response_method,
                            result,
                            handled_by_client_id,
                            ..
                        } => {
                            let _ = (response_method, handled_by_client_id);
                            Ok(result)
                        }
                        DesktopIpcResponse::Error { error, .. } => {
                            Err(format!("desktop IPC {method} failed: {error}"))
                        }
                    };
                }
                DesktopIpcEnvelope::Broadcast(broadcast) => {
                    self.pending_broadcasts.push_back(broadcast);
                }
                DesktopIpcEnvelope::Request(_)
                | DesktopIpcEnvelope::ClientDiscoveryRequest(_)
                | DesktopIpcEnvelope::ClientDiscoveryResponse(_)
                | DesktopIpcEnvelope::Response(_) => {}
            }
        }
    }

    fn next_broadcast(&mut self) -> Result<Option<DesktopIpcBroadcast>, String> {
        if let Some(broadcast) = self.pending_broadcasts.pop_front() {
            return Ok(Some(broadcast));
        }

        loop {
            let Some(envelope) = self.read_envelope()? else {
                return Ok(None);
            };
            match envelope {
                DesktopIpcEnvelope::Broadcast(broadcast) => return Ok(Some(broadcast)),
                DesktopIpcEnvelope::Request(request) => {
                    let _ = request;
                }
                DesktopIpcEnvelope::Response(_)
                | DesktopIpcEnvelope::ClientDiscoveryRequest(_)
                | DesktopIpcEnvelope::ClientDiscoveryResponse(_) => {}
            }
        }
    }

    fn write_frame(&mut self, envelope: &DesktopIpcEnvelope) -> Result<(), String> {
        let payload = serde_json::to_vec(envelope)
            .map_err(|error| format!("failed to serialize desktop IPC frame: {error}"))?;
        let length = u32::try_from(payload.len())
            .map_err(|_| "desktop IPC frame is larger than 4 GiB".to_string())?;
        self.stream
            .write_all(&length.to_le_bytes())
            .and_then(|_| self.stream.write_all(&payload))
            .and_then(|_| self.stream.flush())
            .map_err(|error| format!("failed to write desktop IPC frame: {error}"))
    }

    fn read_envelope(&mut self) -> Result<Option<DesktopIpcEnvelope>, String> {
        let frame = match self.read_frame()? {
            DesktopIpcFrameRead::Timeout => return Ok(None),
            DesktopIpcFrameRead::Closed => {
                return Err("desktop IPC connection closed".to_string());
            }
            DesktopIpcFrameRead::Payload(frame) => frame,
        };
        serde_json::from_slice::<DesktopIpcEnvelope>(&frame)
            .map(Some)
            .map_err(|error| format!("failed to decode desktop IPC frame: {error}"))
    }

    fn read_frame(&mut self) -> Result<DesktopIpcFrameRead, String> {
        let mut len_buf = [0_u8; 4];
        match self.stream.read_exact(&mut len_buf) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                ) =>
            {
                return Ok(DesktopIpcFrameRead::Timeout);
            }
            Err(error) if error.kind() == ErrorKind::UnexpectedEof => {
                return Ok(DesktopIpcFrameRead::Closed);
            }
            Err(error) => return Err(format!("failed to read desktop IPC frame header: {error}")),
        }

        let length = u32::from_le_bytes(len_buf);
        if length == 0 {
            return Ok(DesktopIpcFrameRead::Payload(Vec::new()));
        }
        if length > IPC_FRAME_MAX_BYTES {
            return Err(format!(
                "desktop IPC frame exceeded size limit: {length} > {IPC_FRAME_MAX_BYTES}"
            ));
        }

        let mut payload = vec![0_u8; length as usize];
        self.stream
            .read_exact(&mut payload)
            .map_err(|error| format!("failed to read desktop IPC frame body: {error}"))?;
        Ok(DesktopIpcFrameRead::Payload(payload))
    }
}

pub fn detect_default_socket_path() -> Option<PathBuf> {
    let uid = env::var("UID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            Command::new("id")
                .arg("-u")
                .output()
                .ok()
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })?;
    Some(
        env::temp_dir()
            .join("codex-ipc")
            .join(format!("ipc-{uid}.sock")),
    )
}

pub fn apply_patches(target: &mut Value, patches: &[DesktopImmerPatch]) -> Result<(), String> {
    for patch in patches {
        apply_patch(target, patch)?;
    }
    Ok(())
}

pub fn snapshot_from_conversation_state(
    conversation_state: &Value,
    previous_snapshot: Option<&ThreadSnapshotDto>,
    access_mode: AccessMode,
) -> Result<ThreadSnapshotDto, String> {
    let native_thread_id = conversation_state
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "desktop IPC conversation state did not include id".to_string())?
        .to_string();
    let thread_id = format!("codex:{native_thread_id}");
    let turns = conversation_state
        .get("turns")
        .and_then(Value::as_array)
        .ok_or_else(|| format!("desktop IPC conversation {thread_id} did not include turns"))?;

    let workspace = previous_snapshot
        .map(|snapshot| snapshot.thread.workspace.clone())
        .filter(|value| !value.trim().is_empty())
        .or_else(|| first_turn_workspace(turns))
        .unwrap_or_default();
    let entries = map_conversation_entries(&thread_id, turns)?;
    let created_at = previous_snapshot
        .map(|snapshot| snapshot.thread.created_at.clone())
        .filter(|value| !value.trim().is_empty())
        .or_else(|| first_turn_timestamp(turns))
        .unwrap_or_else(current_timestamp_string);
    let updated_at = latest_entry_timestamp(&entries)
        .or_else(|| latest_turn_timestamp(turns))
        .or_else(|| {
            previous_snapshot
                .map(|snapshot| snapshot.thread.updated_at.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or_else(current_timestamp_string);
    let repository = previous_snapshot
        .map(|snapshot| snapshot.thread.repository.clone())
        .filter(|value| !value.trim().is_empty())
        .or_else(|| derive_repository_name_from_cwd(&workspace))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = previous_snapshot
        .map(|snapshot| snapshot.thread.branch.clone())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let source = previous_snapshot
        .map(|snapshot| snapshot.thread.source.clone())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "codex_app_ipc".to_string());
    let title = previous_snapshot
        .map(|snapshot| snapshot.thread.title.clone())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Untitled thread".to_string());
    let status = turns
        .last()
        .and_then(turn_status)
        .unwrap_or(ThreadStatus::Idle);
    let last_turn_summary = entries
        .iter()
        .rev()
        .find_map(|entry| {
            let trimmed = entry.summary.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        })
        .or_else(|| {
            previous_snapshot
                .map(|snapshot| snapshot.thread.last_turn_summary.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or_default();

    Ok(ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: shared_contracts::ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id,
            native_thread_id: native_thread_id.clone(),
            provider: shared_contracts::ProviderKind::Codex,
            client: map_thread_client_kind_from_source(&source),
            title,
            status,
            workspace,
            repository,
            branch,
            created_at,
            updated_at,
            source,
            access_mode,
            last_turn_summary,
            active_turn_id: None,
        },
        latest_bridge_seq: previous_snapshot.and_then(|snapshot| snapshot.latest_bridge_seq),
        entries,
        approvals: previous_snapshot
            .map(|snapshot| snapshot.approvals.clone())
            .unwrap_or_default(),
        git_status: previous_snapshot.and_then(|snapshot| snapshot.git_status.clone()),
        workflow_state: previous_snapshot.and_then(|snapshot| snapshot.workflow_state.clone()),
        pending_user_input: None,
    })
}

pub fn diff_thread_snapshots(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &ThreadSnapshotDto,
) -> Vec<BridgeEventEnvelope<Value>> {
    let previous_entries = previous_snapshot
        .map(|snapshot| {
            snapshot
                .entries
                .iter()
                .cloned()
                .map(|entry| (entry.event_id.clone(), entry))
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default();

    let mut events = Vec::new();
    for entry in &next_snapshot.entries {
        if previous_entries.get(&entry.event_id) == Some(entry) {
            continue;
        }
        events.push(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: entry.event_id.clone(),
            bridge_seq: None,
            thread_id: next_snapshot.thread.thread_id.clone(),
            kind: entry.kind,
            occurred_at: entry.occurred_at.clone(),
            payload: entry.payload.clone(),
            annotations: entry.annotations.clone(),
        });
    }

    let previous_status = previous_snapshot.map(|snapshot| snapshot.thread.status);
    if previous_status != Some(next_snapshot.thread.status) {
        events.push(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!(
                "{}-desktop-status-{}",
                next_snapshot.thread.thread_id, next_snapshot.thread.updated_at
            ),
            bridge_seq: None,
            thread_id: next_snapshot.thread.thread_id.clone(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: next_snapshot.thread.updated_at.clone(),
            payload: json!({
                "status": thread_status_wire_value(next_snapshot.thread.status),
                "reason": "desktop_ipc",
            }),
            annotations: None,
        });
    }

    events
}

fn apply_patch(target: &mut Value, patch: &DesktopImmerPatch) -> Result<(), String> {
    if patch.path.is_empty() {
        return match patch.op {
            DesktopImmerOp::Add | DesktopImmerOp::Replace => {
                *target = patch
                    .value
                    .clone()
                    .ok_or_else(|| "desktop IPC root patch was missing value".to_string())?;
                Ok(())
            }
            DesktopImmerOp::Remove => {
                *target = Value::Null;
                Ok(())
            }
        };
    }

    let (last_segment, parent_path) = patch
        .path
        .split_last()
        .ok_or_else(|| "desktop IPC patch path unexpectedly empty".to_string())?;
    let parent = locate_value_mut(target, parent_path)?;

    match (parent, last_segment, patch.op) {
        (Value::Object(object), DesktopImmerPathSegment::Key(key), DesktopImmerOp::Add)
        | (Value::Object(object), DesktopImmerPathSegment::Key(key), DesktopImmerOp::Replace) => {
            object.insert(
                key.clone(),
                patch.value.clone().ok_or_else(|| {
                    format!("desktop IPC object patch for {key} was missing value")
                })?,
            );
            Ok(())
        }
        (Value::Object(object), DesktopImmerPathSegment::Key(key), DesktopImmerOp::Remove) => {
            object.remove(key);
            Ok(())
        }
        (Value::Array(array), DesktopImmerPathSegment::Index(index), DesktopImmerOp::Add) => {
            let value = patch.value.clone().ok_or_else(|| {
                format!("desktop IPC array add patch at {index} was missing value")
            })?;
            if *index > array.len() {
                return Err(format!(
                    "desktop IPC array add patch index {index} exceeds length {}",
                    array.len()
                ));
            }
            array.insert(*index, value);
            Ok(())
        }
        (Value::Array(array), DesktopImmerPathSegment::Index(index), DesktopImmerOp::Replace) => {
            let value = patch.value.clone().ok_or_else(|| {
                format!("desktop IPC array replace patch at {index} was missing value")
            })?;
            let Some(slot) = array.get_mut(*index) else {
                return Err(format!(
                    "desktop IPC array replace patch index {index} exceeds length {}",
                    array.len()
                ));
            };
            *slot = value;
            Ok(())
        }
        (Value::Array(array), DesktopImmerPathSegment::Index(index), DesktopImmerOp::Remove) => {
            if *index >= array.len() {
                return Err(format!(
                    "desktop IPC array remove patch index {index} exceeds length {}",
                    array.len()
                ));
            }
            array.remove(*index);
            Ok(())
        }
        (Value::Object(_), DesktopImmerPathSegment::Index(index), _) => Err(format!(
            "desktop IPC patch segment type did not match object parent for array index {index}"
        )),
        (Value::Array(_), DesktopImmerPathSegment::Key(key), _) => Err(format!(
            "desktop IPC patch segment type did not match array parent for object key {key}"
        )),
        (other, _, _) => Err(format!(
            "desktop IPC patch parent was not a container: {other}"
        )),
    }
}

fn locate_value_mut<'a>(
    current: &'a mut Value,
    path: &[DesktopImmerPathSegment],
) -> Result<&'a mut Value, String> {
    let mut current = current;
    for segment in path {
        current = match segment {
            DesktopImmerPathSegment::Key(key) => current
                .get_mut(key)
                .ok_or_else(|| format!("desktop IPC object path segment was missing: {key}"))?,
            DesktopImmerPathSegment::Index(index) => current
                .as_array_mut()
                .and_then(|array| array.get_mut(*index))
                .ok_or_else(|| format!("desktop IPC array path segment was missing: {index}"))?,
        };
    }
    Ok(current)
}

fn map_conversation_entries(
    thread_id: &str,
    turns: &[Value],
) -> Result<Vec<ThreadTimelineEntryDto>, String> {
    let mut entries = Vec::new();
    for turn in turns {
        let turn_id = turn
            .get("turnId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| "desktop IPC turn was missing turnId".to_string())?;
        let items = turn
            .get("items")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("desktop IPC turn {turn_id} was missing items"))?;
        for (index, item) in items.iter().enumerate() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
                continue;
            };
            if !should_publish_live_payload(kind, &payload) {
                continue;
            }
            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("item-{index}"));
            let occurred_at = item_timestamp(item)
                .or_else(|| turn_timestamp(turn))
                .or_else(|| uuid_v7_timestamp(turn_id))
                .unwrap_or_else(current_timestamp_string);
            let envelope = build_timeline_event_envelope(
                format!("{turn_id}-{item_id}"),
                thread_id_for_turn(turn).unwrap_or_else(|| thread_id.to_string()),
                kind,
                occurred_at,
                payload.clone(),
            );
            entries.push(ThreadTimelineEntryDto {
                event_id: envelope.event_id,
                kind,
                occurred_at: envelope.occurred_at,
                summary: summarize_live_payload(kind, &payload),
                payload,
                annotations: envelope.annotations,
            });
        }
    }
    Ok(entries)
}

fn thread_id_for_turn(turn: &Value) -> Option<String> {
    turn.get("params")
        .and_then(|params| params.get("threadId"))
        .and_then(Value::as_str)
        .map(|thread_id| format!("codex:{thread_id}"))
}

fn first_turn_workspace(turns: &[Value]) -> Option<String> {
    turns.iter().find_map(|turn| {
        turn.get("params")
            .and_then(|params| params.get("cwd"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

fn latest_entry_timestamp(entries: &[ThreadTimelineEntryDto]) -> Option<String> {
    entries.last().map(|entry| entry.occurred_at.clone())
}

fn first_turn_timestamp(turns: &[Value]) -> Option<String> {
    turns.first().and_then(turn_timestamp)
}

fn latest_turn_timestamp(turns: &[Value]) -> Option<String> {
    turns.iter().rev().find_map(turn_timestamp)
}

fn turn_timestamp(turn: &Value) -> Option<String> {
    ["turnStartedAtMs", "finalAssistantStartedAtMs"]
        .into_iter()
        .find_map(|key| turn.get(key))
        .and_then(timestamp_value)
        .or_else(|| {
            turn.get("turnId")
                .and_then(Value::as_str)
                .and_then(uuid_v7_timestamp)
        })
}

fn item_timestamp(item: &Value) -> Option<String> {
    [
        "timestamp",
        "occurredAt",
        "updatedAt",
        "createdAt",
        "startedAt",
        "completedAt",
        "startTime",
        "endTime",
    ]
    .into_iter()
    .find_map(|key| item.get(key))
    .and_then(timestamp_value)
}

fn timestamp_value(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            trimmed
                .parse::<i64>()
                .ok()
                .map(unix_timestamp_to_iso8601)
                .or_else(|| Some(trimmed.to_string()))
        }
        Value::Number(number) => number.as_i64().map(unix_timestamp_to_iso8601).or_else(|| {
            number
                .as_u64()
                .map(|value| unix_timestamp_to_iso8601(value as i64))
        }),
        _ => None,
    }
}

fn uuid_v7_timestamp(value: &str) -> Option<String> {
    let compact = value.chars().filter(|ch| *ch != '-').collect::<String>();
    if compact.len() != 32 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }
    if !compact
        .chars()
        .nth(12)
        .is_some_and(|version| version.eq_ignore_ascii_case(&'7'))
    {
        return None;
    }
    let millis = i64::from_str_radix(&compact[0..12], 16).ok()?;
    Some(unix_timestamp_to_iso8601(millis))
}

pub(crate) fn turn_status(turn: &Value) -> Option<ThreadStatus> {
    let raw = turn.get("status").and_then(Value::as_str)?;
    let normalized = raw.trim().to_ascii_lowercase().replace(['_', ' '], "");
    match normalized.as_str() {
        "pending" | "queued" | "inprogress" | "running" | "active" | "thinking" | "started"
        | "progress" => Some(ThreadStatus::Running),
        "completed" | "complete" | "done" | "success" | "ok" | "succeeded" => {
            Some(ThreadStatus::Completed)
        }
        "idle" => Some(ThreadStatus::Idle),
        "interrupted" | "halted" | "cancelled" | "canceled" => Some(ThreadStatus::Interrupted),
        "failed" | "fail" | "error" | "errored" | "denied" => Some(ThreadStatus::Failed),
        _ => None,
    }
}

pub(crate) fn raw_turn_status(turn: &Value) -> Option<&str> {
    turn.get("status").and_then(Value::as_str)
}

fn thread_status_wire_value(status: ThreadStatus) -> &'static str {
    match status {
        ThreadStatus::Idle => "idle",
        ThreadStatus::Running => "running",
        ThreadStatus::Completed => "completed",
        ThreadStatus::Interrupted => "interrupted",
        ThreadStatus::Failed => "failed",
    }
}

#[cfg(test)]
mod tests {
    use serde_json::Value;
    use serde_json::json;
    use shared_contracts::{BridgeEventKind, ThreadStatus};

    use super::{
        AccessMode, DesktopImmerOp, DesktopImmerPatch, DesktopImmerPathSegment, apply_patches,
        diff_thread_snapshots, snapshot_from_conversation_state, turn_status,
    };

    #[test]
    fn apply_patches_replaces_nested_items() {
        let mut conversation = json!({
            "id": "thread-1",
            "turns": [{
                "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                "status": "running",
                "params": { "threadId": "thread-1", "cwd": "/tmp/repo" },
                "items": [
                    { "type": "agentMessage", "id": "item-1", "text": "hello" }
                ]
            }]
        });

        apply_patches(
            &mut conversation,
            &[DesktopImmerPatch {
                op: DesktopImmerOp::Replace,
                path: vec![
                    DesktopImmerPathSegment::Key("turns".to_string()),
                    DesktopImmerPathSegment::Index(0),
                    DesktopImmerPathSegment::Key("items".to_string()),
                    DesktopImmerPathSegment::Index(0),
                ],
                value: Some(json!({
                    "type": "agentMessage",
                    "id": "item-1",
                    "text": "hello world"
                })),
            }],
        )
        .expect("patch application should succeed");

        assert_eq!(
            conversation["turns"][0]["items"][0]["text"],
            Value::String("hello world".to_string())
        );
    }

    #[test]
    fn snapshot_mapping_builds_entries_and_thread_detail() {
        let snapshot = snapshot_from_conversation_state(
            &json!({
                "id": "thread-1",
                "hostId": "local",
                "turns": [{
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "running",
                    "turnStartedAtMs": 1774592758217_i64,
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/tmp/repo",
                        "input": [{ "type": "text", "text": "Investigate mobile bridge sync" }]
                    },
                    "items": [
                        { "type": "userMessage", "id": "item-1", "content": [{ "type": "text", "text": "Investigate mobile bridge sync" }] },
                        { "type": "agentMessage", "id": "item-2", "text": "Streaming now" },
                        { "type": "commandExecution", "id": "item-3", "command": "git status", "aggregatedOutput": "clean" }
                    ]
                }]
            }),
            None,
            AccessMode::ControlWithApprovals,
        )
        .expect("snapshot mapping should succeed");

        assert_eq!(snapshot.thread.thread_id, "codex:thread-1");
        assert_eq!(snapshot.thread.native_thread_id, "thread-1");
        assert_eq!(snapshot.thread.workspace, "/tmp/repo");
        assert_eq!(snapshot.thread.repository, "repo");
        assert_eq!(snapshot.thread.status, ThreadStatus::Running);
        assert_eq!(snapshot.entries.len(), 3);
        assert_eq!(snapshot.entries[1].kind, BridgeEventKind::MessageDelta);
        assert_eq!(snapshot.entries[2].kind, BridgeEventKind::CommandDelta);
    }

    #[test]
    fn snapshot_mapping_keeps_placeholder_title_when_no_explicit_name_exists() {
        let snapshot = snapshot_from_conversation_state(
            &json!({
                "id": "thread-1",
                "hostId": "local",
                "turns": [{
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "running",
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/tmp/repo",
                        "input": [{ "type": "text", "text": "This should not become the thread title" }]
                    },
                    "items": [
                        { "type": "userMessage", "id": "item-1", "content": [{ "type": "text", "text": "This should not become the thread title" }] }
                    ]
                }]
            }),
            None,
            AccessMode::ControlWithApprovals,
        )
        .expect("snapshot mapping should succeed");

        assert_eq!(snapshot.thread.title, "Untitled thread");
    }

    #[test]
    fn snapshot_diff_emits_changed_entry_and_status() {
        let previous = snapshot_from_conversation_state(
            &json!({
                "id": "thread-1",
                "hostId": "local",
                "turns": [{
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "running",
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/tmp/repo",
                        "input": [{ "type": "text", "text": "Investigate mobile bridge sync" }]
                    },
                    "items": [
                        { "type": "agentMessage", "id": "item-2", "text": "Streaming" }
                    ]
                }]
            }),
            None,
            AccessMode::ControlWithApprovals,
        )
        .expect("previous snapshot should map");
        let next = snapshot_from_conversation_state(
            &json!({
                "id": "thread-1",
                "hostId": "local",
                "turns": [{
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "completed",
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/tmp/repo",
                        "input": [{ "type": "text", "text": "Investigate mobile bridge sync" }]
                    },
                    "items": [
                        { "type": "agentMessage", "id": "item-2", "text": "Streaming done" }
                    ]
                }]
            }),
            Some(&previous),
            AccessMode::ControlWithApprovals,
        )
        .expect("next snapshot should map");

        let events = diff_thread_snapshots(Some(&previous), &next);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[1].kind, BridgeEventKind::ThreadStatusChanged);
    }

    #[test]
    fn turn_status_recognizes_desktop_status_variants() {
        assert_eq!(
            turn_status(&json!({"status":"in_progress"})),
            Some(ThreadStatus::Running)
        );
        assert_eq!(
            turn_status(&json!({"status":"active"})),
            Some(ThreadStatus::Running)
        );
        assert_eq!(
            turn_status(&json!({"status":"done"})),
            Some(ThreadStatus::Completed)
        );
        assert_eq!(
            turn_status(&json!({"status":"errored"})),
            Some(ThreadStatus::Failed)
        );
        assert_eq!(turn_status(&json!({"status":"mystery"})), None);
    }
}
