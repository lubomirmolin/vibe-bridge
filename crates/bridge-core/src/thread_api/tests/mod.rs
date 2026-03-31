use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use super::{
    CodexNotificationNormalizer, CodexThread, CodexThreadStatus, CodexTurn,
    THREAD_SYNC_REUSE_WINDOW_MILLIS, ThreadApiService, ThreadSyncConfig, UpstreamThreadRecord,
    UpstreamTimelineEvent, current_unix_epoch_millis, load_thread_snapshot_from_codex_archive,
    load_thread_snapshot_from_codex_archive_for_ids, map_codex_thread_to_timeline_events,
    map_thread_detail, merge_thread_snapshots, provider_thread_id, should_resume_thread,
    unix_timestamp_to_iso8601,
};
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadStatus,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
};

mod archive;
mod notifications;
mod rpc_timeline;
mod service;
mod sync;

fn write_archived_thread_fixture(
    codex_home: &Path,
    thread_id: &str,
    updated_at: &str,
    title: &str,
    summary: &str,
) {
    write_archived_thread_fixtures(codex_home, &[(thread_id, updated_at, title, summary)]);
}

fn write_archived_thread_fixtures(codex_home: &Path, fixtures: &[(&str, &str, &str, &str)]) {
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");

    let index_line = fixtures
        .iter()
        .map(|(thread_id, updated_at, title, _)| {
            json!({
                "id": thread_id,
                "thread_name": title,
                "updated_at": updated_at,
            })
            .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(
        codex_home.join("session_index.jsonl"),
        format!("{index_line}\n"),
    )
    .expect("session index should be writable");

    for (thread_id, updated_at, _, summary) in fixtures {
        let session_meta_line = json!({
            "timestamp": "2026-03-19T09:55:00Z",
            "type": "session_meta",
            "payload": {
                "id": thread_id,
                "timestamp": "2026-03-19T09:55:00Z",
                "cwd": "/Users/test/workspace",
                "source": "vscode",
                "git": {
                    "branch": "master",
                    "repository_url": "git@github.com:example/codex-mobile-companion.git",
                }
            }
        })
        .to_string();
        let event_line = json!({
            "timestamp": updated_at,
            "type": "event_msg",
            "payload": {
                "type": "agent_message",
                "message": summary,
            }
        })
        .to_string();
        fs::write(
            sessions_directory.join(format!("rollout-2026-03-19T10-00-00-{thread_id}.jsonl")),
            format!("{session_meta_line}\n{event_line}\n"),
        )
        .expect("session log should be writable");
    }
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

fn codex_thread_id(native_id: &str) -> String {
    provider_thread_id(shared_contracts::ProviderKind::Codex, native_id)
}
