use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use super::{
    CodexNotificationNormalizer, CodexThread, CodexThreadStatus, CodexTurn, ThreadApiService,
    ThreadSyncConfig, UpstreamThreadRecord, UpstreamTimelineEvent, should_resume_thread,
};
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadStatus,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
};

#[test]
fn list_and_detail_responses_normalize_upstream_thread_shapes() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-abc".to_string(),
            headline: "Normalize thread payloads".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "master".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: true,
            git_ahead_by: 1,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "read_only".to_string(),
            last_turn_summary: "started normalization".to_string(),
        }],
        HashMap::new(),
    );

    let list = service.list_response();
    assert_eq!(list.contract_version, CONTRACT_VERSION);
    assert_eq!(list.threads[0].thread_id, "thread-abc");
    assert_eq!(list.threads[0].status, ThreadStatus::Running);

    let detail = service
        .detail_response("thread-abc")
        .expect("detail response should exist");
    assert_eq!(detail.thread.access_mode, AccessMode::ReadOnly);
    assert_eq!(detail.thread.last_turn_summary, "started normalization");
}

#[test]
fn timeline_page_response_normalizes_event_kinds() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-abc".to_string(),
            headline: "Normalize stream payloads".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "master".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "streaming".to_string(),
        }],
        HashMap::from([(
            "thread-abc".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-abc".to_string(),
                event_type: "command_output_delta".to_string(),
                happened_at: "2026-03-17T10:06:00Z".to_string(),
                summary_text: "command output".to_string(),
                data: serde_json::json!({ "delta": "line" }),
            }],
        )]),
    );

    let timeline = service
        .timeline_page_response("thread-abc", None, 50)
        .expect("timeline response should exist");

    assert_eq!(timeline.contract_version, CONTRACT_VERSION);
    assert_eq!(timeline.entries.len(), 1);
    assert_eq!(timeline.entries[0].kind, BridgeEventKind::CommandDelta);
    assert_eq!(timeline.thread.thread_id, "thread-abc");
}

#[test]
fn timeline_page_response_adds_exploration_annotations_without_mutating_payload() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-abc".to_string(),
            headline: "Normalize stream payloads".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "master".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "streaming".to_string(),
        }],
        HashMap::from([(
            "thread-abc".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "turn-123-tool-1".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "search output".to_string(),
                    data: json!({
                        "id": "tool-1",
                        "command": "exec_command",
                        "arguments": {"cmd": "rg -n timeline crates/bridge-core/src/thread_api.rs"},
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-tool-2".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:01Z".to_string(),
                    summary_text: "read output".to_string(),
                    data: json!({
                        "id": "tool-2",
                        "command": "exec_command",
                        "arguments": {"cmd": "sed -n 1,20p crates/bridge-core/src/thread_api.rs"},
                    }),
                },
            ],
        )]),
    );

    let timeline = service
        .timeline_page_response("thread-abc", None, 50)
        .expect("timeline response should exist");

    let search_annotations = timeline.entries[0]
        .annotations
        .as_ref()
        .expect("search entry should include annotations");
    assert_eq!(
        search_annotations.group_kind,
        Some(ThreadTimelineGroupKind::Exploration)
    );
    assert_eq!(
        search_annotations.group_id.as_deref(),
        Some("exploration:turn-123")
    );
    assert_eq!(
        search_annotations.exploration_kind,
        Some(ThreadTimelineExplorationKind::Search)
    );
    assert_eq!(search_annotations.entry_label.as_deref(), Some("Search"));
    assert!(timeline.entries[0].payload.get("presentation").is_none());

    let read_annotations = timeline.entries[1]
        .annotations
        .as_ref()
        .expect("read entry should include annotations");
    assert_eq!(
        read_annotations.exploration_kind,
        Some(ThreadTimelineExplorationKind::Read)
    );
    assert_eq!(
        read_annotations.entry_label.as_deref(),
        Some("Read thread_api.rs")
    );
    assert!(timeline.entries[1].payload.get("presentation").is_none());
}

#[test]
fn timeline_page_response_for_existing_thread_without_events_returns_empty_payload() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-empty".to_string(),
            headline: "Thread without timeline events".to_string(),
            lifecycle_state: "done".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "master".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "No turns yet".to_string(),
        }],
        HashMap::new(),
    );

    let timeline = service
        .timeline_page_response("thread-empty", None, 50)
        .expect("existing thread should return timeline payload");

    assert_eq!(timeline.thread.thread_id, "thread-empty");
    assert!(timeline.entries.is_empty());
    assert_eq!(timeline.next_before, None);
    assert!(!timeline.has_more_before);
}

#[test]
fn timeline_page_response_applies_before_cursor_and_limit() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-page".to_string(),
            headline: "Paged timeline".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "streaming".to_string(),
        }],
        HashMap::from([(
            "thread-page".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "one".to_string(),
                    data: json!({"delta": "one"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-2".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:02:00Z".to_string(),
                    summary_text: "two".to_string(),
                    data: json!({"delta": "two"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-3".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:03:00Z".to_string(),
                    summary_text: "three".to_string(),
                    data: json!({"delta": "three"}),
                },
            ],
        )]),
    );

    let newest_page = service
        .timeline_page_response("thread-page", None, 2)
        .expect("timeline page should exist");
    assert_eq!(
        newest_page
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["evt-2", "evt-3"]
    );
    assert_eq!(newest_page.next_before.as_deref(), Some("evt-2"));
    assert!(newest_page.has_more_before);

    let older_page = service
        .timeline_page_response("thread-page", newest_page.next_before.as_deref(), 2)
        .expect("older page should exist");
    assert_eq!(
        older_page
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["evt-1"]
    );
    assert_eq!(older_page.next_before, None);
    assert!(!older_page.has_more_before);
}

#[test]
fn reconcile_snapshot_preserves_mixed_event_order_for_equal_timestamps() {
    let thread = UpstreamThreadRecord {
        id: "thread-mixed".to_string(),
        headline: "Mixed events".to_string(),
        lifecycle_state: "active".to_string(),
        workspace_path: "/workspace/codex-mobile-companion".to_string(),
        repository_name: "codex-mobile-companion".to_string(),
        branch_name: "main".to_string(),
        remote_name: "origin".to_string(),
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: "2026-03-17T10:00:00Z".to_string(),
        updated_at: "2026-03-17T10:05:00Z".to_string(),
        source: "cli".to_string(),
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: "mixed".to_string(),
    };

    let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], HashMap::new());
    let _ = service.reconcile_snapshot(
        vec![thread],
        HashMap::from([(
            "thread-mixed".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-2".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "message".to_string(),
                    data: json!({"delta": "message"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-10".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "file".to_string(),
                    data: json!({"change": "file"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-1".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "command".to_string(),
                    data: json!({"output": "command"}),
                },
            ],
        )]),
    );

    let page = service
        .timeline_page_response("thread-mixed", None, 50)
        .expect("timeline page should exist");
    assert_eq!(
        page.entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["evt-2", "evt-10", "evt-1"]
    );
    assert_eq!(
        page.entries
            .iter()
            .map(|entry| entry.kind)
            .collect::<Vec<_>>(),
        vec![
            BridgeEventKind::MessageDelta,
            BridgeEventKind::FileChange,
            BridgeEventKind::CommandDelta,
        ]
    );
}

#[test]
fn equal_timestamp_pagination_cursors_advance_past_internal_only_window() {
    let thread = UpstreamThreadRecord {
        id: "thread-page-stability".to_string(),
        headline: "Cursor stability".to_string(),
        lifecycle_state: "active".to_string(),
        workspace_path: "/workspace/codex-mobile-companion".to_string(),
        repository_name: "codex-mobile-companion".to_string(),
        branch_name: "main".to_string(),
        remote_name: "origin".to_string(),
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: "2026-03-17T10:00:00Z".to_string(),
        updated_at: "2026-03-17T10:05:00Z".to_string(),
        source: "cli".to_string(),
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: "cursor".to_string(),
    };

    let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], HashMap::new());
    let _ = service.reconcile_snapshot(
        vec![thread],
        HashMap::from([(
            "thread-page-stability".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "oldest visible".to_string(),
                    data: json!({"delta": "oldest visible"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-2".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "internal-only-1".to_string(),
                    data: json!({"internal": true}),
                },
                UpstreamTimelineEvent {
                    id: "evt-10".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "internal-only-2".to_string(),
                    data: json!({"internal": true}),
                },
                UpstreamTimelineEvent {
                    id: "evt-11".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "newest visible".to_string(),
                    data: json!({"change": "newest visible"}),
                },
            ],
        )]),
    );

    let newest_page = service
        .timeline_page_response("thread-page-stability", None, 1)
        .expect("newest page should exist");
    assert_eq!(newest_page.entries[0].event_id, "evt-11");
    assert_eq!(newest_page.next_before.as_deref(), Some("evt-11"));

    let internal_only_page = service
        .timeline_page_response(
            "thread-page-stability",
            newest_page.next_before.as_deref(),
            2,
        )
        .expect("internal page should exist");
    assert_eq!(
        internal_only_page
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["evt-2", "evt-10"]
    );
    assert_eq!(internal_only_page.next_before.as_deref(), Some("evt-2"));

    let oldest_visible_page = service
        .timeline_page_response(
            "thread-page-stability",
            internal_only_page.next_before.as_deref(),
            2,
        )
        .expect("oldest visible page should exist");
    assert_eq!(oldest_visible_page.entries.len(), 1);
    assert_eq!(oldest_visible_page.entries[0].event_id, "evt-1");
    assert_eq!(oldest_visible_page.next_before, None);
    assert!(!oldest_visible_page.has_more_before);
}

