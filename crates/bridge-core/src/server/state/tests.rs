use std::fs;
use std::sync::mpsc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, PendingUserInputDto,
    ProviderKind, ThreadClientKind, ThreadDetailDto, ThreadSnapshotDto, ThreadStatus,
    ThreadSummaryDto, ThreadTimelineEntryDto, ThreadWorkflowStateDto, UserInputAnswerDto,
    UserInputOptionDto, UserInputQuestionDto,
};

use crate::pairing::PairingSessionService;
use crate::server::config::{BridgeCodexConfig, BridgeConfig};
use crate::server::gateway::GatewayTurnStreamActivity;
use crate::server::pairing_route::PairingRouteState;
use crate::server::speech::SpeechService;
use crate::server::state::snapshots::should_refresh_terminal_timeline_snapshot;
use crate::server::timeline_events::build_timeline_event_envelope;

use super::{
    BridgeAppState, GatewayTurnControlRequest, LiveDeltaCompactor, NotificationControlMessage,
    PendingProviderApprovalSession, PendingTurnClientMessage, PendingUserInputSession,
    ProviderApprovalContext, ProviderApprovalSelection, build_claude_tool_approval_response,
    build_codex_approval_response, build_desktop_ipc_snapshot_update,
    build_pending_provider_approval_from_codex, build_provider_approval_questionnaire,
    drain_notification_control_messages, ensure_running_status_for_desktop_patch_update,
    parse_provider_approval_selection, payload_contains_hidden_message,
    preserve_bootstrap_status_for_cached_desktop_snapshot,
    preserve_running_status_for_bridge_owned_desktop_update,
    resume_notification_thread_until_rollout_exists, resume_notification_threads,
    should_clear_transient_thread_state, should_defer_bridge_owned_turn_finalization,
    should_publish_compacted_event,
    should_suppress_non_running_thread_status_for_bridge_active_turn,
    should_suppress_notification_event_for_bridge_active_turn,
    watchdog_should_finalize_bridge_owned_turn,
};

async fn test_bridge_app_state() -> BridgeAppState {
    let state_directory = std::env::temp_dir().join(format!(
        "bridge-app-state-test-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos()
    ));
    fs::create_dir_all(&state_directory).expect("test state directory should exist");
    let pairing_route = PairingRouteState::new(
        "https://bridge.ts.net".to_string(),
        true,
        None,
        3210,
        false,
        state_directory.clone(),
    );
    let config = BridgeConfig {
        host: "127.0.0.1".to_string(),
        port: 3210,
        state_directory: state_directory.clone(),
        speech_helper_binary: None,
        pairing_route: pairing_route.clone(),
        codex: BridgeCodexConfig::default(),
    };
    let speech = SpeechService::from_config(&config).await;
    let state_directory = config.state_directory.clone();
    BridgeAppState::new(
        config.codex,
        PairingSessionService::new(
            &config.host,
            config.port,
            pairing_route.pairing_base_url(),
            state_directory.clone(),
        ),
        pairing_route,
        speech,
        state_directory,
    )
}

#[test]
fn hidden_payload_detection_marks_only_active_bridge_protocol_messages() {
    assert!(payload_contains_hidden_message(&json!({
        "text": "# AGENTS.md instructions for /tmp/workspace"
    })));
    assert!(payload_contains_hidden_message(&json!({
        "text": "<app-context>\nMobile quick action: the user tapped Commit.\n</app-context>"
    })));
    assert!(!payload_contains_hidden_message(&json!({
        "text": "Plan how to cover the critical mobile flows."
    })));
}

#[test]
fn visible_prompts_synthesize_visible_user_messages_for_bridge_owned_turns() {
    assert!(super::should_synthesize_visible_user_prompt(
        "Commit",
        &super::build_hidden_commit_prompt(),
    ));
    assert!(super::should_synthesize_visible_user_prompt(
        "Commit", "Commit",
    ));
    assert!(!super::should_synthesize_visible_user_prompt(
        "",
        &super::build_hidden_commit_prompt(),
    ));
}

#[test]
fn visible_user_message_event_uses_user_message_payload() {
    let event = super::build_visible_user_message_event(
        "codex:thread-1",
        "2026-04-03T08:00:00Z",
        Some("turn-1"),
        "Commit",
        Some("client-1"),
    );

    assert_eq!(event.kind, BridgeEventKind::MessageDelta);
    assert_eq!(event.event_id, "turn-1-visible-user-prompt");
    assert_eq!(event.payload["type"], "userMessage");
    assert_eq!(event.payload["role"], "user");
    assert_eq!(event.payload["text"], "Commit");
    assert_eq!(event.payload["content"][0]["text"], "Commit");
    assert_eq!(event.payload["client_message_id"], "client-1");
}

#[tokio::test]
async fn live_user_message_injection_clears_pending_client_message_state() {
    let state = test_bridge_app_state().await;
    state
        .update_thread_runtime("codex:thread-1", |runtime| {
            runtime.pending_client_message = Some(PendingTurnClientMessage {
                client_message_id: "client-1".to_string(),
                turn_id: Some("turn-1".to_string()),
                prompt_text: "Commit".to_string(),
            });
        })
        .await;
    let mut event = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "turn-1-msg-1".to_string(),
        bridge_seq: None,
        thread_id: "codex:thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-04-03T08:00:00Z".to_string(),
        payload: json!({
            "type": "userMessage",
            "role": "user",
            "text": "Commit",
        }),
        annotations: None,
    };

    state
        .inject_pending_turn_client_message_id(&mut event)
        .await;

    assert_eq!(event.payload["client_message_id"], "client-1");
    assert!(
        !state
            .read_thread_runtime("codex:thread-1", |runtime| {
                runtime
                    .and_then(|runtime| runtime.pending_client_message.as_ref())
                    .is_some()
            })
            .await
    );
}

#[tokio::test]
async fn completion_snapshot_refresh_is_skipped_when_live_stream_was_self_sufficient() {
    assert!(GatewayTurnStreamActivity::default().requires_completion_snapshot_refresh());
    assert!(
        GatewayTurnStreamActivity {
            saw_user_message: true,
            ..GatewayTurnStreamActivity::default()
        }
        .requires_completion_snapshot_refresh()
    );
    assert!(
        !GatewayTurnStreamActivity {
            saw_user_message: true,
            saw_assistant_message: true,
            saw_turn_completed: true,
            ..GatewayTurnStreamActivity::default()
        }
        .requires_completion_snapshot_refresh()
    );
}

#[tokio::test]
async fn external_snapshot_update_enriches_latest_user_message_with_pending_client_message_id() {
    let state = test_bridge_app_state().await;
    state
        .update_thread_runtime("codex:thread-1", |runtime| {
            runtime.pending_client_message = Some(PendingTurnClientMessage {
                client_message_id: "client-1".to_string(),
                turn_id: Some("turn-1".to_string()),
                prompt_text: "Why can't you run dart format?".to_string(),
            });
        })
        .await;

    state
        .apply_external_snapshot_update(
            ThreadSnapshotDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: ThreadDetailDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "codex:thread-1".to_string(),
                    native_thread_id: "thread-1".to_string(),
                    provider: ProviderKind::Codex,
                    client: ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Completed,
                    workspace: "/repo".to_string(),
                    repository: "repo".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-04-03T08:00:00Z".to_string(),
                    updated_at: "2026-04-03T08:00:05Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "done".to_string(),
                    active_turn_id: None,
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "codex:thread-1-archive-7".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-04-03T08:00:01Z".to_string(),
                    summary: "Why can't you run dart format?".to_string(),
                    payload: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "Why can't you run dart format?"
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            },
            Vec::new(),
        )
        .await;

    let snapshot = state
        .projections()
        .snapshot("codex:thread-1")
        .await
        .expect("snapshot should exist");
    assert_eq!(snapshot.entries[0].payload["client_message_id"], "client-1");
    assert!(
        !state
            .read_thread_runtime("codex:thread-1", |runtime| {
                runtime
                    .and_then(|runtime| runtime.pending_client_message.as_ref())
                    .is_some()
            })
            .await
    );
}

