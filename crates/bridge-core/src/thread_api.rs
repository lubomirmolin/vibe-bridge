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
use shared_contracts::{
    BridgeEventEnvelope, ProviderKind, ThreadClientKind, ThreadDetailDto, ThreadGitDiffMode,
    ThreadStatus, ThreadSummaryDto,
};

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
pub(crate) use self::notifications::{normalize_codex_item_payload, should_publish_live_payload};
#[cfg(test)]
use self::rpc::{CodexThread, CodexThreadStatus, CodexTurn, should_resume_thread};
#[cfg(test)]
use self::sync::THREAD_SYNC_REUSE_WINDOW_MILLIS;
use self::sync::{ThreadSyncConfig, ThreadSyncReceipt};
pub(crate) use self::timeline::{
    build_timeline_event_envelope, current_timestamp_string, derive_repository_name_from_cwd,
    map_thread_client_kind_from_source, summarize_live_payload, unix_timestamp_to_iso8601,
};
#[cfg(test)]
use self::timeline::{
    current_unix_epoch_millis, map_codex_thread_to_timeline_events, map_thread_detail,
};

pub(crate) fn provider_thread_id(provider: ProviderKind, native_id: &str) -> String {
    format!("{}:{native_id}", provider_prefix(provider))
}

pub(crate) fn provider_prefix(provider: ProviderKind) -> &'static str {
    match provider {
        ProviderKind::Codex => "codex",
        ProviderKind::ClaudeCode => "claude",
    }
}

pub(crate) fn provider_from_thread_id(thread_id: &str) -> Option<ProviderKind> {
    let (prefix, _) = thread_id.split_once(':')?;
    match prefix {
        "codex" => Some(ProviderKind::Codex),
        "claude" => Some(ProviderKind::ClaudeCode),
        _ => None,
    }
}

pub(crate) fn native_thread_id_for_provider<'a>(
    thread_id: &'a str,
    provider: ProviderKind,
) -> Option<&'a str> {
    match provider_from_thread_id(thread_id) {
        Some(found_provider) if found_provider == provider => {
            thread_id.split_once(':').map(|(_, native_id)| native_id)
        }
        None if provider == ProviderKind::Codex => Some(thread_id),
        _ => None,
    }
}

pub(crate) fn is_provider_thread_id(thread_id: &str, provider: ProviderKind) -> bool {
    native_thread_id_for_provider(thread_id, provider).is_some()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamThreadRecord {
    pub id: String,
    pub native_id: String,
    pub provider: ProviderKind,
    pub client: ThreadClientKind,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadGitDiffQuery {
    pub mode: ThreadGitDiffMode,
    pub path: Option<String>,
}