#[test]
fn turn_mutations_produce_normalized_result_and_events() {
    let mut service = ThreadApiService::sample();

    let dispatch = service
        .start_turn("thread-123", Some("Investigate websocket routing"))
        .expect("turn mutation should not fail")
        .expect("thread should exist");

    assert_eq!(dispatch.response.operation, "turn_start");
    assert_eq!(dispatch.response.thread_status, ThreadStatus::Running);
    assert_eq!(dispatch.events.len(), 2);
    assert_eq!(
        dispatch.events[0].kind,
        BridgeEventKind::ThreadStatusChanged
    );
    assert_eq!(dispatch.events[0].thread_id, "thread-123");
}

#[test]
fn thread_not_found_errors_trigger_resume_retry() {
    assert!(should_resume_thread(
        "codex rpc request 'turn/start' failed: thread not found: thread-123"
    ));
    assert!(!should_resume_thread(
        "codex rpc request 'turn/start' failed: rate limited"
    ));
}

#[test]
fn git_mutations_retarget_repo_context_by_thread() {
    let mut service = ThreadApiService::sample();

    let first = service
        .switch_branch("thread-123", "feature/stream-router")
        .expect("first thread should exist");
    let second = service
        .push_repo("thread-456", Some("origin"))
        .expect("second thread should exist");

    assert_eq!(
        first.response.repository.repository,
        "codex-mobile-companion"
    );
    assert_eq!(first.response.repository.branch, "feature/stream-router");
    assert_eq!(second.response.repository.repository, "codex-runtime-tools");
    assert_eq!(second.response.repository.remote, "origin");

    let first_status = service
        .git_status_response("thread-123")
        .expect("status should exist for thread-123");
    assert_eq!(first_status.repository.branch, "feature/stream-router");
}