#[tokio::test]
async fn external_snapshot_update_enriches_hyphenated_turn_visible_prompt_client_message_id() {
    let state = test_bridge_app_state().await;
    let turn_id = "019d5fda-9dec-7c33-b8ab-f4d8e978d125";
    state
        .update_thread_runtime("codex:thread-1", |runtime| {
            runtime.pending_client_message = Some(PendingTurnClientMessage {
                client_message_id: "client-1".to_string(),
                turn_id: Some(turn_id.to_string()),
                prompt_text: "Explain thread titles".to_string(),
            });
        })
        .await;

    state
        .apply_external_snapshot_update(
            ThreadSnapshotDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: ThreadDetailDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "codex:thread-1".to_string(),
                    native_thread_id: "thread-1".to_string(),
                    provider: ProviderKind::Codex,
                    client: ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Completed,
                    workspace: "/repo".to_string(),
                    repository: "repo".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-04-03T08:00:00Z".to_string(),
                    updated_at: "2026-04-03T08:00:05Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "done".to_string(),
                    active_turn_id: None,
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: format!("{turn_id}-visible-user-prompt"),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-04-03T08:00:01Z".to_string(),
                    summary: "Explain thread titles".to_string(),
                    payload: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "Explain thread titles"
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            },
            Vec::new(),
        )
        .await;

    let snapshot = state
        .projections()
        .snapshot("codex:thread-1")
        .await
        .expect("snapshot should exist");
    assert_eq!(snapshot.entries[0].payload["client_message_id"], "client-1");
}

#[tokio::test]
async fn external_snapshot_update_dedupes_synthetic_visible_prompt_against_canonical_user_message()
{
    let state = test_bridge_app_state().await;
    state
        .projections()
        .put_snapshot(ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: "Commit".to_string(),
                active_turn_id: Some("turn-1".to_string()),
            },
            latest_bridge_seq: None,
            entries: vec![ThreadTimelineEntryDto {
                event_id: "turn-1-visible-user-prompt".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-04-03T08:00:00Z".to_string(),
                summary: "Commit".to_string(),
                payload: json!({
                    "type": "userMessage",
                    "role": "user",
                    "text": "Commit",
                    "client_message_id": "client-1"
                }),
                annotations: None,
            }],
            approvals: vec![],
            git_status: None,
            workflow_state: None,
            pending_user_input: None,
        })
        .await;

    state
        .apply_external_snapshot_update(
            ThreadSnapshotDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: ThreadDetailDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "codex:thread-1".to_string(),
                    native_thread_id: "thread-1".to_string(),
                    provider: ProviderKind::Codex,
                    client: ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Completed,
                    workspace: "/repo".to_string(),
                    repository: "repo".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-04-03T08:00:00Z".to_string(),
                    updated_at: "2026-04-03T08:00:05Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "done".to_string(),
                    active_turn_id: None,
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "turn-1-item-user-1".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-04-03T08:00:01Z".to_string(),
                    summary: "Commit".to_string(),
                    payload: json!({
                        "type": "userMessage",
                        "role": "user",
                        "text": "Commit",
                        "client_message_id": "client-1"
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            },
            Vec::new(),
        )
        .await;

    let snapshot = state
        .projections()
        .snapshot("codex:thread-1")
        .await
        .expect("snapshot should exist");
    assert_eq!(snapshot.entries.len(), 1);
    assert_eq!(snapshot.entries[0].event_id, "turn-1-item-user-1");
}

#[test]
fn terminal_timeline_refreshes_when_cached_exploration_command_lacks_annotations() {
    let snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "codex:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: ProviderKind::Codex,
            client: ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Completed,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-04-03T08:00:00Z".to_string(),
            updated_at: "2026-04-03T08:00:02Z".to_string(),
            source: "cli".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: "done".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-search".to_string(),
            kind: BridgeEventKind::CommandDelta,
            occurred_at: "2026-04-03T08:00:01Z".to_string(),
            summary: "Called exec_command".to_string(),
            payload: json!({
                "command": "exec_command",
                "arguments": "{\"cmd\":\"rg -n LIVE_CODEX_REGULAR_FLOW_NEEDLE apps/mobile/integration_test/support/live_codex_regular_flow_probe.txt\"}",
            }),
            annotations: None,
        }],
        approvals: vec![],
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    assert!(should_refresh_terminal_timeline_snapshot(
        None, &snapshot, None,
    ));
    assert!(!should_refresh_terminal_timeline_snapshot(
        Some("cursor"),
        &snapshot,
        None,
    ));
}

#[test]
fn terminal_timeline_refresh_skips_running_and_freshly_annotated_snapshots() {
    let running_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "codex:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: ProviderKind::Codex,
            client: ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-04-03T08:00:00Z".to_string(),
            updated_at: "2026-04-03T08:00:02Z".to_string(),
            source: "cli".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: "working".to_string(),
            active_turn_id: Some("turn-1".to_string()),
        },
        latest_bridge_seq: None,
        entries: vec![],
        approvals: vec![],
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    assert!(!should_refresh_terminal_timeline_snapshot(
        None,
        &running_snapshot,
        None,
    ));

    let summary = ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: "codex:thread-1".to_string(),
        native_thread_id: "thread-1".to_string(),
        provider: ProviderKind::Codex,
        client: ThreadClientKind::Cli,
        title: "Thread".to_string(),
        status: ThreadStatus::Completed,
        workspace: "/repo".to_string(),
        repository: "repo".to_string(),
        branch: "main".to_string(),
        updated_at: "2026-04-03T08:00:02Z".to_string(),
    };
    let annotated_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Completed,
            active_turn_id: None,
            last_turn_summary: "done".to_string(),
            ..running_snapshot.thread.clone()
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-search".to_string(),
            kind: BridgeEventKind::CommandDelta,
            occurred_at: "2026-04-03T08:00:01Z".to_string(),
            summary: "Search".to_string(),
            payload: json!({
                "command": "exec_command",
                "arguments": "{\"cmd\":\"rg -n LIVE_CODEX_REGULAR_FLOW_NEEDLE apps/mobile/integration_test/support/live_codex_regular_flow_probe.txt\"}",
            }),
            annotations: build_timeline_event_envelope(
                "evt-search",
                "codex:thread-1",
                BridgeEventKind::CommandDelta,
                "2026-04-03T08:00:01Z",
                json!({
                    "command": "exec_command",
                    "arguments": "{\"cmd\":\"rg -n LIVE_CODEX_REGULAR_FLOW_NEEDLE apps/mobile/integration_test/support/live_codex_regular_flow_probe.txt\"}",
                }),
            )
            .annotations,
        }],
        approvals: vec![],
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    assert!(!should_refresh_terminal_timeline_snapshot(
        None,
        &annotated_snapshot,
        Some(&summary),
    ));
}

