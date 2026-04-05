mod archive;
mod patch_diff;
mod rpc;
mod timeline;

use std::collections::HashMap;

use serde_json::Value;
use shared_contracts::{ProviderKind, ThreadClientKind};

pub(crate) use self::archive::{
    load_archive_timeline_entries_for_session_path, load_archive_timeline_entries_for_thread,
    load_thread_snapshot, load_thread_snapshot_for_id, resolve_codex_home_dir,
};
pub(crate) use self::timeline::{map_thread_detail, map_thread_summary, map_timeline_entry};
pub(crate) use crate::thread_identity::{native_thread_id_for_provider, provider_thread_id};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UpstreamThreadRecord {
    pub(crate) id: String,
    pub(crate) native_id: String,
    pub(crate) provider: ProviderKind,
    pub(crate) client: ThreadClientKind,
    pub(crate) headline: String,
    pub(crate) lifecycle_state: String,
    pub(crate) workspace_path: String,
    pub(crate) repository_name: String,
    pub(crate) branch_name: String,
    pub(crate) remote_name: String,
    pub(crate) git_dirty: bool,
    pub(crate) git_ahead_by: u32,
    pub(crate) git_behind_by: u32,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) source: String,
    pub(crate) approval_mode: String,
    pub(crate) last_turn_summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UpstreamTimelineEvent {
    pub(crate) id: String,
    pub(crate) event_type: String,
    pub(crate) happened_at: String,
    pub(crate) summary_text: String,
    pub(crate) data: Value,
}

type ThreadSnapshot = (
    Vec<UpstreamThreadRecord>,
    HashMap<String, Vec<UpstreamTimelineEvent>>,
);