#[test]
fn archived_codex_sessions_load_as_thread_fallback() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-1","thread_name":"Investigate fallback","updated_at":"2026-03-19T09:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T09-00-00-thread-archive-1.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T08:55:00Z","type":"session_meta","payload":{"id":"thread-archive-1","timestamp":"2026-03-19T08:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T08:56:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Working through archive fallback."}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T08:57:00Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"pwd\"]}"}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (threads, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].id, "thread-archive-1");
    assert_eq!(threads[0].headline, "Investigate fallback");
    assert_eq!(threads[0].repository_name, "project");
    assert_eq!(threads[0].branch_name, "main");
    assert_eq!(threads[0].workspace_path, "/Users/test/workspace");
    assert_eq!(threads[0].source, "cli");

    let thread_timeline = timeline
        .get("thread-archive-1")
        .expect("timeline should exist for archived thread");
    assert_eq!(thread_timeline.len(), 2);
    assert_eq!(thread_timeline[0].event_type, "agent_message_delta");
    assert_eq!(thread_timeline[1].event_type, "command_output_delta");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archived_custom_tool_file_changes_map_to_file_change_events() {
    let codex_home = unique_test_codex_home();
    let workspace_directory = codex_home.join("workspace");
    fs::create_dir_all(workspace_directory.join("lib"))
        .expect("test workspace directory should exist");
    let workspace_file = workspace_directory.join("lib/main.dart");
    let mut workspace_lines = (1..95)
        .map(|index| format!("line {index}"))
        .collect::<Vec<_>>();
    workspace_lines.push("old".to_string());
    workspace_lines.push("line 96".to_string());
    fs::write(&workspace_file, format!("{}\n", workspace_lines.join("\n")))
        .expect("workspace file should be writable");

    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-tools","thread_name":"Apply patch fallback","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");

    let session_path =
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-tools.jsonl");
    let entries = vec![
        json!({
            "timestamp":"2026-03-19T09:55:00Z",
            "type":"session_meta",
            "payload":{
                "id":"thread-archive-tools",
                "timestamp":"2026-03-19T09:55:00Z",
                "cwd":workspace_directory,
                "source":"cli",
                "git":{"branch":"main","repository_url":"git@github.com:example/project.git"}
            }
        }),
        json!({
            "timestamp":"2026-03-19T09:56:00Z",
            "type":"response_item",
            "payload":{
                "type":"custom_tool_call",
                "name":"apply_patch",
                "call_id":"call-1",
                "input":format!(
                    "*** Begin Patch\n*** Update File: {}\n@@\n-old\n+new\n*** End Patch\n",
                    workspace_file.display()
                )
            }
        }),
        json!({
            "timestamp":"2026-03-19T09:57:00Z",
            "type":"response_item",
            "payload":{
                "type":"custom_tool_call_output",
                "call_id":"call-1",
                "output":format!(
                    "{{\"output\":\"Success. Updated the following files:\\nM {}\\n\",\"metadata\":{{\"exit_code\":0}}}}",
                    workspace_file.display()
                )
            }
        }),
    ];
    let content = entries
        .into_iter()
        .map(|entry| entry.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(session_path, format!("{content}\n")).expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get("thread-archive-tools")
        .expect("timeline should exist for archived thread");
    assert_eq!(thread_timeline.len(), 2);
    assert_eq!(thread_timeline[0].event_type, "file_change_delta");
    assert_eq!(thread_timeline[1].event_type, "file_change_delta");
    assert_eq!(
        thread_timeline[0]
            .data
            .get("resolved_unified_diff")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        format!(
            "diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -95,1 +95,1 @@\n-old\n+new",
            path = workspace_file.display()
        )
    );
    assert_eq!(
        thread_timeline[1]
            .data
            .get("output")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        format!(
            "Success. Updated the following files:\nM {}\n",
            workspace_file.display()
        )
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archived_delete_file_patch_resolves_to_deleted_unified_diff() {
    let codex_home = unique_test_codex_home();
    let workspace_directory = codex_home.join("workspace");
    let target_directory = workspace_directory.join("apps/mobile/test/features/threads");
    fs::create_dir_all(&target_directory).expect("test workspace directory should exist");
    let deleted_file = target_directory.join("thread_live_timeline_regression_test.dart");
    fs::write(&deleted_file, "alpha\nbeta\ngamma\n")
        .expect("deleted file fixture should be writable");

    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-delete","thread_name":"Delete file fallback","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");

    let session_path =
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-delete.jsonl");
    let entries = vec![
        json!({
            "timestamp":"2026-03-19T09:55:00Z",
            "type":"session_meta",
            "payload":{
                "id":"thread-archive-delete",
                "timestamp":"2026-03-19T09:55:00Z",
                "cwd":workspace_directory,
                "source":"cli",
                "git":{"branch":"main","repository_url":"git@github.com:example/project.git"}
            }
        }),
        json!({
            "timestamp":"2026-03-19T09:56:00Z",
            "type":"response_item",
            "payload":{
                "type":"custom_tool_call",
                "name":"apply_patch",
                "call_id":"call-delete",
                "input":format!(
                    "*** Begin Patch\n*** Delete File: {}\n*** End Patch\n",
                    deleted_file.display()
                )
            }
        }),
    ];
    let content = entries
        .into_iter()
        .map(|entry| entry.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(session_path, format!("{content}\n")).expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get("thread-archive-delete")
        .expect("timeline should exist for archived thread");
    assert_eq!(thread_timeline.len(), 1);
    assert_eq!(thread_timeline[0].event_type, "file_change_delta");
    assert_eq!(
        thread_timeline[0]
            .data
            .get("resolved_unified_diff")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        format!(
            "diff --git a/{path} b/{path}\n--- a/{path}\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-alpha\n-beta\n-gamma",
            path = deleted_file.display()
        )
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archived_sessions_hide_internal_messages_and_deduplicate_assistant_text() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-filtered","thread_name":"Filter internal records","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-filtered.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-filtered","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<collaboration_mode>Default</collaboration_mode>"}]}}"#,
            "\n",
            r##"{"timestamp":"2026-03-19T09:56:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/test/workspace"}]}}"##,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:01.250Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<shell>zsh</shell>\n<current_date>2026-03-21</current_date>\n<timezone>Europe/Prague</timezone>\n</environment_context>"}]}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:01.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the duplicated thread messages.\n"}]}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:02Z","type":"event_msg","payload":{"type":"user_message","message":"Fix the duplicated thread messages.\n"}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Tracing the archive parser now."}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tracing the archive parser now."}]}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:05Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get("thread-archive-filtered")
        .expect("timeline should exist for archived thread");

    assert_eq!(thread_timeline.len(), 3);
    assert_eq!(thread_timeline[0].event_type, "agent_message_delta");
    assert_eq!(
        thread_timeline[0]
            .data
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "userMessage"
    );
    assert_eq!(thread_timeline[1].event_type, "agent_message_delta");
    assert_eq!(
        thread_timeline[1]
            .data
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "assistant"
    );
    assert_eq!(thread_timeline[2].event_type, "command_output_delta");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archived_sessions_keep_visible_user_messages_when_event_msg_is_missing() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-legacy","thread_name":"Legacy archive session","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-legacy.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-legacy","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain the reconnect issue.\n"}]}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tracing the reconnect path."}]}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get("thread-archive-legacy")
        .expect("timeline should exist for archived thread");

    assert_eq!(thread_timeline.len(), 2);
    assert_eq!(thread_timeline[0].data["type"], "userMessage");
    assert_eq!(thread_timeline[1].data["type"], "agentMessage");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archive_loader_can_fetch_requested_thread_outside_latest_archive_window() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");

    let mut session_index_entries = Vec::new();
    for index in 0..12 {
        let thread_id = if index == 11 {
            "thread-target".to_string()
        } else {
            format!("thread-{index}")
        };
        session_index_entries.push(format!(
            "{{\"id\":\"{thread_id}\",\"thread_name\":\"Thread {index}\",\"updated_at\":\"2026-03-19T10:{index:02}:00Z\"}}"
        ));

        fs::write(
            sessions_directory.join(format!(
                "rollout-2026-03-19T10-{index:02}-00-{thread_id}.jsonl"
            )),
            format!(
                "{{\"timestamp\":\"2026-03-19T10:{index:02}:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{thread_id}\",\"timestamp\":\"2026-03-19T10:{index:02}:00Z\",\"cwd\":\"/Users/test/workspace\",\"source\":\"cli\",\"git\":{{\"branch\":\"main\",\"repository_url\":\"git@github.com:example/project.git\"}}}}}}\n\
{{\"timestamp\":\"2026-03-19T10:{index:02}:30Z\",\"type\":\"response_item\",\"payload\":{{\"type\":\"function_call_output\",\"output\":\"Command: echo target-{index}\\nOutput:\\ntarget-{index}\"}}}}\n",
            ),
        )
        .expect("session log should be writable");
    }

    fs::write(
        codex_home.join("session_index.jsonl"),
        session_index_entries.join("\n"),
    )
    .expect("session index should be writable");

    let requested_ids = HashSet::from(["thread-target".to_string()]);
    let (_, timeline_by_thread_id) =
        super::load_thread_snapshot_from_codex_archive_for_ids(&codex_home, Some(&requested_ids))
            .expect("requested archive snapshot should load");

    let timeline = timeline_by_thread_id
        .get("thread-target")
        .expect("requested thread timeline should be present");
    assert_eq!(timeline.len(), 1);
    assert_eq!(timeline[0].event_type, "command_output_delta");
    assert!(
        timeline[0]
            .data
            .get("output")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .contains("target-11")
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archive_loader_can_fetch_requested_thread_when_session_index_entry_is_missing() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/21");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");

    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-indexed","thread_name":"Indexed thread","updated_at":"2026-03-21T07:00:00Z"}"#,
    )
    .expect("session index should be writable");

    let requested_id = "thread-missing-index";
    fs::write(
        sessions_directory.join(format!("rollout-2026-03-21T07-13-12-{requested_id}.jsonl")),
        concat!(
            r#"{"timestamp":"2026-03-21T07:13:27.058Z","type":"session_meta","payload":{"id":"thread-missing-index","timestamp":"2026-03-21T07:13:12.714Z","cwd":"/Users/test/workspace","source":"cli"}}"#,
            "\n",
            r#"{"timestamp":"2026-03-21T07:13:45.894Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            "\n",
            r#"{"timestamp":"2026-03-21T07:13:46.936Z","type":"response_item","payload":{"type":"function_call_output","output":"Command: /bin/zsh -lc 'pwd'\nOutput:\n/Users/test/workspace"}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let requested_ids = HashSet::from([requested_id.to_string()]);
    let (records, timeline_by_thread_id) =
        super::load_thread_snapshot_from_codex_archive_for_ids(&codex_home, Some(&requested_ids))
            .expect("requested archive snapshot should load");

    assert_eq!(records.len(), 1);
    assert_eq!(records[0].id, requested_id);
    let timeline = timeline_by_thread_id
        .get(requested_id)
        .expect("requested thread timeline should be present");
    assert_eq!(timeline.len(), 2);
    assert_eq!(timeline[0].event_type, "command_output_delta");
    assert_eq!(timeline[1].event_type, "command_output_delta");
    assert_eq!(
        timeline[0]
            .data
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "exec_command"
    );
    assert!(
        timeline[1]
            .data
            .get("output")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .contains("/Users/test/workspace")
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
#[ignore]
fn debug_local_archive_thread_event_mix() {
    let codex_home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .expect("HOME should be set")
        .join(".codex");
    let thread_id = std::env::var("CODEX_DEBUG_THREAD_ID")
        .unwrap_or_else(|_| "019d0b18-30e3-7240-9e27-e6766967d061".to_string());
    let requested_ids = HashSet::from([thread_id.clone()]);
    let (_, timeline_by_thread_id) =
        super::load_thread_snapshot_from_codex_archive_for_ids(&codex_home, Some(&requested_ids))
            .expect("archive snapshot should load");

    let timeline = timeline_by_thread_id
        .get(&thread_id)
        .expect("timeline should exist");
    let mut counts = HashMap::new();
    for event in timeline {
        *counts.entry(event.event_type.clone()).or_insert(0usize) += 1;
    }
    eprintln!("timeline count={} counts={counts:?}", timeline.len());
    let latest_page = timeline.iter().rev().take(80).cloned().collect::<Vec<_>>();
    let mut latest_counts = HashMap::new();
    for event in latest_page.iter().rev() {
        *latest_counts
            .entry(event.event_type.clone())
            .or_insert(0usize) += 1;
    }
    eprintln!(
        "latest_page_count={} counts={latest_counts:?}",
        latest_page.len()
    );
    for event in latest_page.iter().take(15) {
        eprintln!(
            "latest page event: {} {}",
            event.event_type, event.summary_text
        );
    }
    for event in timeline
        .iter()
        .filter(|event| event.event_type != "agent_message_delta")
        .take(5)
    {
        eprintln!(
            "non-message event: {} {}",
            event.event_type, event.summary_text
        );
    }
}

#[test]
#[ignore]
fn debug_live_snapshot_thread_event_mix() {
    let thread_id = std::env::var("CODEX_DEBUG_THREAD_ID")
        .unwrap_or_else(|_| "019d0b18-30e3-7240-9e27-e6766967d061".to_string());
    let service =
        ThreadApiService::from_codex_app_server("/Users/lubomirmolin/.bun/bin/codex", &[], None)
            .expect("live snapshot should load");
    let timeline = service
        .timeline_by_thread_id
        .get(&thread_id)
        .expect("timeline should exist");
    let mut counts = HashMap::new();
    for event in timeline {
        *counts.entry(event.event_type.clone()).or_insert(0usize) += 1;
    }
    eprintln!("live snapshot count={} counts={counts:?}", timeline.len());
    let latest_page = timeline.iter().rev().take(80).cloned().collect::<Vec<_>>();
    let mut latest_counts = HashMap::new();
    for event in latest_page.iter().rev() {
        *latest_counts
            .entry(event.event_type.clone())
            .or_insert(0usize) += 1;
    }
    eprintln!(
        "live latest_page_count={} counts={latest_counts:?}",
        latest_page.len()
    );
    for event in latest_page.iter().take(15) {
        eprintln!(
            "live latest page event: {} {}",
            event.event_type, event.summary_text
        );
    }
    for event in timeline
        .iter()
        .filter(|event| event.event_type != "agent_message_delta")
        .take(5)
    {
        eprintln!(
            "live non-message event: {} {}",
            event.event_type, event.summary_text
        );
    }
}

#[test]
fn merge_thread_snapshots_supplements_rpc_with_archive_tool_events() {
    let rpc_snapshot = (
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Inspect snapshot merge".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Inspecting".to_string(),
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-user".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Check the timeline".to_string(),
                    data: json!({"type": "userMessage", "content": [{"text": "Check the timeline"}]}),
                },
                UpstreamTimelineEvent {
                    id: "evt-agent".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:02:00Z".to_string(),
                    summary_text: "Tracing now".to_string(),
                    data: json!({"type": "agentMessage", "text": "Tracing now"}),
                },
            ],
        )]),
    );
    let archive_snapshot = (
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Inspect snapshot merge".to_string(),
            lifecycle_state: "done".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:07:00Z".to_string(),
            source: "archive".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Edited files".to_string(),
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "archive-user".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Check the timeline".to_string(),
                    data: json!({"type": "userMessage", "content": [{"text": "Check the timeline"}]}),
                },
                UpstreamTimelineEvent {
                    id: "archive-file-change".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:03:00Z".to_string(),
                    summary_text: "Edited files via apply_patch".to_string(),
                    data: json!({
                        "change": "*** Begin Patch\n*** Update File: /workspace/codex-mobile-companion/lib/main.dart\n*** End Patch",
                        "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart",
                    }),
                },
            ],
        )]),
    );

    let (_, timeline_by_thread_id) = super::merge_thread_snapshots(rpc_snapshot, archive_snapshot);
    let timeline = timeline_by_thread_id
        .get("thread-123")
        .expect("merged timeline should exist");

    assert_eq!(timeline.len(), 3);
    assert_eq!(timeline[0].id, "archive-user");
    assert_eq!(timeline[1].id, "evt-agent");
    assert_eq!(timeline[2].id, "archive-file-change");
    assert_eq!(timeline[2].event_type, "file_change_delta");
    assert_eq!(
        timeline[2].data["resolved_unified_diff"],
        "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart"
    );
}