#[tokio::test]
async fn bridge_turn_metadata_merges_synthetic_visible_user_messages() {
    let state = test_bridge_app_state().await;
    let event = super::build_visible_user_message_event(
        "codex:thread-1",
        "2026-04-03T08:00:00Z",
        Some("turn-1"),
        "Commit",
        None,
    );

    state.record_bridge_turn_metadata(&event).await;

    let mut snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "codex:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: ProviderKind::Codex,
            client: ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-04-03T08:00:00Z".to_string(),
            updated_at: "2026-04-03T08:00:00Z".to_string(),
            source: "cli".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    state.merge_bridge_turn_metadata(&mut snapshot).await;

    assert_eq!(snapshot.entries.len(), 1);
    assert_eq!(snapshot.entries[0].event_id, "turn-1-visible-user-prompt");
    assert_eq!(snapshot.entries[0].payload["text"], "Commit");
}

#[tokio::test]
async fn bridge_turn_metadata_does_not_duplicate_existing_synthetic_visible_user_message() {
    let state = test_bridge_app_state().await;
    let event = super::build_visible_user_message_event(
        "codex:thread-1",
        "2026-04-03T08:00:00Z",
        Some("turn-1"),
        "Commit",
        None,
    );

    state.record_bridge_turn_metadata(&event).await;

    let mut snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "codex:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: ProviderKind::Codex,
            client: ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-04-03T08:00:00Z".to_string(),
            updated_at: "2026-04-03T08:00:00Z".to_string(),
            source: "cli".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "turn-1-visible-user-prompt".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-04-03T08:00:00Z".to_string(),
            summary: "Commit".to_string(),
            payload: json!({
                "type": "userMessage",
                "role": "user",
                "text": "Commit",
            }),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    state.merge_bridge_turn_metadata(&mut snapshot).await;

    assert_eq!(snapshot.entries.len(), 1);
}

#[tokio::test]
async fn pending_images_attach_to_synthetic_visible_user_message() {
    let state = test_bridge_app_state().await;
    state
        .update_thread_runtime("codex:thread-1", |runtime| {
            runtime.pending_user_message_images = vec![
                "https://example.test/a.png".to_string(),
                "https://example.test/b.png".to_string(),
            ];
        })
        .await;
    let mut event = super::build_visible_user_message_event(
        "codex:thread-1",
        "2026-04-03T08:00:00Z",
        Some("turn-1"),
        "Commit",
        None,
    );

    state.merge_pending_user_message_images(&mut event).await;

    assert_eq!(
        event.payload["images"],
        json!(["https://example.test/a.png", "https://example.test/b.png"])
    );
    assert!(
        !state
            .read_thread_runtime("codex:thread-1", |runtime| {
                runtime.is_some_and(|runtime| !runtime.pending_user_message_images.is_empty())
            })
            .await
    );
}

#[test]
fn provider_approval_questionnaires_are_not_reconstructed_as_plan_sessions() {
    let questionnaire = PendingUserInputDto {
        request_id: "approval-1".to_string(),
        title: "Approve command execution?".to_string(),
        detail: None,
        workflow_kind: Some("provider_approval".to_string()),
        original_prompt: None,
        provider_request_id: Some("req-approval-1".to_string()),
        questions: vec![UserInputQuestionDto {
            question_id: "approval_decision".to_string(),
            prompt: "Choose an action".to_string(),
            options: vec![
                UserInputOptionDto {
                    option_id: "allow_once".to_string(),
                    label: "Allow once".to_string(),
                    description: String::new(),
                    is_recommended: true,
                },
                UserInputOptionDto {
                    option_id: "allow_for_session".to_string(),
                    label: "Allow for session".to_string(),
                    description: String::new(),
                    is_recommended: false,
                },
                UserInputOptionDto {
                    option_id: "deny".to_string(),
                    label: "Deny".to_string(),
                    description: String::new(),
                    is_recommended: false,
                },
            ],
        }],
    };

    assert!(super::looks_like_provider_approval_questionnaire(
        &questionnaire
    ));
}

#[tokio::test]
async fn startup_expires_native_plan_questionnaire_sessions_from_projection_state() {
    let state = test_bridge_app_state().await;
    let questionnaire = PendingUserInputDto {
        request_id: "native-plan-request".to_string(),
        title: "Clarify the implementation".to_string(),
        detail: Some("Answer the plan questions below.".to_string()),
        workflow_kind: Some("plan_questionnaire".to_string()),
        original_prompt: Some("Plan the reconnect rewrite".to_string()),
        provider_request_id: Some("call-plan-native".to_string()),
        questions: vec![UserInputQuestionDto {
            question_id: "scope".to_string(),
            prompt: "What should this plan prioritize?".to_string(),
            options: vec![
                UserInputOptionDto {
                    option_id: "bridge".to_string(),
                    label: "Bridge".to_string(),
                    description: String::new(),
                    is_recommended: true,
                },
                UserInputOptionDto {
                    option_id: "mobile".to_string(),
                    label: "Mobile".to_string(),
                    description: String::new(),
                    is_recommended: false,
                },
            ],
        }],
    };
    state
        .projections()
        .put_snapshot(ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-native-plan-restart".to_string(),
                native_thread_id: "thread-native-plan-restart".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: Some("turn-native-plan-restart".to_string()),
            },
            latest_bridge_seq: None,
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            workflow_state: None,
            pending_user_input: Some(questionnaire),
        })
        .await;

    state
        .restore_pending_user_input_sessions_from_projection()
        .await;

    assert!(
        state
            .read_thread_runtime("codex:thread-native-plan-restart", |runtime| {
                runtime
                    .and_then(|runtime| runtime.pending_user_input.as_ref())
                    .is_none()
            })
            .await,
        "native plan questionnaires should not be rehydrated after bridge restart"
    );
    assert!(
        state
            .projections()
            .snapshot("codex:thread-native-plan-restart")
            .await
            .is_some_and(|snapshot| {
                snapshot.pending_user_input.is_none()
                    && snapshot.workflow_state.is_some_and(|workflow| {
                        workflow.workflow_kind == "plan_questionnaire"
                            && workflow.state == "expired"
                            && workflow.request_id.as_deref() == Some("native-plan-request")
                            && workflow.original_prompt.as_deref()
                                == Some("Plan the reconnect rewrite")
                            && workflow.provider_request_id.as_deref() == Some("call-plan-native")
                    })
            }),
        "stale native plan questionnaires should become expired workflow state on restart"
    );
}

