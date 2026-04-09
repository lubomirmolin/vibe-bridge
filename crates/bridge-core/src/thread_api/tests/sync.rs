use super::*;

#[test]
fn sync_thread_from_upstream_refreshes_only_requested_thread() {
    let target_thread_id = codex_thread_id("thread-target");
    let other_thread_id = codex_thread_id("thread-other");
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-target","thread_name":"Fresh target title","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-target.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-target","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Fresh target body."}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let mut service = ThreadApiService {
        thread_records: vec![
            UpstreamThreadRecord {
                id: target_thread_id.clone(),
                native_id: "thread-target".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                headline: "Stale target title".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/stale-target".to_string(),
                repository_name: "stale-target".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:00:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "stale target summary".to_string(),
            },
            UpstreamThreadRecord {
                id: other_thread_id.clone(),
                native_id: "thread-other".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                headline: "Unrelated thread".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/other".to_string(),
                repository_name: "other".to_string(),
                branch_name: "main".to_string(),
                remote_name: "origin".to_string(),
                git_dirty: false,
                git_ahead_by: 0,
                git_behind_by: 0,
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:00:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "other summary".to_string(),
            },
        ],
        timeline_by_thread_id: HashMap::from([
            (
                target_thread_id.clone(),
                vec![UpstreamTimelineEvent {
                    id: "stale-target-event".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:00:00Z".to_string(),
                    summary_text: "stale target event".to_string(),
                    data: json!({"delta": "stale target event", "role": "assistant"}),
                }],
            ),
            (
                other_thread_id.clone(),
                vec![UpstreamTimelineEvent {
                    id: "other-event".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:00:00Z".to_string(),
                    summary_text: "other event".to_string(),
                    data: json!({"delta": "other event", "role": "assistant"}),
                }],
            ),
        ]),
        thread_sync_receipts_by_id: HashMap::new(),
        next_event_sequence: 10,
        sync_config: Some(ThreadSyncConfig {
            codex_command: "/definitely/missing/codex".to_string(),
            codex_args: Vec::new(),
            codex_endpoint: None,
            codex_home: codex_home.clone(),
        }),
    };

    service
        .sync_thread_from_upstream(&target_thread_id)
        .expect("thread sync should fall back to archive");

    let refreshed_target = service
        .thread_records
        .iter()
        .find(|thread| thread.id == target_thread_id)
        .expect("target thread should remain present");
    assert_eq!(refreshed_target.headline, "Fresh target title");
    assert_eq!(refreshed_target.last_turn_summary, "Fresh target body.");

    let untouched_other = service
        .thread_records
        .iter()
        .find(|thread| thread.id == other_thread_id)
        .expect("other thread should remain present");
    assert_eq!(untouched_other.headline, "Unrelated thread");
    assert_eq!(untouched_other.last_turn_summary, "other summary");

    let target_timeline = service
        .timeline_by_thread_id
        .get(&target_thread_id)
        .expect("target timeline should exist");
    assert_eq!(target_timeline.len(), 1);
    assert_eq!(target_timeline[0].summary_text, "Fresh target body.");

    let other_timeline = service
        .timeline_by_thread_id
        .get(&other_thread_id)
        .expect("other timeline should still exist");
    assert_eq!(other_timeline.len(), 1);
    assert_eq!(other_timeline[0].id, "other-event");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_reuses_fresh_snapshot_for_detail_then_timeline_pair() {
    let native_thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let thread_id = codex_thread_id(native_thread_id);
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        native_thread_id,
        "2026-03-19T10:00:00Z",
        "Cold snapshot title",
        "Cold snapshot summary.",
    );

    let mut service = ThreadApiService::with_seed_data(Vec::new(), HashMap::new());
    service.sync_config = Some(ThreadSyncConfig {
        codex_command: "/definitely/missing/codex".to_string(),
        codex_args: Vec::new(),
        codex_endpoint: None,
        codex_home: codex_home.clone(),
    });

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("initial cold sync should load archive snapshot");

    let receipt_before = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("thread receipt should exist after initial sync")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("immediate companion sync should succeed");

    let receipt_after = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("thread receipt should remain after companion sync")
        .synced_at_millis;
    assert_eq!(
        receipt_after, receipt_before,
        "immediate detail/timeline companion request should stay on the same warm generation"
    );

    let detail = service
        .detail_response(&thread_id)
        .expect("thread detail should remain present");
    assert_eq!(detail.thread.title, "Cold snapshot title");
    assert_eq!(detail.thread.updated_at, "2026-03-19T10:00:00Z");

    let timeline = service
        .timeline_page_response(&thread_id, None, 80)
        .expect("timeline should remain available");
    assert_eq!(timeline.thread.title, "Cold snapshot title");
    assert_eq!(timeline.thread.updated_at, "2026-03-19T10:00:00Z");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_reuses_single_refresh_generation_for_reconnect_style_pair() {
    let native_thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let thread_id = codex_thread_id(native_thread_id);
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        native_thread_id,
        "2026-03-19T10:00:00Z",
        "Initial title",
        "Initial summary.",
    );

    let mut service = ThreadApiService::with_seed_data(Vec::new(), HashMap::new());
    service.sync_config = Some(ThreadSyncConfig {
        codex_command: "/definitely/missing/codex".to_string(),
        codex_args: Vec::new(),
        codex_endpoint: None,
        codex_home: codex_home.clone(),
    });

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("initial sync should load first snapshot");

    let first_receipt_before = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("receipt should exist after initial sync")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("timeline companion request should succeed");
    let first_receipt_after = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("receipt should remain after companion sync")
        .synced_at_millis;
    assert_eq!(
        first_receipt_after, first_receipt_before,
        "unchanged reconnect-style companion request should reuse the warm generation"
    );
    assert_eq!(
        service
            .detail_response(&thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Initial title"
    );

    if let Some(receipt) = service.thread_sync_receipts_by_id.get_mut(&thread_id) {
        receipt.synced_at_millis = super::current_unix_epoch_millis()
            .saturating_sub(super::THREAD_SYNC_REUSE_WINDOW_MILLIS + 1);
    }

    write_archived_thread_fixture(
        &codex_home,
        native_thread_id,
        "2026-03-19T10:30:00Z",
        "Reconnect title",
        "Reconnect refresh summary.",
    );

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("reconnect detail request should refresh from archive");
    assert_eq!(
        service
            .detail_response(&thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Reconnect title"
    );

    let second_receipt_before = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("receipt should exist after reconnect refresh")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("reconnect timeline companion request should succeed");
    let second_receipt_after = service
        .thread_sync_receipts_by_id
        .get(&thread_id)
        .expect("receipt should remain after reconnect companion")
        .synced_at_millis;
    assert_eq!(
        second_receipt_after, second_receipt_before,
        "reconnect-style detail/timeline pair should share a single warm generation"
    );
    assert_eq!(
        service
            .detail_response(&thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Reconnect title"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_keeps_fast_path_for_same_thread_after_interleaved_read() {
    let canonical_native_thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let canonical_thread_id = codex_thread_id(canonical_native_thread_id);
    let interleaved_native_thread_id = "thread-other";
    let interleaved_thread_id = codex_thread_id(interleaved_native_thread_id);
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixtures(
        &codex_home,
        &[
            (
                canonical_native_thread_id,
                "2026-03-19T10:00:00Z",
                "Canonical title",
                "Canonical summary.",
            ),
            (
                interleaved_native_thread_id,
                "2026-03-19T09:00:00Z",
                "Interleaved title",
                "Interleaved summary.",
            ),
        ],
    );

    let mut service = ThreadApiService::with_seed_data(Vec::new(), HashMap::new());
    service.sync_config = Some(ThreadSyncConfig {
        codex_command: "/definitely/missing/codex".to_string(),
        codex_args: Vec::new(),
        codex_endpoint: None,
        codex_home: codex_home.clone(),
    });

    service
        .sync_thread_from_upstream(&canonical_thread_id)
        .expect("initial sync should load canonical thread snapshot");

    let canonical_receipt_before = service
        .thread_sync_receipts_by_id
        .get(&canonical_thread_id)
        .expect("canonical sync receipt should exist")
        .synced_at_millis;

    // This delay intentionally exceeds the old 250ms warm window while still
    // representing an immediate user-level interleaved read sequence.
    std::thread::sleep(std::time::Duration::from_millis(350));

    service
        .sync_thread_from_upstream(&interleaved_thread_id)
        .expect("interleaved thread sync should succeed");
    service
        .sync_thread_from_upstream(&canonical_thread_id)
        .expect("revisited canonical thread sync should succeed");

    let canonical_receipt_after = service
        .thread_sync_receipts_by_id
        .get(&canonical_thread_id)
        .expect("canonical sync receipt should still exist")
        .synced_at_millis;

    assert_eq!(
        canonical_receipt_after, canonical_receipt_before,
        "canonical thread should stay on the warm fast path after interleaving another thread"
    );
    assert_eq!(
        service
            .detail_response(&canonical_thread_id)
            .expect("canonical detail should remain available")
            .thread
            .title,
        "Canonical title"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_invalidates_fast_path_when_archive_index_changes() {
    let native_thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let thread_id = codex_thread_id(native_thread_id);
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        native_thread_id,
        "2026-03-19T10:00:00Z",
        "Initial title",
        "Initial summary.",
    );

    let session_index_path = codex_home.join("session_index.jsonl");
    let initial_index_modified_at = fs::metadata(&session_index_path)
        .expect("session index metadata should exist")
        .modified()
        .expect("session index modified time should be readable");

    let mut service = ThreadApiService::with_seed_data(Vec::new(), HashMap::new());
    service.sync_config = Some(ThreadSyncConfig {
        codex_command: "/definitely/missing/codex".to_string(),
        codex_args: Vec::new(),
        codex_endpoint: None,
        codex_home: codex_home.clone(),
    });

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("initial sync should load first snapshot");

    std::thread::sleep(std::time::Duration::from_millis(5));

    write_archived_thread_fixture(
        &codex_home,
        native_thread_id,
        "2026-03-19T10:30:00Z",
        "Updated title",
        "Updated summary.",
    );

    let updated_index_modified_at = fs::metadata(&session_index_path)
        .expect("session index metadata should still exist")
        .modified()
        .expect("updated session index modified time should be readable");
    assert!(
        updated_index_modified_at > initial_index_modified_at,
        "fixture update should advance session index modified time"
    );

    if let Some(receipt) = service.thread_sync_receipts_by_id.get_mut(&thread_id) {
        receipt.synced_at_millis = super::current_unix_epoch_millis();
    }

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("sync after archive update should succeed");

    assert_eq!(
        service
            .detail_response(&thread_id)
            .expect("detail should remain present")
            .thread
            .title,
        "Updated title",
        "archive index updates should invalidate the warm fast path"
    );

    let _ = fs::remove_dir_all(codex_home);
}
