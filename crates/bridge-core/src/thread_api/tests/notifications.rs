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