#[tokio::test]
async fn startup_clears_stale_provider_approval_sessions_from_projection_state() {
    let state = test_bridge_app_state().await;
    let questionnaire = PendingUserInputDto {
        request_id: "approval-restart".to_string(),
        title: "Approve command execution?".to_string(),
        detail: Some("Command: git status".to_string()),
        workflow_kind: Some("provider_approval".to_string()),
        original_prompt: None,
        provider_request_id: Some("req-approval-restart".to_string()),
        questions: vec![UserInputQuestionDto {
            question_id: "approval_decision".to_string(),
            prompt: "Choose an action".to_string(),
            options: vec![
                UserInputOptionDto {
                    option_id: "allow_once".to_string(),
                    label: "Allow once".to_string(),
                    description: String::new(),
                    is_recommended: true,
                },
                UserInputOptionDto {
                    option_id: "allow_for_session".to_string(),
                    label: "Allow for session".to_string(),
                    description: String::new(),
                    is_recommended: false,
                },
                UserInputOptionDto {
                    option_id: "deny".to_string(),
                    label: "Deny".to_string(),
                    description: String::new(),
                    is_recommended: false,
                },
            ],
        }],
    };
    state
        .projections()
        .put_snapshot(ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-approval".to_string(),
                native_thread_id: "thread-approval".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: Some("turn-approval".to_string()),
            },
            latest_bridge_seq: None,
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            workflow_state: None,
            pending_user_input: Some(questionnaire),
        })
        .await;

    state
        .restore_pending_user_input_sessions_from_projection()
        .await;

    assert!(
        state
            .read_thread_runtime("codex:thread-approval", |runtime| {
                runtime
                    .and_then(|runtime| runtime.pending_user_input.as_ref())
                    .is_none()
            })
            .await,
        "provider approvals should not be rehydrated without live resolution channels"
    );
    assert!(
        state
            .projections()
            .snapshot("codex:thread-approval")
            .await
            .is_some_and(|snapshot| {
                snapshot.pending_user_input.is_none()
                    && snapshot.workflow_state.is_some_and(|workflow| {
                        workflow.workflow_kind == "provider_approval"
                            && workflow.state == "expired"
                            && workflow.request_id.as_deref() == Some("approval-restart")
                            && workflow.provider_request_id.as_deref()
                                == Some("req-approval-restart")
                    })
            }),
        "stale provider approvals should become expired workflow state on restart"
    );
}

#[tokio::test]
async fn native_codex_request_user_input_round_trip_updates_projection_and_response_payload() {
    let state = test_bridge_app_state().await;
    state
        .projections()
        .put_snapshot(ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-native-plan-live".to_string(),
                native_thread_id: "thread-native-plan-live".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: Some("turn-native-plan-live".to_string()),
            },
            latest_bridge_seq: None,
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            workflow_state: Some(ThreadWorkflowStateDto {
                workflow_kind: "plan_questionnaire".to_string(),
                state: "awaiting_questions".to_string(),
                request_id: None,
                original_prompt: Some("Plan the reconnect rewrite".to_string()),
                provider_request_id: None,
            }),
            pending_user_input: None,
        })
        .await;
    state
        .update_thread_runtime("codex:thread-native-plan-live", |runtime| {
            runtime.active_turn_id = Some("turn-native-plan-live".to_string());
        })
        .await;

    let state_for_request = state.clone();
    let request_task: tokio::task::JoinHandle<Result<Option<Value>, String>> =
        tokio::spawn(async move {
            state_for_request
                .handle_turn_control_request(
                    "codex:thread-native-plan-live",
                    GatewayTurnControlRequest::CodexRequestUserInput {
                        request_id: json!("req-plan-live"),
                        params: json!({
                            "threadId": "thread-native-plan-live",
                            "turnId": "turn-native-plan-live",
                            "itemId": "call-plan-live",
                            "questions": [{
                                "id": "scope",
                                "header": "Clarify the implementation",
                                "question": "What should this plan prioritize?",
                                "options": [{
                                    "label": "Bridge (Recommended)",
                                    "description": "Focus on bridge internals."
                                }, {
                                    "label": "Mobile",
                                    "description": "Focus on Flutter UX."
                                }]
                            }]
                        }),
                    },
                )
                .await
        });

    for _ in 0..50 {
        if state
            .projections()
            .snapshot("codex:thread-native-plan-live")
            .await
            .is_some_and(|snapshot| snapshot.pending_user_input.is_some())
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let pending = state
        .projections()
        .snapshot("codex:thread-native-plan-live")
        .await
        .and_then(|snapshot| snapshot.pending_user_input)
        .expect("native request_user_input should publish pending state");
    assert_eq!(pending.request_id, "req-plan-live");
    assert_eq!(
        pending.provider_request_id.as_deref(),
        Some("call-plan-live")
    );
    assert_eq!(
        state
            .projections()
            .snapshot("codex:thread-native-plan-live")
            .await
            .and_then(|snapshot| snapshot.workflow_state)
            .as_ref()
            .map(|workflow| workflow.state.as_str()),
        Some("awaiting_response")
    );

    let mutation = state
        .respond_to_user_input(
            "codex:thread-native-plan-live",
            "req-plan-live",
            &[UserInputAnswerDto {
                question_id: "scope".to_string(),
                option_id: "bridge".to_string(),
            }],
            Some("Keep reconnect stable."),
            None,
            None,
        )
        .await
        .expect("native request_user_input response should succeed");
    assert_eq!(mutation.thread_status, ThreadStatus::Running);
    assert_eq!(mutation.turn_id.as_deref(), Some("turn-native-plan-live"));

    let response = request_task
        .await
        .expect("request task should join")
        .expect("control request should succeed")
        .expect("control request should return a response payload");
    assert_eq!(
        response,
        json!({
            "answers": {
                "scope": {
                    "answers": ["Bridge", "user_note: Keep reconnect stable."]
                }
            }
        })
    );
    assert!(
        state
            .projections()
            .snapshot("codex:thread-native-plan-live")
            .await
            .is_some_and(|snapshot| {
                snapshot.pending_user_input.is_none() && snapshot.workflow_state.is_none()
            }),
        "native request_user_input resolution should clear pending projection state"
    );
}

#[tokio::test]
async fn provider_approval_sessions_set_and_clear_explicit_workflow_state() {
    let state = test_bridge_app_state().await;
    state
        .projections()
        .put_snapshot(ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-approval-live".to_string(),
                native_thread_id: "thread-approval-live".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: Some("turn-approval-live".to_string()),
            },
            latest_bridge_seq: None,
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            workflow_state: None,
            pending_user_input: None,
        })
        .await;

    let prompt = build_pending_provider_approval_from_codex(
        "codex:thread-approval-live",
        &json!("req-live-1"),
        "item/commandExecution/requestApproval",
        &json!({
            "reason": "Need approval to inspect git state",
            "command": "git status",
            "cwd": "/repo",
        }),
    )
    .expect("approval prompt should parse")
    .expect("approval prompt should be recognized");
    let request_id = prompt.questionnaire.request_id.clone();
    let provider_request_id = prompt.provider_request_id.clone();

    let state_for_registration = state.clone();
    let registration = tokio::spawn(async move {
        state_for_registration
            .register_provider_approval_session("codex:thread-approval-live", prompt)
            .await
    });

    for _ in 0..5 {
        if state
            .projections()
            .snapshot("codex:thread-approval-live")
            .await
            .is_some_and(|snapshot| snapshot.pending_user_input.is_some())
        {
            break;
        }
        tokio::task::yield_now().await;
    }

    let snapshot = state
        .projections()
        .snapshot("codex:thread-approval-live")
        .await
        .expect("snapshot should exist");
    assert_eq!(
        snapshot
            .workflow_state
            .as_ref()
            .map(|workflow| workflow.workflow_kind.as_str()),
        Some("provider_approval")
    );
    assert_eq!(
        snapshot
            .workflow_state
            .as_ref()
            .map(|workflow| workflow.state.as_str()),
        Some("pending")
    );
    assert_eq!(
        snapshot
            .workflow_state
            .as_ref()
            .and_then(|workflow| workflow.request_id.as_deref()),
        Some(request_id.as_str())
    );
    assert_eq!(
        snapshot
            .workflow_state
            .as_ref()
            .and_then(|workflow| workflow.provider_request_id.as_deref()),
        Some(provider_request_id.as_str())
    );
    assert_eq!(
        snapshot
            .pending_user_input
            .as_ref()
            .map(|pending| pending.request_id.as_str()),
        Some(request_id.as_str())
    );

    state
        .respond_to_user_input(
            "codex:thread-approval-live",
            &request_id,
            &[UserInputAnswerDto {
                question_id: "approval_decision".to_string(),
                option_id: "allow_once".to_string(),
            }],
            None,
            None,
            None,
        )
        .await
        .expect("provider approval response should succeed");

    assert_eq!(
        registration
            .await
            .expect("registration task should finish")
            .expect("provider approval should resolve"),
        ProviderApprovalSelection::AllowOnce
    );

    let snapshot = state
        .projections()
        .snapshot("codex:thread-approval-live")
        .await
        .expect("snapshot should exist after resolution");
    assert!(snapshot.pending_user_input.is_none());
    assert!(snapshot.workflow_state.is_none());
}

