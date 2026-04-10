use super::*;
use shared_contracts::ThreadGitDiffMode;

use crate::thread_api::ThreadGitDiffQuery;

#[test]
fn list_and_detail_responses_normalize_upstream_thread_shapes() {
    let thread_id = codex_thread_id("thread-abc");
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-abc".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
    assert_eq!(list.threads[0].thread_id, thread_id);
    assert_eq!(list.threads[0].status, ThreadStatus::Running);

    let detail = service
        .detail_response(&codex_thread_id("thread-abc"))
        .expect("detail response should exist");
    assert_eq!(detail.thread.access_mode, AccessMode::ReadOnly);
    assert_eq!(detail.thread.last_turn_summary, "started normalization");
}

#[test]
fn timeline_page_response_normalizes_event_kinds() {
    let thread_id = codex_thread_id("thread-abc");
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-abc".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
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
        .timeline_page_response(&thread_id, None, 50)
        .expect("timeline response should exist");

    assert_eq!(timeline.contract_version, CONTRACT_VERSION);
    assert_eq!(timeline.entries.len(), 1);
    assert_eq!(timeline.entries[0].kind, BridgeEventKind::CommandDelta);
    assert_eq!(timeline.thread.thread_id, thread_id);
}

#[test]
fn timeline_page_response_orders_same_turn_messages_before_work_for_equal_timestamps() {
    let thread_id = codex_thread_id("thread-abc");
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-abc".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
            vec![
                UpstreamTimelineEvent {
                    id: "turn-123-call-z".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Edited lib/main.dart".to_string(),
                    data: json!({
                        "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-call-a".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "command output".to_string(),
                    data: json!({ "delta": "line" }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-item-2".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Tracing now".to_string(),
                    data: json!({
                        "type": "agentMessage",
                        "role": "assistant",
                        "text": "Tracing now",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-item-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Inspect this".to_string(),
                    data: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "Inspect this",
                    }),
                },
            ],
        )]),
    );

    let timeline = service
        .timeline_page_response(&thread_id, None, 50)
        .expect("timeline response should exist");

    assert_eq!(
        timeline
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec![
            "turn-123-item-1",
            "turn-123-item-2",
            "turn-123-call-a",
            "turn-123-call-z",
        ]
    );
}

#[test]
fn timeline_page_response_does_not_split_same_turn_equal_timestamp_batches() {
    let thread_id = codex_thread_id("thread-abc");
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-abc".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
            vec![
                UpstreamTimelineEvent {
                    id: "turn-older-item-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:05:59Z".to_string(),
                    summary_text: "older".to_string(),
                    data: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "older",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-call-z".to_string(),
                    event_type: "file_change_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Edited lib/main.dart".to_string(),
                    data: json!({
                        "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-call-a".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "command output".to_string(),
                    data: json!({ "delta": "line" }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-item-2".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Tracing now".to_string(),
                    data: json!({
                        "type": "agentMessage",
                        "role": "assistant",
                        "text": "Tracing now",
                    }),
                },
                UpstreamTimelineEvent {
                    id: "turn-123-item-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "Inspect this".to_string(),
                    data: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "Inspect this",
                    }),
                },
            ],
        )]),
    );

    let newest_page = service
        .timeline_page_response(&thread_id, None, 2)
        .expect("timeline response should exist");

    assert_eq!(
        newest_page
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec![
            "turn-123-item-1",
            "turn-123-item-2",
            "turn-123-call-a",
            "turn-123-call-z",
        ]
    );
    assert_eq!(newest_page.next_before.as_deref(), Some("turn-123-item-1"));
    assert!(newest_page.has_more_before);

    let older_page = service
        .timeline_page_response(&thread_id, newest_page.next_before.as_deref(), 2)
        .expect("older page should exist");

    assert_eq!(
        older_page
            .entries
            .iter()
            .map(|entry| entry.event_id.as_str())
            .collect::<Vec<_>>(),
        vec!["turn-older-item-1"]
    );
}