#[test]
fn merge_thread_snapshots_deduplicates_archive_and_rpc_command_and_file_change_candidates() {
    let rpc_snapshot = (
        vec![UpstreamThreadRecord {
            id: "thread-merge-dedupe".to_string(),
            headline: "Inspect dedupe".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Inspecting".to_string(),
        }],
        HashMap::from([(
            "thread-merge-dedupe".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "rpc-command".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Called exec_command".to_string(),
                    data: json!({
                        "id": "tool-1",
                        "type": "functionCall",
                        "name": "exec_command",
                        "command": "exec_command",
                        "arguments": {"cmd": "pwd"},
                    }),
                },
                UpstreamTimelineEvent {
                    id: "rpc-file-change".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:02:00Z".to_string(),
                    summary_text: "Edited files via apply_patch".to_string(),
                    data: json!({
                        "id": "tool-2",
                        "type": "customToolCall",
                        "name": "apply_patch",
                        "command": "apply_patch",
                        "input": "*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n",
                        "change": "*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "rpc-file-output".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:03:00Z".to_string(),
                    summary_text: "Success. Updated the following files: M lib/main.dart"
                        .to_string(),
                    data: json!({
                        "id": "tool-3",
                        "type": "customToolCallOutput",
                        "status": "completed",
                        "output": "Success. Updated the following files:\nM lib/main.dart\n",
                    }),
                },
            ],
        )]),
    );

    let archive_snapshot = (
        vec![UpstreamThreadRecord {
            id: "thread-merge-dedupe".to_string(),
            headline: "Inspect dedupe".to_string(),
            lifecycle_state: "done".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "archive".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Edited files".to_string(),
        }],
        HashMap::from([(
            "thread-merge-dedupe".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "archive-command".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Called exec_command".to_string(),
                    data: json!({
                        "command": "exec_command",
                        "arguments": {"cmd": "pwd"},
                    }),
                },
                UpstreamTimelineEvent {
                    id: "archive-file-change".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:02:00Z".to_string(),
                    summary_text: "Edited files via apply_patch".to_string(),
                    data: json!({
                        "command": "apply_patch",
                        "change": "*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n",
                        "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "archive-file-output".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:03:00Z".to_string(),
                    summary_text: "Success. Updated the following files: M lib/main.dart"
                        .to_string(),
                    data: json!({
                        "output": "Success. Updated the following files:\nM lib/main.dart\n",
                    }),
                },
            ],
        )]),
    );

    let (_, timeline_by_thread_id) = super::merge_thread_snapshots(rpc_snapshot, archive_snapshot);
    let timeline = timeline_by_thread_id
        .get("thread-merge-dedupe")
        .expect("merged timeline should exist");

    assert_eq!(timeline.len(), 3);
    assert_eq!(timeline[0].id, "archive-command");
    assert_eq!(timeline[1].id, "archive-file-change");
    assert_eq!(timeline[2].id, "archive-file-output");
    assert_eq!(timeline[1].event_type, "file_change_delta");
    assert_eq!(timeline[2].event_type, "file_change_delta");
    assert_eq!(
        timeline[1].data["resolved_unified_diff"],
        "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart"
    );
    assert_eq!(
        timeline[2].data["output"],
        "Success. Updated the following files:\nM lib/main.dart\n"
    );
}