#[test]
fn codex_command_approval_prompts_map_to_pending_user_input_shape() {
    let prompt = build_pending_provider_approval_from_codex(
        "codex:thread-fallback",
        &json!("req-1"),
        "item/commandExecution/requestApproval",
        &json!({
            "reason": "Need approval to inspect git state",
            "command": "git status",
            "cwd": "/repo",
        }),
    )
    .expect("command approval payload should parse")
    .expect("command approval prompt should be recognized");

    assert_eq!(prompt.provider_request_id, "req-1");
    assert_eq!(prompt.questionnaire.title, "Approve command execution?");
    assert_eq!(
        prompt.questionnaire.workflow_kind.as_deref(),
        Some("provider_approval")
    );
    assert_eq!(
        prompt.questionnaire.provider_request_id.as_deref(),
        Some("req-1")
    );
    assert_eq!(prompt.questionnaire.questions.len(), 1);
    assert_eq!(
        prompt.questionnaire.questions[0]
            .options
            .iter()
            .map(|option| option.option_id.as_str())
            .collect::<Vec<_>>(),
        vec!["allow_once", "allow_for_session", "deny"]
    );
    assert!(
        prompt
            .questionnaire
            .detail
            .expect("detail should be present")
            .contains("Command: git status")
    );
}

#[test]
fn codex_permission_responses_map_allow_once_session_and_deny() {
    let params = json!({
        "permissions": {
            "fileSystem": { "read": ["/repo"], "write": ["/repo"] },
            "network": { "enabled": true }
        }
    });
    let allow_once = build_codex_approval_response(
        "item/permissions/requestApproval",
        &params,
        ProviderApprovalSelection::AllowOnce,
    )
    .expect("allow once should map");
    let allow_session = build_codex_approval_response(
        "item/permissions/requestApproval",
        &params,
        ProviderApprovalSelection::AllowForSession,
    )
    .expect("allow for session should map");
    let deny = build_codex_approval_response(
        "item/permissions/requestApproval",
        &params,
        ProviderApprovalSelection::Deny,
    )
    .expect("deny should map");

    assert_eq!(allow_once["scope"], "turn");
    assert_eq!(allow_once["permissions"], params["permissions"]);
    assert_eq!(allow_session["scope"], "session");
    assert_eq!(allow_session["permissions"], params["permissions"]);
    assert_eq!(deny["scope"], "turn");
    assert_eq!(deny["permissions"], json!({}));
}

#[test]
fn codex_command_and_file_deny_map_to_cancel_decision() {
    let command_response = build_codex_approval_response(
        "item/commandExecution/requestApproval",
        &json!({}),
        ProviderApprovalSelection::Deny,
    )
    .expect("command deny should map");
    let file_response = build_codex_approval_response(
        "item/fileChange/requestApproval",
        &json!({}),
        ProviderApprovalSelection::Deny,
    )
    .expect("file deny should map");

    assert_eq!(command_response, json!({"decision":"cancel"}));
    assert_eq!(file_response, json!({"decision":"cancel"}));
}

#[test]
fn claude_tool_approval_responses_preserve_schema() {
    let request = json!({
        "input": { "cmd": "ls -la" },
        "permission_suggestions": { "allow": ["ls"] },
        "tool_use_id": "tool-123",
    });
    let allow_session =
        build_claude_tool_approval_response(ProviderApprovalSelection::AllowForSession, &request);
    let deny = build_claude_tool_approval_response(ProviderApprovalSelection::Deny, &request);

    assert_eq!(allow_session["behavior"], "allow");
    assert_eq!(allow_session["updatedInput"], json!({"cmd":"ls -la"}));
    assert_eq!(allow_session["updatedPermissions"], json!({"allow":["ls"]}));
    assert_eq!(allow_session["toolUseID"], "tool-123");

    assert_eq!(deny["behavior"], "deny");
    assert_eq!(deny["interrupt"], true);
}

#[test]
fn provider_approval_selection_parser_accepts_allow_session_choice() {
    let selection = parse_provider_approval_selection(&[shared_contracts::UserInputAnswerDto {
        question_id: "approval_decision".to_string(),
        option_id: "allow_for_session".to_string(),
    }]);
    assert_eq!(selection, Some(ProviderApprovalSelection::AllowForSession));
}

#[tokio::test]
async fn respond_to_provider_approval_returns_mutation_and_resolves_pending_request() {
    let state = test_bridge_app_state().await;
    let thread_id = "codex:thread-provider-approval";
    let questionnaire = build_provider_approval_questionnaire(
        "thread-provider-approval",
        "Approve command execution?".to_string(),
        None,
    );
    let request_id = questionnaire.request_id.clone();
    let (resolution_tx, resolution_rx) = tokio::sync::oneshot::channel();
    state
        .update_thread_runtime(thread_id, |runtime| {
            runtime.pending_user_input = Some(PendingUserInputSession::ProviderApproval(
                PendingProviderApprovalSession {
                    questionnaire,
                    provider_request_id: "upstream-approval-1".to_string(),
                    context: ProviderApprovalContext::CodexCommandOrFile,
                    resolution_tx,
                },
            ));
            runtime.active_turn_id = Some("turn-approval-1".to_string());
        })
        .await;

    let result = state
        .respond_to_user_input(
            thread_id,
            &request_id,
            &[shared_contracts::UserInputAnswerDto {
                question_id: "approval_decision".to_string(),
                option_id: "allow_once".to_string(),
            }],
            None,
            None,
            None,
        )
        .await
        .expect("approval response should be accepted");

    assert_eq!(result.message, "approval response submitted");
    assert_eq!(result.turn_id.as_deref(), Some("turn-approval-1"));
    assert_eq!(
        resolution_rx
            .await
            .expect("provider selection should resolve"),
        ProviderApprovalSelection::AllowOnce
    );
}

#[test]
fn resume_notification_threads_replays_all_requested_threads() {
    let requested = [
        "thread-from-mobile".to_string(),
        "thread-from-desktop".to_string(),
    ];
    let mut resumed = Vec::new();

    let dropped_threads = resume_notification_threads(requested.iter(), |thread_id| {
        resumed.push(thread_id.to_string());
        Ok(())
    })
    .expect("resume replay should succeed");
    assert!(dropped_threads.is_empty());

    assert_eq!(
        resumed,
        vec![
            "thread-from-mobile".to_string(),
            "thread-from-desktop".to_string(),
        ]
    );
}