#[test]
fn timeline_page_response_adds_exploration_annotations_without_mutating_payload() {
    let thread_id = codex_thread_id("thread-abc");
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-abc".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
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
        .timeline_page_response(&thread_id, None, 50)
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
            native_id: "thread-empty".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            native_id: "thread-page".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
        native_id: "thread-mixed".to_string(),
        provider: shared_contracts::ProviderKind::Codex,
        client: shared_contracts::ThreadClientKind::Cli,
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
        native_id: "thread-page-stability".to_string(),
        provider: shared_contracts::ProviderKind::Codex,
        client: shared_contracts::ThreadClientKind::Cli,
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
fn reconcile_snapshot_publishes_status_and_new_timeline_events() {
    let mut service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
        native_id: "thread-123".to_string(),
        provider: shared_contracts::ProviderKind::Codex,
        client: shared_contracts::ThreadClientKind::Cli,
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
        native_id: "thread-123".to_string(),
        provider: shared_contracts::ProviderKind::Codex,
        client: shared_contracts::ThreadClientKind::Cli,
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
        native_id: "thread-123".to_string(),
        provider: shared_contracts::ProviderKind::Codex,
        client: shared_contracts::ThreadClientKind::Cli,
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
fn timeline_page_response_adds_exploration_annotations_for_background_commands() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-123".to_string(),
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
fn apply_live_event_replaces_existing_timeline_entry_with_same_event_id() {
    let thread_id = codex_thread_id("thread-123");
    let mut service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
        &thread_id,
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
        &thread_id,
        BridgeEventKind::MessageDelta,
        "102",
        json!({
            "id": "msg-1",
            "type": "agentMessage",
            "text": "Hello",
        }),
    ));

    let timeline = service
        .timeline_page_response(&thread_id, None, 50)
        .expect("timeline response should exist");
    assert_eq!(timeline.entries.len(), 1);
    assert_eq!(timeline.entries[0].event_id, "turn-123-msg-1");
    assert_eq!(timeline.entries[0].payload["text"], "Hello");

    let detail = service
        .detail_response(&thread_id)
        .expect("detail response should exist");
    assert_eq!(detail.thread.updated_at, "102");
    assert_eq!(detail.thread.last_turn_summary, "Hello");
}

#[test]
fn git_diff_response_uses_latest_thread_change_diff_payload() {
    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-diff".to_string(),
            native_id: "thread-diff".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            headline: "Inspect diff".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: "/workspace/codex-mobile-companion".to_string(),
            repository_name: "codex-mobile-companion".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: true,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "full_control".to_string(),
            last_turn_summary: "diff".to_string(),
        }],
        HashMap::from([(
            "thread-diff".to_string(),
            vec![UpstreamTimelineEvent {
                id: "evt-diff".to_string(),
                event_type: "file_change_delta".to_string(),
                happened_at: "2026-03-17T10:06:00Z".to_string(),
                summary_text: "Updated lib/main.dart".to_string(),
                data: json!({
                    "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart\n@@ -1 +1 @@\n-old\n+new"
                }),
            }],
        )]),
    );

    let diff = service
        .git_diff_response(
            "thread-diff",
            &ThreadGitDiffQuery {
                mode: ThreadGitDiffMode::LatestThreadChange,
                path: None,
            },
        )
        .expect("git diff response should exist");

    assert_eq!(diff.mode, ThreadGitDiffMode::LatestThreadChange);
    assert_eq!(diff.files.len(), 1);
    assert_eq!(diff.files[0].path, "lib/main.dart");
    assert_eq!(diff.files[0].additions, 1);
    assert_eq!(diff.files[0].deletions, 1);
}

#[test]
fn git_diff_response_reads_workspace_diff_from_real_git_repo() {
    use std::fs;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    let temp_dir = std::env::temp_dir().join(format!(
        "thread-diff-workspace-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be valid")
            .as_millis()
    ));
    fs::create_dir_all(&temp_dir).expect("temp dir should exist");

    let git = |args: &[&str]| {
        let output = Command::new("git")
            .current_dir(&temp_dir)
            .args(args)
            .output()
            .expect("git should run");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    };

    git(&["init"]);
    git(&["config", "user.name", "Codex Test"]);
    git(&["config", "user.email", "codex@example.com"]);
    fs::write(temp_dir.join("tracked.txt"), "before\n").expect("seed file should write");
    git(&["add", "tracked.txt"]);
    git(&["commit", "-m", "initial"]);

    fs::write(temp_dir.join("tracked.txt"), "after\n").expect("tracked file should write");
    fs::write(temp_dir.join("new.txt"), "fresh\n").expect("untracked file should write");

    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-workspace".to_string(),
            native_id: "thread-workspace".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            headline: "Workspace diff".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: temp_dir.to_string_lossy().to_string(),
            repository_name: "repo".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: true,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "full_control".to_string(),
            last_turn_summary: "workspace".to_string(),
        }],
        HashMap::new(),
    );

    let diff = service
        .git_diff_response(
            "thread-workspace",
            &ThreadGitDiffQuery {
                mode: ThreadGitDiffMode::Workspace,
                path: None,
            },
        )
        .expect("workspace diff should exist");

    assert_eq!(diff.mode, ThreadGitDiffMode::Workspace);
    assert!(diff.unified_diff.contains("tracked.txt"));
    assert!(diff.unified_diff.contains("new.txt"));
    assert_eq!(diff.files.len(), 2);

    fs::remove_dir_all(&temp_dir).expect("temp dir should be removable");
}

