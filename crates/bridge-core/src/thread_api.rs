mod archive;
mod notifications;
mod patch_diff;
mod rpc;
mod service;
mod sync;
#[cfg(test)]
mod tests;
mod timeline;

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use shared_contracts::{BridgeEventEnvelope, ThreadDetailDto, ThreadStatus, ThreadSummaryDto};

use self::archive::{is_file_change_custom_tool, is_file_change_text};
pub(crate) use self::archive::{
    load_archive_timeline_entries_for_session_path, load_archive_timeline_entries_for_thread,
};
#[cfg(test)]
use self::archive::{
    load_thread_snapshot_from_codex_archive, load_thread_snapshot_from_codex_archive_for_ids,
    merge_thread_snapshots,
};
pub(crate) use self::notifications::CodexNotificationNormalizer;
pub use self::notifications::CodexNotificationStream;
#[cfg(test)]
use self::rpc::{CodexThread, CodexThreadStatus, CodexTurn, should_resume_thread};
#[cfg(test)]
use self::sync::THREAD_SYNC_REUSE_WINDOW_MILLIS;
use self::sync::{ThreadSyncConfig, ThreadSyncReceipt};
#[cfg(test)]
use self::timeline::{
    current_unix_epoch_millis, map_codex_thread_to_timeline_events, map_thread_detail,
    unix_timestamp_to_iso8601,
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
    pub data: Value,
}

type ThreadSnapshot = (
    Vec<UpstreamThreadRecord>,
    HashMap<String, Vec<UpstreamTimelineEvent>>,
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadApiService {
    thread_records: Vec<UpstreamThreadRecord>,
    timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    thread_sync_receipts_by_id: HashMap<String, ThreadSyncReceipt>,
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