#[test]
fn drain_notification_control_messages_resumes_threads_until_queue_is_empty() {
    let (tx, rx) = mpsc::channel();
    tx.send(NotificationControlMessage::ResumeThread(
        "thread-123".to_string(),
    ))
    .expect("control message should enqueue");
    tx.send(NotificationControlMessage::ResumeThread(
        "thread-456".to_string(),
    ))
    .expect("control message should enqueue");
    drop(tx);

    let mut resumed = Vec::new();
    drain_notification_control_messages(&rx, |message| {
        let NotificationControlMessage::ResumeThread(thread_id) = message;
        resumed.push(thread_id);
        Ok(())
    })
    .expect("draining control messages should succeed");

    assert_eq!(
        resumed,
        vec!["thread-123".to_string(), "thread-456".to_string()]
    );
}

#[test]
fn duplicate_resume_notification_requests_are_de_deduplicated() {
    let (tx, rx) = mpsc::channel();
    tx.send(NotificationControlMessage::ResumeThread(
        "thread-123".to_string(),
    ))
    .expect("control message should enqueue");
    tx.send(NotificationControlMessage::ResumeThread(
        "thread-123".to_string(),
    ))
    .expect("control message should enqueue");
    drop(tx);

    let mut resumed = Vec::new();
    drain_notification_control_messages(&rx, |message| {
        let NotificationControlMessage::ResumeThread(thread_id) = message;
        resumed.push(thread_id);
        Ok(())
    })
    .expect("draining control messages should succeed");

    assert_eq!(
        resumed,
        vec!["thread-123".to_string(), "thread-123".to_string()]
    );
}

#[test]
fn request_notification_thread_resume_dispatches_once_per_thread() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime should build");
    runtime.block_on(async {
        let state = test_bridge_app_state().await;
        state
            .request_notification_thread_resume("codex:thread-123")
            .await;
        state
            .request_notification_thread_resume("codex:thread-123")
            .await;

        assert_eq!(
            state.resumable_notification_threads().await,
            std::collections::HashSet::from(["codex:thread-123".to_string()])
        );
    });
}

#[test]
fn request_notification_thread_resume_ignores_non_codex_threads() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime should build");
    runtime.block_on(async {
        let state = test_bridge_app_state().await;
        state
            .request_notification_thread_resume("claude:thread-123")
            .await;

        assert!(state.resumable_notification_threads().await.is_empty());
    });
}

#[test]
fn resume_notification_thread_retries_missing_rollout_until_success() {
    let mut attempts = 0usize;
    let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
        attempts += 1;
        if attempts < 3 {
            return Err("codex rpc request 'thread/resume' failed: no rollout found".to_string());
        }
        Ok(())
    });

    assert!(result.is_ok());
    assert_eq!(attempts, 3);
}

#[test]
fn resume_notification_thread_treats_empty_rollout_as_stale() {
    let mut attempts = 0usize;
    let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
        attempts += 1;
        Err(
                "codex rpc request 'thread/resume' failed: failed to load rollout `/tmp/rollout.jsonl`: rollout at /tmp/rollout.jsonl is empty"
                    .to_string(),
            )
    });

    assert_eq!(
            result,
            Err(
                "codex rpc request 'thread/resume' failed: failed to load rollout `/tmp/rollout.jsonl`: rollout at /tmp/rollout.jsonl is empty"
                    .to_string(),
            )
        );
    assert_eq!(attempts, 20);
}

#[test]
fn resume_notification_thread_returns_non_rollout_errors_immediately() {
    let mut attempts = 0usize;
    let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
        attempts += 1;
        Err("codex rpc request 'thread/resume' failed: invalid thread id".to_string())
    });

    assert_eq!(
        result,
        Err("codex rpc request 'thread/resume' failed: invalid thread id".to_string())
    );
    assert_eq!(attempts, 1);
}

#[tokio::test]
async fn in_flight_title_generation_still_recognizes_placeholder_titles() {
    let state = test_bridge_app_state().await;
    let placeholder_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-29T10:00:00Z".to_string(),
            updated_at: "2026-03-29T10:00:00Z".to_string(),
            source: "bridge".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    state.projections().put_snapshot(placeholder_snapshot).await;
    state
        .projections()
        .replace_summaries(vec![ThreadSummaryDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            updated_at: "2026-03-29T10:00:00Z".to_string(),
        }])
        .await;

    state
        .inner
        .inflight_thread_title_generations
        .write()
        .await
        .insert("thread-1".to_string());

    assert!(state.thread_title_still_needs_generation("thread-1").await);
    assert!(!state.should_generate_thread_title("thread-1").await);
}

#[tokio::test]
async fn claude_placeholder_titles_still_generate_and_persist_locally() {
    let state = test_bridge_app_state().await;
    let placeholder_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-29T10:00:00Z".to_string(),
            updated_at: "2026-03-29T10:00:00Z".to_string(),
            source: "bridge".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    state.projections().put_snapshot(placeholder_snapshot).await;
    state
        .projections()
        .replace_summaries(vec![ThreadSummaryDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            updated_at: "2026-03-29T10:00:00Z".to_string(),
        }])
        .await;

    assert!(state.should_generate_thread_title("claude:thread-1").await);

    state
        .persist_generated_thread_title(
            "claude:thread-1",
            "Investigate Claude thread title generation",
        )
        .await
        .expect("Claude titles should persist without an upstream rename");

    let snapshot = state
        .projections()
        .snapshot("claude:thread-1")
        .await
        .expect("Claude snapshot should exist");
    assert_eq!(
        snapshot.thread.title,
        "Investigate Claude thread title generation"
    );

    let summary_title = state
        .projections()
        .thread_title("claude:thread-1")
        .await
        .expect("Claude summary title should exist");
    assert_eq!(summary_title, "Investigate Claude thread title generation");
}

#[test]
fn title_generation_model_uses_requested_model_only_for_codex_threads() {
    assert_eq!(
        super::title_generation_model_for_thread("codex:thread-1", Some("gpt-5-mini")),
        Some("gpt-5-mini")
    );
    assert_eq!(
        super::title_generation_model_for_thread("claude:thread-1", Some("claude-sonnet-4-6"),),
        None
    );
}

#[test]
fn claude_prompt_title_fallback_uses_first_sentence() {
    assert_eq!(
        super::provisional_thread_title_from_prompt(
            "claude:thread-1",
            "Explain why thread titles help mobile triage. Do not use tools.",
        ),
        Some("Explain why thread titles help mobile triage".to_string())
    );
    assert_eq!(
        super::provisional_thread_title_from_prompt(
            "codex:thread-1",
            "Explain why thread titles help mobile triage.",
        ),
        None
    );
}

#[test]
fn external_snapshot_refresh_preserves_non_placeholder_generated_title() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Investigate Claude thread titles".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-29T10:00:00Z".to_string(),
            updated_at: "2026-03-29T10:00:00Z".to_string(),
            source: "bridge".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut refreshed_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Completed,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-29T10:00:00Z".to_string(),
            updated_at: "2026-03-29T10:00:10Z".to_string(),
            source: "bridge".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    super::preserve_generated_thread_title(&previous_snapshot, &mut refreshed_snapshot);

    assert_eq!(
        refreshed_snapshot.thread.title,
        "Investigate Claude thread titles"
    );
}