#[test]
fn merge_thread_snapshots_prefers_fresher_archive_metadata_for_real_thread_detail_parity() {
    let thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let rpc_snapshot = (
        vec![UpstreamThreadRecord {
            id: thread_id.to_string(),
            headline: "Delegate subagents to fix tests".to_string(),
            lifecycle_state: "idle".to_string(),
            workspace_path: "/Users/lubomirmolin/PhpstormProjects/wrong-workspace".to_string(),
            repository_name: "wrong-workspace".to_string(),
            branch_name: "feature/wrong-thread".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-20T20:59:45.000Z".to_string(),
            updated_at: "2026-03-20T21:40:09.000Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "can you help me debug why the threads detail is very spotty?"
                .to_string(),
        }],
        HashMap::from([(
            thread_id.to_string(),
            vec![UpstreamTimelineEvent {
                id: "rpc-last-event".to_string(),
                event_type: "command_output_delta".to_string(),
                happened_at: "2026-03-20T21:40:09.000Z".to_string(),
                summary_text: "Command: /bin/zsh -lc pgrep".to_string(),
                data: json!({"command": "pgrep -fal bridge-server"}),
            }],
        )]),
    );

    let archive_snapshot = (
        vec![UpstreamThreadRecord {
            id: thread_id.to_string(),
            headline: "Investigate thread detail sync".to_string(),
            lifecycle_state: "done".to_string(),
            workspace_path: "/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion"
                .to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "master".to_string(),
            remote_name: "local".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-20T20:59:45.512Z".to_string(),
            updated_at: "2026-03-20T21:04:34.235Z".to_string(),
            source: "vscode".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "kill all old servers or apps".to_string(),
        }],
        HashMap::from([(
            thread_id.to_string(),
            vec![UpstreamTimelineEvent {
                id: format!("{thread_id}-archive-2"),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-20T21:40:09.107Z".to_string(),
                summary_text: "All of the old local app/server processes are down.".to_string(),
                data: json!({"delta": "All of the old local app/server processes are down.", "role": "assistant"}),
            }],
        )]),
    );

    let (records, timeline_by_thread_id) =
        super::merge_thread_snapshots(rpc_snapshot, archive_snapshot);

    let merged_record = records
        .iter()
        .find(|record| record.id == thread_id)
        .expect("merged thread record should exist");
    assert_eq!(merged_record.headline, "Investigate thread detail sync");
    assert_eq!(
        merged_record.workspace_path,
        "/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion"
    );
    assert_eq!(merged_record.repository_name, "codex-mobile-companion");
    assert_eq!(merged_record.branch_name, "master");
    assert_eq!(merged_record.source, "vscode");
    assert_eq!(merged_record.lifecycle_state, "done");
    assert_eq!(
        merged_record.last_turn_summary,
        "All of the old local app/server processes are down."
    );
    assert_eq!(merged_record.updated_at, "2026-03-20T21:40:09.107Z");

    let detail = super::map_thread_detail(merged_record);
    assert_eq!(detail.status, ThreadStatus::Completed);
    assert_eq!(
        detail.last_turn_summary,
        "All of the old local app/server processes are down."
    );
    assert_eq!(detail.updated_at, "2026-03-20T21:40:09.107Z");

    let timeline = timeline_by_thread_id
        .get(thread_id)
        .expect("merged timeline should exist");
    assert_eq!(timeline.len(), 2);
    assert_eq!(timeline[1].id, format!("{thread_id}-archive-2"));
}