#[test]
fn git_diff_response_returns_none_for_non_repo_workspace() {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    let temp_dir = std::env::temp_dir().join(format!(
        "thread-diff-non-repo-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be valid")
            .as_millis()
    ));
    fs::create_dir_all(&temp_dir).expect("temp dir should exist");

    let service = ThreadApiService::with_seed_data(
        vec![UpstreamThreadRecord {
            id: "thread-non-repo".to_string(),
            native_id: "thread-non-repo".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            headline: "Non repo".to_string(),
            lifecycle_state: "active".to_string(),
            workspace_path: temp_dir.to_string_lossy().to_string(),
            repository_name: "repo".to_string(),
            branch_name: "main".to_string(),
            remote_name: "origin".to_string(),
            git_dirty: false,
            git_ahead_by: 0,
            git_behind_by: 0,
            created_at: "2026-03-17T10:00:00Z".to_string(),
            updated_at: "2026-03-17T10:05:00Z".to_string(),
            source: "cli".to_string(),
            approval_mode: "full_control".to_string(),
            last_turn_summary: "workspace".to_string(),
        }],
        HashMap::new(),
    );

    let diff = service.git_diff_response(
        "thread-non-repo",
        &ThreadGitDiffQuery {
            mode: ThreadGitDiffMode::Workspace,
            path: None,
        },
    );

    assert!(diff.is_none());
    fs::remove_dir_all(&temp_dir).expect("temp dir should be removable");
}

#[test]
fn sync_thread_from_upstream_falls_back_to_full_sync_when_single_thread_load_is_empty() {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{SystemTime, UNIX_EPOCH};

    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be valid")
        .as_nanos();
    let temp_dir = std::env::temp_dir().join(format!(
        "thread-sync-full-fallback-{}-{unique}",
        std::process::id()
    ));
    fs::create_dir_all(&temp_dir).expect("temp dir should exist");

    let script_path = temp_dir.join("fake-codex.sh");
    fs::write(
        &script_path,
        r#"#!/bin/sh
if [ "$1" = "app-server" ]; then
  shift
fi
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"id":%s,"result":{}}\n' "$id"
      ;;
    *'"method":"thread/list"'*)
      printf '{"id":%s,"result":{"data":[{"id":"thread-123","name":"Thread from list","preview":"preview","status":{"type":"idle"},"cwd":"/workspace/repo","gitInfo":{"branch":"main","originUrl":"git@github.com:example/repo.git"},"createdAt":1710000000,"updatedAt":1710000300,"source":"cli","turns":[]}],"nextCursor":null}}\n' "$id"
      ;;
    *'"method":"thread/read"'*)
      printf '{"id":%s,"error":{"message":"thread not found"}}\n' "$id"
      ;;
    *'"method":"thread/resume"'*)
      printf '{"id":%s,"error":{"message":"thread not found"}}\n' "$id"
      ;;
    *)
      printf '{"id":%s,"result":{}}\n' "$id"
      ;;
  esac
done
"#,
    )
    .expect("fake codex script should be written");
    fs::set_permissions(&script_path, fs::Permissions::from_mode(0o755))
        .expect("fake codex script should be executable");

    let _env_lock = crate::test_support::lock_test_env();
    let previous_codex_home = std::env::var_os("CODEX_HOME");
    unsafe {
        std::env::set_var("CODEX_HOME", &temp_dir);
    }

    let mut service =
        ThreadApiService::from_codex_app_server(script_path.to_string_lossy().as_ref(), &[], None)
            .expect("service should load from thread/list");
    let thread_id = codex_thread_id("thread-123");
    assert!(service.detail_response(&thread_id).is_some());

    service
        .sync_thread_from_upstream(&thread_id)
        .expect("single-thread sync should fall back to full sync");

    let detail = service
        .detail_response(&thread_id)
        .expect("thread should remain available after fallback");
    assert_eq!(detail.thread.title, "Thread from list");
    assert_eq!(detail.thread.workspace, "/workspace/repo");

    match previous_codex_home {
        Some(value) => unsafe {
            std::env::set_var("CODEX_HOME", value);
        },
        None => unsafe {
            std::env::remove_var("CODEX_HOME");
        },
    }
    fs::remove_dir_all(&temp_dir).expect("temp dir should be removable");
}