#[test]
fn summary_reconcile_preserves_existing_non_placeholder_title() {
    let reconciled = super::merge_reconciled_thread_summaries(
        vec![ThreadSummaryDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Explain why thread titles help mobile triage".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            updated_at: "2026-03-29T10:00:05Z".to_string(),
        }],
        vec![ThreadSummaryDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "claude:thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "Untitled thread".to_string(),
            status: ThreadStatus::Completed,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            updated_at: "2026-03-29T10:00:10Z".to_string(),
        }],
    );

    assert_eq!(
        reconciled[0].title,
        "Explain why thread titles help mobile triage"
    );
    assert_eq!(reconciled[0].status, ThreadStatus::Completed);
}

#[test]
fn desktop_patch_updates_mark_thread_running_until_explicit_completion_arrives() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Idle,
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            ..previous_snapshot.thread.clone()
        },
        latest_bridge_seq: previous_snapshot.latest_bridge_seq,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::CommandDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            summary: "working".to_string(),
            payload: json!({"delta":"working","replace":false}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    ensure_running_status_for_desktop_patch_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        true,
        Some("in_progress"),
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
}

#[test]
fn desktop_patch_updates_do_not_override_explicit_terminal_status() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Completed,
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            ..previous_snapshot.thread.clone()
        },
        latest_bridge_seq: previous_snapshot.latest_bridge_seq,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            summary: "done".to_string(),
            payload: json!({"delta":"done","replace":false}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    ensure_running_status_for_desktop_patch_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        true,
        Some("completed"),
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Completed);
}

#[test]
fn desktop_patch_updates_with_fresh_activity_override_idle_raw_turn_status() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "thinking".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:00Z".to_string(),
            summary: "thinking".to_string(),
            payload: json!({"delta":"thinking","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Idle,
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            ..previous_snapshot.thread.clone()
        },
        latest_bridge_seq: previous_snapshot.latest_bridge_seq,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            summary: "thinking harder".to_string(),
            payload: json!({"delta":"thinking harder","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    ensure_running_status_for_desktop_patch_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        true,
        Some("idle"),
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
}

#[test]
fn desktop_patch_updates_without_fresh_activity_preserve_idle_raw_turn_status() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "thinking".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:00Z".to_string(),
            summary: "thinking".to_string(),
            payload: json!({"delta":"thinking","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = previous_snapshot.clone();

    ensure_running_status_for_desktop_patch_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        true,
        Some("idle"),
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Idle);
}

#[test]
fn cached_desktop_snapshot_is_materialized_when_thread_starts_being_tracked() {
    let conversation_state = json!({
        "id": "thread-1",
        "hostId": "local",
        "title": "Thread",
        "cwd": "/repo",
        "lastModifiedAt": "2026-03-27T20:00:10Z",
        "turns": [
            {
                "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                "status": "in_progress",
                "turnStartedAtMs": 1774592758217_i64,
                "params": {
                    "threadId": "thread-1",
                    "cwd": "/repo",
                    "input": [{ "type": "text", "text": "hello" }]
                },
                "items": [
                    {
                        "id": "msg-user-1",
                        "type": "userMessage",
                        "content": [{ "type": "text", "text": "hello" }]
                    },
                    {
                        "id": "msg-assistant-1",
                        "type": "agentMessage",
                        "text": "working"
                    }
                ]
            }
        ]
    });

    let mut compactor = LiveDeltaCompactor::default();
    let (snapshot, events) = build_desktop_ipc_snapshot_update(
        None,
        None,
        &conversation_state,
        shared_contracts::AccessMode::ControlWithApprovals,
        &mut compactor,
        false,
        None,
        false,
    )
    .expect("cached desktop snapshot should materialize");

    assert_eq!(snapshot.thread.thread_id, "codex:thread-1");
    assert_eq!(snapshot.thread.native_thread_id, "thread-1");
    assert_eq!(snapshot.thread.status, ThreadStatus::Running);
    assert_eq!(snapshot.entries.len(), 2);
    assert!(events.iter().any(|event| {
        event.kind == BridgeEventKind::ThreadStatusChanged
            && event.payload.get("status").and_then(Value::as_str) == Some("running")
    }));
    assert!(events.iter().any(|event| {
        event.kind == BridgeEventKind::MessageDelta
            && event.payload.get("role").and_then(Value::as_str) == Some("assistant")
            && event.payload.get("replace").and_then(Value::as_bool) == Some(true)
    }));
}

#[test]
fn bridge_owned_desktop_snapshot_updates_do_not_publish_live_events() {
    let conversation_state = json!({
        "id": "thread-1",
        "hostId": "local",
        "title": "Thread",
        "cwd": "/repo",
        "lastModifiedAt": "2026-03-27T20:00:10Z",
        "turns": [
            {
                "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                "status": "in_progress",
                "turnStartedAtMs": 1774592758217_i64,
                "params": {
                    "threadId": "thread-1",
                    "cwd": "/repo",
                    "input": [{ "type": "text", "text": "hello" }]
                },
                "items": [
                    {
                        "id": "msg-assistant-1",
                        "type": "agentMessage",
                        "text": "working"
                    }
                ]
            }
        ]
    });

    let mut compactor = LiveDeltaCompactor::default();
    let (snapshot, events) = build_desktop_ipc_snapshot_update(
        None,
        None,
        &conversation_state,
        shared_contracts::AccessMode::ControlWithApprovals,
        &mut compactor,
        false,
        None,
        true,
    )
    .expect("bridge-owned desktop snapshot should still materialize");

    assert_eq!(snapshot.entries.len(), 1);
    assert!(events.is_empty());
}

#[test]
fn cached_desktop_snapshot_preserves_bootstrap_non_running_status() {
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "working".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            summary: "working".to_string(),
            payload: json!({"delta":"working","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    preserve_bootstrap_status_for_cached_desktop_snapshot(
        None,
        Some(ThreadStatus::Idle),
        &mut next_snapshot,
        false,
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Idle);
}

#[test]
fn terminal_thread_status_events_clear_transient_thread_state() {
    let event = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-status".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "status": "completed",
            "reason": "upstream_notification",
        }),
        annotations: None,
    };

    assert!(should_clear_transient_thread_state(&event));
}

#[test]
fn live_delta_compactor_keeps_plan_steps_on_compacted_events() {
    let mut compactor = LiveDeltaCompactor::default();
    let compacted = compactor.compact(BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-plan".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::PlanDelta,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "id": "plan-1",
            "type": "plan",
            "text": "1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card",
            "steps": [
                {"step": "Inspect bridge payload", "status": "completed"},
                {"step": "Add Flutter card", "status": "in_progress"}
            ],
            "completed_count": 1,
            "total_count": 2,
        }),
        annotations: None,
    });

    assert_eq!(compacted.payload["type"], "plan");
    assert_eq!(
        compacted.payload["delta"],
        "1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card"
    );
    assert_eq!(compacted.payload["completed_count"], 1);
    assert_eq!(
        compacted.payload["steps"][1]["status"].as_str(),
        Some("in_progress")
    );
}