#[test]
fn sync_thread_from_upstream_refreshes_only_requested_thread() {
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
                id: "thread-target".to_string(),
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
                id: "thread-other".to_string(),
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
                "thread-target".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "stale-target-event".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:00:00Z".to_string(),
                    summary_text: "stale target event".to_string(),
                    data: json!({"delta": "stale target event", "role": "assistant"}),
                }],
            ),
            (
                "thread-other".to_string(),
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
        .sync_thread_from_upstream("thread-target")
        .expect("thread sync should fall back to archive");

    let refreshed_target = service
        .thread_records
        .iter()
        .find(|thread| thread.id == "thread-target")
        .expect("target thread should remain present");
    assert_eq!(refreshed_target.headline, "Fresh target title");
    assert_eq!(refreshed_target.last_turn_summary, "Fresh target body.");

    let untouched_other = service
        .thread_records
        .iter()
        .find(|thread| thread.id == "thread-other")
        .expect("other thread should remain present");
    assert_eq!(untouched_other.headline, "Unrelated thread");
    assert_eq!(untouched_other.last_turn_summary, "other summary");

    let target_timeline = service
        .timeline_by_thread_id
        .get("thread-target")
        .expect("target timeline should exist");
    assert_eq!(target_timeline.len(), 1);
    assert_eq!(target_timeline[0].summary_text, "Fresh target body.");

    let other_timeline = service
        .timeline_by_thread_id
        .get("thread-other")
        .expect("other timeline should still exist");
    assert_eq!(other_timeline.len(), 1);
    assert_eq!(other_timeline[0].id, "other-event");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_reuses_fresh_snapshot_for_detail_then_timeline_pair() {
    let thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        thread_id,
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
        .sync_thread_from_upstream(thread_id)
        .expect("initial cold sync should load archive snapshot");

    let receipt_before = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("thread receipt should exist after initial sync")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(thread_id)
        .expect("immediate companion sync should succeed");

    let receipt_after = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("thread receipt should remain after companion sync")
        .synced_at_millis;
    assert_eq!(
        receipt_after, receipt_before,
        "immediate detail/timeline companion request should stay on the same warm generation"
    );

    let detail = service
        .detail_response(thread_id)
        .expect("thread detail should remain present");
    assert_eq!(detail.thread.title, "Cold snapshot title");
    assert_eq!(detail.thread.updated_at, "2026-03-19T10:00:00Z");

    let timeline = service
        .timeline_page_response(thread_id, None, 80)
        .expect("timeline should remain available");
    assert_eq!(timeline.thread.title, "Cold snapshot title");
    assert_eq!(timeline.thread.updated_at, "2026-03-19T10:00:00Z");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_reuses_single_refresh_generation_for_reconnect_style_pair() {
    let thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        thread_id,
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
        .sync_thread_from_upstream(thread_id)
        .expect("initial sync should load first snapshot");

    let first_receipt_before = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("receipt should exist after initial sync")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(thread_id)
        .expect("timeline companion request should succeed");
    let first_receipt_after = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("receipt should remain after companion sync")
        .synced_at_millis;
    assert_eq!(
        first_receipt_after, first_receipt_before,
        "unchanged reconnect-style companion request should reuse the warm generation"
    );
    assert_eq!(
        service
            .detail_response(thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Initial title"
    );

    if let Some(receipt) = service.thread_sync_receipts_by_id.get_mut(thread_id) {
        receipt.synced_at_millis = super::current_unix_epoch_millis()
            .saturating_sub(super::THREAD_SYNC_REUSE_WINDOW_MILLIS + 1);
    }

    write_archived_thread_fixture(
        &codex_home,
        thread_id,
        "2026-03-19T10:30:00Z",
        "Reconnect title",
        "Reconnect refresh summary.",
    );

    service
        .sync_thread_from_upstream(thread_id)
        .expect("reconnect detail request should refresh from archive");
    assert_eq!(
        service
            .detail_response(thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Reconnect title"
    );

    let second_receipt_before = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("receipt should exist after reconnect refresh")
        .synced_at_millis;

    service
        .sync_thread_from_upstream(thread_id)
        .expect("reconnect timeline companion request should succeed");
    let second_receipt_after = service
        .thread_sync_receipts_by_id
        .get(thread_id)
        .expect("receipt should remain after reconnect companion")
        .synced_at_millis;
    assert_eq!(
        second_receipt_after, second_receipt_before,
        "reconnect-style detail/timeline pair should share a single warm generation"
    );
    assert_eq!(
        service
            .detail_response(thread_id)
            .expect("detail should stay present")
            .thread
            .title,
        "Reconnect title"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_keeps_fast_path_for_same_thread_after_interleaved_read() {
    let canonical_thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let interleaved_thread_id = "thread-other";
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixtures(
        &codex_home,
        &[
            (
                canonical_thread_id,
                "2026-03-19T10:00:00Z",
                "Canonical title",
                "Canonical summary.",
            ),
            (
                interleaved_thread_id,
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
        .sync_thread_from_upstream(canonical_thread_id)
        .expect("initial sync should load canonical thread snapshot");

    let canonical_receipt_before = service
        .thread_sync_receipts_by_id
        .get(canonical_thread_id)
        .expect("canonical sync receipt should exist")
        .synced_at_millis;

    // This delay intentionally exceeds the old 250ms warm window while still
    // representing an immediate user-level interleaved read sequence.
    std::thread::sleep(std::time::Duration::from_millis(350));

    service
        .sync_thread_from_upstream(interleaved_thread_id)
        .expect("interleaved thread sync should succeed");
    service
        .sync_thread_from_upstream(canonical_thread_id)
        .expect("revisited canonical thread sync should succeed");

    let canonical_receipt_after = service
        .thread_sync_receipts_by_id
        .get(canonical_thread_id)
        .expect("canonical sync receipt should still exist")
        .synced_at_millis;

    assert_eq!(
        canonical_receipt_after, canonical_receipt_before,
        "canonical thread should stay on the warm fast path after interleaving another thread"
    );
    assert_eq!(
        service
            .detail_response(canonical_thread_id)
            .expect("canonical detail should remain available")
            .thread
            .title,
        "Canonical title"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn sync_thread_from_upstream_invalidates_fast_path_when_archive_index_changes() {
    let thread_id = "019d0d0c-07df-7632-81fa-a1636651400a";
    let codex_home = unique_test_codex_home();

    write_archived_thread_fixture(
        &codex_home,
        thread_id,
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
        .sync_thread_from_upstream(thread_id)
        .expect("initial sync should load first snapshot");

    std::thread::sleep(std::time::Duration::from_millis(5));

    write_archived_thread_fixture(
        &codex_home,
        thread_id,
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

    if let Some(receipt) = service.thread_sync_receipts_by_id.get_mut(thread_id) {
        receipt.synced_at_millis = super::current_unix_epoch_millis();
    }

    service
        .sync_thread_from_upstream(thread_id)
        .expect("sync after archive update should succeed");

    assert_eq!(
        service
            .detail_response(thread_id)
            .expect("detail should remain present")
            .thread
            .title,
        "Updated title",
        "archive index updates should invalidate the warm fast path"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn reconcile_snapshot_publishes_status_and_new_timeline_events() {
    let mut service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Running".to_string(),
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-existing".to_string(),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-17T10:05:00Z".to_string(),
                summary_text: "Existing assistant output".to_string(),
                data: json!({"delta": "existing"}),
            }],
        )]),
    );

    let events = service.reconcile_snapshot(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "done".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:06:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Completed".to_string(),
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-existing".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:05:00Z".to_string(),
                    summary_text: "Existing assistant output".to_string(),
                    data: json!({"delta": "existing"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-new".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:30Z".to_string(),
                    summary_text: "New command output".to_string(),
                    data: json!({"command": "pwd", "delta": "/workspace"}),
                },
            ],
        )]),
    );

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].kind, BridgeEventKind::ThreadStatusChanged);
    assert_eq!(events[0].payload["status"], "completed");
    assert_eq!(events[1].event_id, "evt-new");
    assert_eq!(events[1].kind, BridgeEventKind::CommandDelta);
}

#[test]
fn reconcile_snapshot_preserves_live_only_events_missing_from_snapshot() {
    let thread = UpstreamThreadRecord {
        id: "thread-123".to_string(),
        headline: "Inspect reconcile merge".to_string(),
        lifecycle_state: "active".to_string(),
        workspace_path: "/workspace/codex-mobile-companion".to_string(),
        repository_name: "codex-mobile-companion".to_string(),
        branch_name: "main".to_string(),
        remote_name: "origin".to_string(),
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: "2026-03-17T10:00:00Z".to_string(),
        updated_at: "2026-03-17T10:05:00Z".to_string(),
        source: "cli".to_string(),
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: "Inspecting".to_string(),
    };
    let mut service = ThreadApiService::with_seed_data(
        vec![thread.clone()],
        HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-message".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:01:00Z".to_string(),
                    summary_text: "Tracing now".to_string(),
                    data: json!({"type": "agentMessage", "text": "Tracing now"}),
                },
                UpstreamTimelineEvent {
                    id: "evt-file-change".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:02:00Z".to_string(),
                    summary_text: "Edited lib/main.dart".to_string(),
                    data: json!({
                        "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart",
                    }),
                },
            ],
        )]),
    );

    let events = service.reconcile_snapshot(
        vec![UpstreamThreadRecord {
            updated_at: "2026-03-17T10:06:00Z".to_string(),
            ..thread
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-message".to_string(),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-17T10:01:00Z".to_string(),
                summary_text: "Tracing now".to_string(),
                data: json!({"type": "agentMessage", "text": "Tracing now"}),
            }],
        )]),
    );

    assert!(events.is_empty());

    let timeline = service
        .timeline_page_response("thread-123", None, 50)
        .expect("timeline response should exist");
    assert_eq!(timeline.entries.len(), 2);
    assert_eq!(timeline.entries[1].kind, BridgeEventKind::FileChange);
    assert_eq!(
        timeline.entries[1].payload["resolved_unified_diff"],
        "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart"
    );
}

#[test]
fn reconcile_snapshot_does_not_republish_existing_events() {
    let thread = UpstreamThreadRecord {
        id: "thread-123".to_string(),
        headline: "Investigate bridge sync".to_string(),
        lifecycle_state: "active".to_string(),
        workspace_path: "/workspace/codex-mobile-companion".to_string(),
        repository_name: "codex-mobile-companion".to_string(),
        branch_name: "main".to_string(),
        remote_name: "origin".to_string(),
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: "2026-03-17T10:00:00Z".to_string(),
        updated_at: "2026-03-17T10:05:00Z".to_string(),
        source: "cli".to_string(),
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: "Running".to_string(),
    };
    let timeline = HashMap::from([(
        "thread-123".to_string(),
        vec![UpstreamTimelineEvent {
            id: "evt-existing".to_string(),
            event_type: "agent_message_delta".to_string(),
            happened_at: "2026-03-17T10:05:00Z".to_string(),
            summary_text: "Existing assistant output".to_string(),
            data: json!({"delta": "existing"}),
        }],
    )]);
    let mut service = ThreadApiService::with_seed_data(vec![thread.clone()], timeline.clone());

    let events = service.reconcile_snapshot(vec![thread], timeline);

    assert!(events.is_empty());
}

