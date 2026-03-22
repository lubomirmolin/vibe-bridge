use std::fs;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

use super::ThreadApiService;

pub(super) const THREAD_SYNC_REUSE_WINDOW_MILLIS: u128 = 5_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ThreadSyncReceipt {
    pub(super) synced_at_millis: u128,
    pub(super) signature: ThreadSnapshotSignature,
    pub(super) session_index_modified_at_millis: Option<u128>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ThreadSnapshotSignature {
    pub(super) updated_at: String,
    pub(super) headline: String,
    pub(super) newest_event_id: Option<String>,
    pub(super) newest_event_at: Option<String>,
    pub(super) timeline_len: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ThreadSyncConfig {
    pub(super) codex_command: String,
    pub(super) codex_args: Vec<String>,
    pub(super) codex_endpoint: Option<String>,
    pub(super) codex_home: PathBuf,
}

impl ThreadApiService {
    pub(super) fn should_reuse_recent_thread_sync(&self, thread_id: &str) -> bool {
        let Some(receipt) = self.thread_sync_receipts_by_id.get(thread_id) else {
            return false;
        };

        let elapsed = super::current_unix_epoch_millis().saturating_sub(receipt.synced_at_millis);
        if elapsed > THREAD_SYNC_REUSE_WINDOW_MILLIS {
            return false;
        }

        self.thread_snapshot_signature(thread_id)
            .is_some_and(|signature| signature == receipt.signature)
            && self.session_index_modified_at_millis() == receipt.session_index_modified_at_millis
    }

    pub(super) fn refresh_thread_sync_receipt(&mut self, thread_id: &str) {
        let Some(signature) = self.thread_snapshot_signature(thread_id) else {
            self.thread_sync_receipts_by_id.remove(thread_id);
            return;
        };

        self.thread_sync_receipts_by_id.insert(
            thread_id.to_string(),
            ThreadSyncReceipt {
                synced_at_millis: super::current_unix_epoch_millis(),
                signature,
                session_index_modified_at_millis: self.session_index_modified_at_millis(),
            },
        );
    }

    fn session_index_modified_at_millis(&self) -> Option<u128> {
        let sync_config = self.sync_config.as_ref()?;
        let session_index_path = sync_config.codex_home.join("session_index.jsonl");
        fs::metadata(session_index_path)
            .ok()?
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis())
    }

    pub(super) fn refresh_all_thread_sync_receipts(&mut self) {
        let thread_ids = self
            .thread_records
            .iter()
            .map(|thread| thread.id.clone())
            .collect::<Vec<_>>();
        self.thread_sync_receipts_by_id.clear();
        for thread_id in thread_ids {
            self.refresh_thread_sync_receipt(&thread_id);
        }
    }

    fn thread_snapshot_signature(&self, thread_id: &str) -> Option<ThreadSnapshotSignature> {
        let thread = self
            .thread_records
            .iter()
            .find(|thread| thread.id == thread_id)?;
        let timeline = self.timeline_by_thread_id.get(thread_id);
        let newest_event = timeline.and_then(|events| events.last());

        Some(ThreadSnapshotSignature {
            updated_at: thread.updated_at.clone(),
            headline: thread.headline.clone(),
            newest_event_id: newest_event.map(|event| event.id.clone()),
            newest_event_at: newest_event.map(|event| event.happened_at.clone()),
            timeline_len: timeline.map_or(0, Vec::len),
        })
    }
}
