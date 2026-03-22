use super::*;

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