#[test]
fn reconcile_snapshot_republishes_changed_events_with_stable_upstream_ids() {
    let thread = UpstreamThreadRecord {
        id: "thread-123".to_string(),
        headline: "Investigate bridge sync".to_string(),
        lifecycle_state: "active".to_string(),
        workspace_path: "/workspace/codex-mobile-companion".to_string(),
        repository_name: "codex-mobile-companion".to_string(),
        branch_name: "main".to_string(),
        remote_name: "origin".to_string(),
        git_dirty: false,
        git_ahead_by: 0,
        git_behind_by: 0,
        created_at: "2026-03-17T10:00:00Z".to_string(),
        updated_at: "2026-03-17T10:05:00Z".to_string(),
        source: "cli".to_string(),
        approval_mode: "control_with_approvals".to_string(),
        last_turn_summary: "Streaming".to_string(),
    };
    let mut service = ThreadApiService::with_seed_data(
        vec![thread.clone()],
        HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-streaming-message".to_string(),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-17T10:05:00Z".to_string(),
                summary_text: "Hel".to_string(),
                data: json!({
                    "type": "agentMessage",
                    "text": "Hel",
                }),
            }],
        )]),
    );

    let events = service.reconcile_snapshot(
        vec![UpstreamThreadRecord {
            updated_at: "2026-03-17T10:05:02Z".to_string(),
            ..thread
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-streaming-message".to_string(),
                event_type: "agent_message_delta".to_string(),
                happened_at: "2026-03-17T10:05:02Z".to_string(),
                summary_text: "Hello from the streamed update".to_string(),
                data: json!({
                    "type": "agentMessage",
                    "text": "Hello from the streamed update",
                }),
            }],
        )]),
    );

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_id, "evt-streaming-message");
    assert_eq!(events[0].kind, BridgeEventKind::MessageDelta);
    assert_eq!(events[0].payload["text"], "Hello from the streamed update");
}

#[test]
fn codex_notification_normalizer_accumulates_agent_message_deltas() {
    let mut normalizer = CodexNotificationNormalizer::default();

    assert!(
        normalizer
            .normalize(
                "turn/started",
                &json!({
                    "threadId": "thread-123",
                    "turn": {
                        "id": "turn-123",
                        "status": "inProgress",
                        "items": [],
                    }
                }),
            )
            .is_none()
    );
    assert!(
        normalizer
            .normalize(
                "thread/realtime/itemAdded",
                &json!({
                    "threadId": "thread-123",
                    "item": {
                        "id": "msg-1",
                        "type": "agentMessage",
                        "text": "",
                    }
                }),
            )
            .is_none()
    );

    let first = normalizer
        .normalize(
            "item/agentMessage/delta",
            &json!({
                "delta": "Hel",
                "itemId": "msg-1",
                "threadId": "thread-123",
                "turnId": "turn-123",
            }),
        )
        .expect("first delta should produce an event");
    assert_eq!(first.event_id, "turn-123-msg-1");
    assert_eq!(first.payload["text"], "Hel");

    let second = normalizer
        .normalize(
            "item/agentMessage/delta",
            &json!({
                "delta": "lo",
                "itemId": "msg-1",
                "threadId": "thread-123",
                "turnId": "turn-123",
            }),
        )
        .expect("second delta should produce an event");
    assert_eq!(second.event_id, "turn-123-msg-1");
    assert_eq!(second.payload["text"], "Hello");
}

#[test]
fn codex_notification_normalizer_maps_custom_tool_item_added_to_file_change() {
    let mut normalizer = CodexNotificationNormalizer::default();

    let event = normalizer
        .normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "tool-1",
                    "type": "customToolCall",
                    "name": "apply_patch",
                    "input": "*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n",
                }
            }),
        )
        .expect("custom tool call should produce a file change event");

    assert_eq!(event.kind, BridgeEventKind::FileChange);
    assert_eq!(event.payload["command"], "apply_patch");
    assert!(
        event.payload["change"]
            .as_str()
            .unwrap_or_default()
            .contains("*** Update File: lib/main.dart")
    );
}

#[test]
fn codex_notification_normalizer_adds_exploration_annotations_for_tool_invocations() {
    let mut normalizer = CodexNotificationNormalizer::default();

    assert!(
        normalizer
            .normalize(
                "turn/started",
                &json!({
                    "threadId": "thread-123",
                    "turn": {
                        "id": "turn-123",
                        "status": "inProgress",
                        "items": [],
                    }
                }),
            )
            .is_none()
    );

    let event = normalizer
        .normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "tool-1",
                    "type": "functionCall",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"rg -n websocket crates/bridge-core/src/thread_api.rs\"}"
                }
            }),
        )
        .expect("tool invocation should produce a command event");

    let annotations = event
        .annotations
        .as_ref()
        .expect("live command event should include annotations");
    assert_eq!(
        annotations.group_kind,
        Some(ThreadTimelineGroupKind::Exploration)
    );
    assert_eq!(
        annotations.group_id.as_deref(),
        Some("exploration:turn-123")
    );
    assert_eq!(
        annotations.exploration_kind,
        Some(ThreadTimelineExplorationKind::Search)
    );
    assert_eq!(annotations.entry_label.as_deref(), Some("Search"));
    assert!(event.payload.get("presentation").is_none());
}

#[test]
fn codex_notification_normalizer_maps_custom_tool_output_deltas() {
    let mut normalizer = CodexNotificationNormalizer::default();

    let event = normalizer
        .normalize(
            "item/customToolCallOutput/outputDelta",
            &json!({
                "delta": "Success. Updated the following files:\nM lib/main.dart\n",
                "itemId": "tool-2",
                "threadId": "thread-123",
                "turnId": "turn-123",
            }),
        )
        .expect("custom tool output delta should produce an event");

    assert_eq!(event.kind, BridgeEventKind::FileChange);
    assert_eq!(
        event.payload["output"],
        "Success. Updated the following files:\nM lib/main.dart\n"
    );
}

#[test]
fn timeline_page_response_adds_exploration_annotations_for_background_commands() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Reading files".to_string(),
        }],
        HashMap::from([(
            "thread-123".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-read".to_string(),
                event_type: "command_output_delta".to_string(),
                happened_at: "2026-03-17T10:01:00Z".to_string(),
                summary_text: "Background terminal finished".to_string(),
                data: json!({
                    "output": "Command: sed -n '1,120p' apps/mobile/lib/features/threads/domain/parsed_command_output.dart\nOutput:\nBackground terminal finished with sed -n '1,120p' apps/mobile/lib/features/threads/domain/parsed_command_output.dart",
                }),
            }],
        )]),
    );

    let page = service
        .timeline_page_response("thread-123", None, 50)
        .expect("timeline page should exist");

    let annotations = page.entries[0]
        .annotations
        .as_ref()
        .expect("background command should include annotations");
    assert_eq!(
        annotations.group_kind,
        Some(ThreadTimelineGroupKind::Exploration)
    );
    assert_eq!(
        annotations.exploration_kind,
        Some(ThreadTimelineExplorationKind::Read)
    );
    assert_eq!(
        annotations.entry_label.as_deref(),
        Some("Read parsed_command_output.dart")
    );
    assert!(page.entries[0].payload.get("presentation").is_none());
}

#[test]
fn codex_notification_normalizer_keeps_exploration_annotations_on_command_output_deltas() {
    let mut normalizer = CodexNotificationNormalizer::default();

    assert!(
        normalizer
            .normalize(
                "turn/started",
                &json!({
                    "threadId": "thread-123",
                    "turn": {
                        "id": "turn-123",
                        "status": "inProgress",
                        "items": [],
                    }
                }),
            )
            .is_none()
    );
    let _ = normalizer.normalize(
        "thread/realtime/itemAdded",
        &json!({
            "threadId": "thread-123",
            "item": {
                "id": "cmd-1",
                "type": "commandExecution",
                "command": "rg -n \"thread-detail\" apps/mobile/lib/features/threads",
                "aggregatedOutput": "",
                "output": "",
            }
        }),
    );

    let event = normalizer
        .normalize(
            "item/commandExecution/outputDelta",
            &json!({
                "delta": "apps/mobile/lib/features/threads/presentation/thread_detail_page.dart:143: _maybeAutoLoadEarlierHistory()",
                "itemId": "cmd-1",
                "threadId": "thread-123",
                "turnId": "turn-123",
            }),
        )
        .expect("command output delta should produce an event");

    let annotations = event
        .annotations
        .as_ref()
        .expect("command output delta should keep annotations");
    assert_eq!(event.kind, BridgeEventKind::CommandDelta);
    assert_eq!(
        annotations.group_kind,
        Some(ThreadTimelineGroupKind::Exploration)
    );
    assert_eq!(
        annotations.exploration_kind,
        Some(ThreadTimelineExplorationKind::Search)
    );
    assert!(event.payload.get("presentation").is_none());
}