#[test]
fn live_delta_compactor_preserves_raw_codex_message_deltas() {
    let mut compactor = LiveDeltaCompactor::default();
    let compacted = compactor.compact(BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-message".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "id": "msg-1",
            "type": "agentMessage",
            "role": "assistant",
            "delta": "**Overall**",
            "replace": false,
        }),
        annotations: None,
    });

    assert_eq!(compacted.payload["delta"], "**Overall**");
    assert_eq!(compacted.payload["replace"].as_bool(), Some(false));
}

#[test]
fn message_events_with_text_but_no_delta_still_publish() {
    let event = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-message".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "role": "assistant",
            "text": "Streaming now",
        }),
        annotations: None,
    };

    assert!(should_publish_compacted_event(&event));
}

#[test]
fn whitespace_only_message_deltas_still_publish() {
    let mut compactor = LiveDeltaCompactor::default();
    let initial = compactor.compact(BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-message".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "id": "msg-1",
            "type": "agentMessage",
            "role": "assistant",
            "text": "GIF",
        }),
        annotations: None,
    });
    let whitespace = compactor.compact(BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-message".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-27T20:00:11Z".to_string(),
        payload: json!({
            "id": "msg-1",
            "type": "agentMessage",
            "role": "assistant",
            "text": "GIF\n",
        }),
        annotations: None,
    });

    assert_eq!(initial.payload["delta"], "GIF");
    assert_eq!(whitespace.payload["delta"], "\n");
    assert!(should_publish_compacted_event(&whitespace));
}

#[test]
fn running_thread_status_events_do_not_clear_transient_thread_state() {
    let event = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-status".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: "2026-03-27T20:00:10Z".to_string(),
        payload: json!({
            "status": "running",
            "reason": "upstream_notification",
        }),
        annotations: None,
    };

    assert!(!should_clear_transient_thread_state(&event));
}

#[test]
fn bridge_owned_desktop_updates_preserve_running_until_terminal_raw_status() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "working".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:00Z".to_string(),
            summary: "working".to_string(),
            payload: json!({"delta":"working","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Idle,
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            ..previous_snapshot.thread.clone()
        },
        latest_bridge_seq: previous_snapshot.latest_bridge_seq,
        entries: vec![ThreadTimelineEntryDto {
            event_id: "evt-2".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            summary: "still working".to_string(),
            payload: json!({"delta":"still working","replace":true}),
            annotations: None,
        }],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    preserve_running_status_for_bridge_owned_desktop_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        Some("idle"),
        true,
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
}

#[test]
fn bridge_owned_desktop_updates_allow_terminal_raw_status() {
    let previous_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-1".to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Running,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:00Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "working".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };
    let mut next_snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            status: ThreadStatus::Completed,
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            ..previous_snapshot.thread.clone()
        },
        latest_bridge_seq: previous_snapshot.latest_bridge_seq,
        entries: vec![],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    preserve_running_status_for_bridge_owned_desktop_update(
        Some(&previous_snapshot),
        &mut next_snapshot,
        Some("completed"),
        true,
    );

    assert_eq!(next_snapshot.thread.status, ThreadStatus::Completed);
}

#[test]
fn notification_events_continue_streaming_for_bridge_active_turns() {
    let message = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-message".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-29T09:00:00Z".to_string(),
        payload: json!({"delta":"hello","replace":true}),
        annotations: None,
    };
    let status = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-status".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: "2026-03-29T09:00:01Z".to_string(),
        payload: json!({"status":"running"}),
        annotations: None,
    };

    assert!(!should_suppress_notification_event_for_bridge_active_turn(
        &message, true
    ));
    assert!(!should_suppress_notification_event_for_bridge_active_turn(
        &status, true
    ));
    assert!(!should_suppress_notification_event_for_bridge_active_turn(
        &message, false
    ));
}

#[test]
fn non_running_thread_status_events_are_suppressed_for_bridge_active_turns() {
    let idle_status = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-status".to_string(),
        bridge_seq: None,
        thread_id: "thread-1".to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: "2026-03-29T09:00:01Z".to_string(),
        payload: json!({"status":"idle"}),
        annotations: None,
    };
    let running_status = BridgeEventEnvelope {
        payload: json!({"status":"running"}),
        ..idle_status.clone()
    };

    assert!(should_suppress_non_running_thread_status_for_bridge_active_turn(&idle_status, true));
    assert!(
        !should_suppress_non_running_thread_status_for_bridge_active_turn(&running_status, true)
    );
    assert!(!should_suppress_non_running_thread_status_for_bridge_active_turn(&idle_status, false));
    assert!(should_suppress_notification_event_for_bridge_active_turn(
        &idle_status,
        true
    ));
}

#[tokio::test]
async fn interrupt_requested_threads_rewrite_upstream_idle_status_to_interrupted() {
    let state = test_bridge_app_state().await;
    state
        .mark_thread_interrupt_requested("codex:thread-1")
        .await;

    let mut idle_status = BridgeEventEnvelope {
        contract_version: CONTRACT_VERSION.to_string(),
        event_id: "evt-status".to_string(),
        bridge_seq: None,
        thread_id: "codex:thread-1".to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: "2026-03-29T09:00:01Z".to_string(),
        payload: json!({
            "status": "idle",
            "reason": "upstream_notification",
        }),
        annotations: None,
    };

    state
        .rewrite_interrupted_thread_status_event(&mut idle_status)
        .await;

    assert_eq!(idle_status.payload["status"], "interrupted");
    assert_eq!(idle_status.payload["reason"], "interrupt_requested");
}

#[tokio::test]
async fn interrupt_requested_threads_preserve_interrupted_status_in_completion_snapshot() {
    let state = test_bridge_app_state().await;
    let thread_id = "codex:thread-1";
    state.mark_thread_interrupt_requested(thread_id).await;

    let snapshot = ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            native_thread_id: "thread-1".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
            title: "Thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: "/repo".to_string(),
            repository: "repo".to_string(),
            branch: "main".to_string(),
            created_at: "2026-03-27T20:00:00Z".to_string(),
            updated_at: "2026-03-27T20:00:10Z".to_string(),
            source: "codex_app_ipc".to_string(),
            access_mode: shared_contracts::AccessMode::ControlWithApprovals,
            last_turn_summary: "idle".to_string(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: vec![],
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    };

    state
        .apply_bridge_turn_completion_snapshot(thread_id, snapshot)
        .await;

    let stored = state
        .projections()
        .snapshot(thread_id)
        .await
        .expect("snapshot should be stored");
    assert_eq!(stored.thread.status, ThreadStatus::Interrupted);
}

#[test]
fn bridge_owned_turn_finalization_waits_for_non_running_snapshot() {
    assert!(should_defer_bridge_owned_turn_finalization(
        ThreadStatus::Running
    ));
    assert!(!should_defer_bridge_owned_turn_finalization(
        ThreadStatus::Idle
    ));
    assert!(!should_defer_bridge_owned_turn_finalization(
        ThreadStatus::Completed
    ));
}

#[test]
fn watchdog_does_not_finalize_while_turn_stream_is_active() {
    assert!(!watchdog_should_finalize_bridge_owned_turn(
        ThreadStatus::Completed,
        true
    ));
    assert!(!watchdog_should_finalize_bridge_owned_turn(
        ThreadStatus::Running,
        false
    ));
    assert!(watchdog_should_finalize_bridge_owned_turn(
        ThreadStatus::Completed,
        false
    ));
}
