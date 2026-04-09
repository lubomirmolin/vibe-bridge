use super::*;

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
    assert_eq!(first.payload["delta"], "Hel");
    assert_eq!(first.payload["replace"], false);

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
    assert_eq!(second.payload["delta"], "lo");
    assert_eq!(second.payload["replace"], false);
}

#[test]
fn codex_notification_normalizer_ignores_message_item_added_and_merges_cumulative_delta() {
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
                        "text": "I'm",
                    }
                }),
            )
            .is_none(),
        "assistant lifecycle events should no longer be the canonical live message source"
    );

    let cumulative = normalizer
        .normalize(
            "item/agentMessage/delta",
            &json!({
                "delta": "I'm checking",
                "itemId": "msg-1",
                "threadId": "thread-123",
                "turnId": "turn-123",
            }),
        )
        .expect("cumulative delta should publish");

    assert_eq!(cumulative.event_id, "turn-123-msg-1");
    assert_eq!(
        cumulative.payload["delta"], "I'm checking",
        "The bridge should preserve the raw assistant delta payload."
    );
    assert_eq!(cumulative.payload["replace"], false);
}

#[test]
fn codex_notification_normalizer_emits_message_completion_only_when_no_delta_arrived() {
    let mut normalizer = CodexNotificationNormalizer::default();

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

    let completed = normalizer
        .normalize(
            "item/completed",
            &json!({
                "threadId": "thread-123",
                "turnId": "turn-123",
                "item": {
                    "id": "msg-1",
                    "type": "agentMessage",
                    "text": "Final answer",
                }
            }),
        )
        .expect("message completion should publish when no delta was observed");

    assert_eq!(completed.kind, BridgeEventKind::MessageDelta);
    assert_eq!(completed.payload["text"], "Final answer");

    let mut normalizer = CodexNotificationNormalizer::default();
    let _ = normalizer.normalize(
        "item/agentMessage/delta",
        &json!({
            "delta": "Partial",
            "itemId": "msg-2",
            "threadId": "thread-123",
            "turnId": "turn-123",
        }),
    );

    assert!(
        normalizer
            .normalize(
                "item/completed",
                &json!({
                    "threadId": "thread-123",
                    "turnId": "turn-123",
                    "item": {
                        "id": "msg-2",
                        "type": "agentMessage",
                        "text": "Partial answer",
                    }
                }),
            )
            .is_none(),
        "completion should not mirror an assistant message that already streamed via delta"
    );
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
fn codex_notification_normalizer_maps_update_plan_to_plan_delta() {
    let mut normalizer = CodexNotificationNormalizer::default();

    let event = normalizer
        .normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "plan-1",
                    "type": "functionCall",
                    "name": "update_plan",
                    "arguments": "{\"explanation\":\"Keep the UI in sync.\",\"plan\":[{\"step\":\"Inspect bridge payload\",\"status\":\"completed\"},{\"step\":\"Add Flutter card\",\"status\":\"in_progress\"},{\"step\":\"Run targeted tests\",\"status\":\"pending\"}]}"
                }
            }),
        )
        .expect("update_plan should produce a plan event");

    assert_eq!(event.kind, BridgeEventKind::PlanDelta);
    assert_eq!(event.payload["type"], "plan");
    assert_eq!(event.payload["completed_count"], 1);
    assert_eq!(event.payload["total_count"], 3);
    assert_eq!(
        event.payload["steps"][1]["status"].as_str(),
        Some("in_progress")
    );
    assert_eq!(
        event.payload["text"].as_str(),
        Some(
            "1 out of 3 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card\n3. Run targeted tests"
        )
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
fn codex_notification_normalizer_preserves_apply_patch_name_on_output_items() {
    let mut normalizer = CodexNotificationNormalizer::default();

    let event = normalizer
        .normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "tool-2",
                    "type": "customToolCallOutput",
                    "name": "apply_patch",
                    "output": "{\"output\":\"Success. Updated the following files:\\nM lib/main.dart\\n\",\"metadata\":{\"exit_code\":0}}",
                }
            }),
        )
        .expect("custom tool output item should produce an event");

    assert_eq!(event.kind, BridgeEventKind::FileChange);
    assert_eq!(event.payload["command"], "apply_patch");
    assert_eq!(
        event.payload["output"],
        "Success. Updated the following files:\nM lib/main.dart\n"
    );
}

#[test]
fn codex_notification_normalizer_maps_web_search_items_to_command_events() {
    let mut normalizer = CodexNotificationNormalizer::default();

    let event = normalizer
        .normalize(
            "thread/realtime/itemAdded",
            &json!({
                "threadId": "thread-123",
                "item": {
                    "id": "web-1",
                    "type": "webSearch",
                    "action": {
                        "type": "search",
                        "query": "GitHub R2Explorer README",
                        "queries": ["GitHub R2Explorer README"]
                    }
                }
            }),
        )
        .expect("web search should produce a command event");

    assert_eq!(event.kind, BridgeEventKind::CommandDelta);
    assert_eq!(event.payload["command"], "web_search");
    assert_eq!(event.payload["action"], "search");
    assert_eq!(event.payload["output"], "search: GitHub R2Explorer README");
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