#[test]
fn apply_live_event_replaces_existing_timeline_entry_with_same_event_id() {
    let mut service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            headline: "Investigate bridge sync".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "control_with_approvals".to_string(),
            last_turn_summary: "Streaming".to_string(),
        }],
        HashMap::new(),
    );

    service.apply_live_event(BridgeEventEnvelope::new(
        "turn-123-msg-1",
        "thread-123",
        BridgeEventKind::MessageDelta,
        "101",
        json!({
            "id": "msg-1",
            "type": "agentMessage",
            "text": "Hel",
        }),
    ));
    service.apply_live_event(BridgeEventEnvelope::new(
        "turn-123-msg-1",
        "thread-123",
        BridgeEventKind::MessageDelta,
        "102",
        json!({
            "id": "msg-1",
            "type": "agentMessage",
            "text": "Hello",
        }),
    ));

    let timeline = service
        .timeline_page_response("thread-123", None, 50)
        .expect("timeline response should exist");
    assert_eq!(timeline.entries.len(), 1);
    assert_eq!(timeline.entries[0].event_id, "turn-123-msg-1");
    assert_eq!(timeline.entries[0].payload["text"], "Hello");

    let detail = service
        .detail_response("thread-123")
        .expect("detail response should exist");
    assert_eq!(detail.thread.updated_at, "102");
    assert_eq!(detail.thread.last_turn_summary, "Hello");
}

#[test]
fn archived_sessions_preserve_user_message_images() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-images","thread_name":"Archive message images","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-images.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-images","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"event_msg","payload":{"type":"user_message","message":"Here is the screenshot.\n","images":["data:image/png;base64,AAA"]}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get("thread-archive-images")
        .expect("timeline should exist for archived thread");

    assert_eq!(thread_timeline.len(), 1);
    assert_eq!(thread_timeline[0].data["type"], "userMessage");
    assert_eq!(
        thread_timeline[0].data["content"][0]["text"],
        "Here is the screenshot."
    );
    assert_eq!(
        thread_timeline[0].data["content"][1]["image_url"],
        "data:image/png;base64,AAA"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn codex_rpc_timeline_skips_unknown_internal_items() {
    let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
        id: "thread-123".to_string(),
        name: Some("Inspect RPC timeline".to_string()),
        preview: Some("Preview".to_string()),
        status: CodexThreadStatus {
            kind: "active".to_string(),
        },
        cwd: "/Users/test/workspace".to_string(),
        git_info: None,
        created_at: 1,
        updated_at: 2,
        source: json!("cli"),
        turns: vec![CodexTurn {
            id: "turn-123".to_string(),
            items: vec![
                json!({"id":"sys-1","type":"systemMessage","text":"<collaboration_mode>Default</collaboration_mode>"}),
                json!({"id":"user-1","type":"userMessage","content":[{"text":"Ship the fix"}]}),
                json!({"id":"assistant-1","type":"agentMessage","text":"Inspecting the issue."}),
            ],
        }],
    });

    assert_eq!(timeline.len(), 2);
    assert_eq!(timeline[0].data["type"], "userMessage");
    assert_eq!(timeline[1].data["type"], "agentMessage");
}

#[test]
fn codex_rpc_timeline_hides_internal_environment_context_messages() {
    let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
        id: "thread-123".to_string(),
        name: Some("Inspect RPC timeline".to_string()),
        preview: Some("Preview".to_string()),
        status: CodexThreadStatus {
            kind: "active".to_string(),
        },
        cwd: "/Users/test/workspace".to_string(),
        git_info: None,
        created_at: 1,
        updated_at: 2,
        source: json!("cli"),
        turns: vec![CodexTurn {
            id: "turn-123".to_string(),
            items: vec![
                json!({"id":"user-internal-1","type":"userMessage","text":"<environment_context>\n<shell>zsh</shell>\n</environment_context>"}),
                json!({"id":"user-1","type":"userMessage","text":"Ship the fix"}),
                json!({"id":"assistant-1","type":"agentMessage","text":"Inspecting the issue."}),
            ],
        }],
    });

    assert_eq!(timeline.len(), 2);
    assert_eq!(timeline[0].data["type"], "userMessage");
    assert_eq!(timeline[0].data["text"], "Ship the fix");
    assert_eq!(timeline[1].data["type"], "agentMessage");
}

#[test]
fn codex_rpc_timeline_maps_tool_calls_to_command_and_file_change_events() {
    let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
        id: "thread-123".to_string(),
        name: Some("Inspect RPC timeline".to_string()),
        preview: Some("Preview".to_string()),
        status: CodexThreadStatus {
            kind: "active".to_string(),
        },
        cwd: "/Users/test/workspace".to_string(),
        git_info: None,
        created_at: 1,
        updated_at: 2,
        source: json!("cli"),
        turns: vec![CodexTurn {
            id: "turn-123".to_string(),
            items: vec![
                json!({
                    "id":"tool-1",
                    "type":"functionCall",
                    "name":"exec_command",
                    "arguments":"{\"cmd\":\"pwd\"}"
                }),
                json!({
                    "id":"tool-2",
                    "type":"customToolCall",
                    "name":"apply_patch",
                    "input":"*** Begin Patch\n*** Update File: lib/main.dart\n@@\n-old\n+new\n*** End Patch\n"
                }),
                json!({
                    "id":"tool-3",
                    "type":"customToolCallOutput",
                    "output":"Success. Updated the following files:\nM lib/main.dart\n"
                }),
            ],
        }],
    });

    assert_eq!(timeline.len(), 3);
    assert_eq!(timeline[0].event_type, "command_output_delta");
    assert_eq!(timeline[0].data["command"], "exec_command");
    assert_eq!(timeline[1].event_type, "file_change_delta");
    assert_eq!(timeline[1].data["command"], "apply_patch");
    assert_eq!(timeline[2].event_type, "file_change_delta");
    assert_eq!(
        timeline[2].data["output"],
        "Success. Updated the following files:\nM lib/main.dart\n"
    );
}

#[test]
fn codex_rpc_timeline_prefers_item_timestamps_and_turn_fallback_over_thread_updated_at() {
    let timeline = super::map_codex_thread_to_timeline_events(&CodexThread {
        id: "thread-123".to_string(),
        name: Some("Inspect RPC timestamping".to_string()),
        preview: Some("Preview".to_string()),
        status: CodexThreadStatus {
            kind: "active".to_string(),
        },
        cwd: "/Users/test/workspace".to_string(),
        git_info: None,
        created_at: 1,
        updated_at: 1_774_042_809,
        source: json!("cli"),
        turns: vec![CodexTurn {
            id: "019d0d10-5cba-7a41-b99d-16d8da53307c".to_string(),
            items: vec![
                json!({
                    "id":"item-1",
                    "type":"userMessage",
                    "text":"Ship it",
                    "createdAt": 1_774_040_000,
                }),
                json!({
                    "id":"item-2",
                    "type":"agentMessage",
                    "text":"On it",
                }),
            ],
        }],
    });

    assert_eq!(timeline.len(), 2);
    assert_eq!(
        timeline[0].happened_at,
        super::unix_timestamp_to_iso8601(1_774_040_000)
    );
    assert_eq!(timeline[1].happened_at, "2026-03-20T21:04:29.370Z");
    assert_ne!(
        timeline[1].happened_at,
        super::unix_timestamp_to_iso8601(1_774_042_809)
    );
}

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
