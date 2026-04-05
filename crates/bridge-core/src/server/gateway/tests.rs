use super::claude::{
    build_claude_input_message, build_claude_message_content, claude_project_slug,
    claude_session_archive_path, parse_data_url_image, summarize_claude_stderr,
};
use super::codex::{
    build_turn_start_input, fetch_thread_summaries_from_archive, normalize_generated_thread_title,
};
use super::mapping::{
    derive_repository_name_from_cwd, extract_generated_thread_title, map_thread_snapshot,
    map_thread_summary, merge_rpc_and_archive_timeline_entries, normalize_codex_item_payload,
    parse_model_options, parse_repository_name_from_origin, timeline_annotations_for_event,
};
use super::{
    CodexGateway, CodexGitInfo, CodexThread, CodexThreadStatus, CodexTurn,
    GatewayTurnControlRequest, TurnStartRequest,
};
use crate::codex_runtime::CodexRuntimeMode;
use crate::server::config::BridgeCodexConfig;
use serde_json::{Value, json};
use shared_contracts::{
    BridgeEventKind, ProviderKind, ThreadTimelineEntryDto, ThreadTimelineExplorationKind,
};
use std::fs;
use std::sync::mpsc;
use std::time::{Duration, Instant};

#[test]
fn parses_repository_name_from_origin_url() {
    assert_eq!(
        parse_repository_name_from_origin("git@github.com:openai/codex.git"),
        Some("codex".to_string())
    );
}

#[test]
fn derives_repository_name_from_workspace_path() {
    assert_eq!(
        derive_repository_name_from_cwd("/Users/test/project"),
        Some("project".to_string())
    );
}

#[test]
fn function_call_command_payload_preserves_arguments_for_mobile_formatting() {
    let item = json!({
        "id": "tool-1",
        "type": "functionCall",
        "name": "exec_command",
        "arguments": "{\"cmd\":\"flutter analyze\"}",
    });

    let (kind, payload) =
        normalize_codex_item_payload(&item).expect("function call should normalize");
    assert_eq!(kind, BridgeEventKind::CommandDelta);
    assert_eq!(payload["command"], "exec_command");
    assert_eq!(payload["arguments"], "{\"cmd\":\"flutter analyze\"}");
}

#[test]
fn update_plan_function_call_normalizes_to_plan_delta() {
    let item = json!({
        "id": "tool-2",
        "type": "functionCall",
        "name": "update_plan",
        "arguments": "{\"plan\":[{\"step\":\"Inspect bridge payload\",\"status\":\"completed\"},{\"step\":\"Add Flutter card\",\"status\":\"in_progress\"}]}"
    });

    let (kind, payload) =
        normalize_codex_item_payload(&item).expect("update_plan should normalize");
    assert_eq!(kind, BridgeEventKind::PlanDelta);
    assert_eq!(payload["type"], "plan");
    assert_eq!(payload["completed_count"], 1);
    assert_eq!(payload["total_count"], 2);
    assert_eq!(
        payload["text"].as_str(),
        Some("1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card")
    );
}

#[test]
fn web_search_item_normalizes_to_command_delta() {
    let item = json!({
        "id": "web-1",
        "type": "webSearch",
        "action": {
            "type": "search",
            "query": "GitHub R2Explorer README",
            "queries": ["GitHub R2Explorer README"]
        }
    });

    let (kind, payload) = normalize_codex_item_payload(&item).expect("web search should normalize");
    assert_eq!(kind, BridgeEventKind::CommandDelta);
    assert_eq!(payload["command"], "web_search");
    assert_eq!(payload["action"], "search");
    assert_eq!(payload["output"], "search: GitHub R2Explorer README");
}

#[test]
fn file_change_tool_output_extracts_path_from_updated_files_summary() {
    let item = json!({
        "id": "tool-edit-result",
        "type": "functionCallOutput",
        "name": "apply_patch",
        "output": "Success. Updated the following files:\nA tmp/live_codex_regular_flow/probe.txt\n",
    });

    let (kind, payload) =
        normalize_codex_item_payload(&item).expect("file change output should normalize");
    assert_eq!(kind, BridgeEventKind::FileChange);
    assert_eq!(payload["path"], "tmp/live_codex_regular_flow/probe.txt");
}

#[test]
fn thread_snapshot_preserves_regular_codex_search_read_and_edit_flow() {
    let snapshot = map_thread_snapshot(CodexThread {
        id: "thread-regular-flow".to_string(),
        name: Some("Regular flow".to_string()),
        preview: Some("search read edit".to_string()),
        status: CodexThreadStatus {
            kind: "idle".to_string(),
        },
        cwd: "/Users/test/codex-mobile-companion".to_string(),
        path: None,
        git_info: Some(CodexGitInfo {
            branch: Some("main".to_string()),
            origin_url: Some("git@github.com:openai/codex-mobile-companion.git".to_string()),
        }),
        created_at: 1_710_000_000,
        updated_at: 1_710_000_300,
        source: Value::String("cli".to_string()),
        turns: vec![CodexTurn {
            id: "turn-regular-flow".to_string(),
            items: vec![
                json!({
                    "id": "tool-search",
                    "type": "functionCall",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"rg -n LIVE_CODEX_REGULAR_FLOW_NEEDLE apps/mobile/integration_test/support/live_codex_regular_flow_probe.txt\"}",
                }),
                json!({
                    "id": "tool-read",
                    "type": "functionCall",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"sed -n '1,3p' apps/mobile/integration_test/support/live_codex_regular_flow_probe.txt\"}",
                }),
                json!({
                    "id": "tool-edit",
                    "type": "functionCall",
                    "name": "apply_patch",
                    "arguments": "*** Begin Patch\n*** Add File: tmp/live_codex_regular_flow/probe.txt\n+Needle: LIVE_CODEX_REGULAR_FLOW_NEEDLE\n+Status: ready\n*** End Patch",
                }),
                json!({
                    "id": "tool-edit-result",
                    "type": "functionCallOutput",
                    "name": "apply_patch",
                    "output": "Success. Updated the following files:\nA tmp/live_codex_regular_flow/probe.txt\n",
                }),
                json!({
                    "id": "msg-assistant",
                    "type": "agentMessage",
                    "text": "done",
                }),
            ],
        }],
    });

    let search_entry = snapshot
        .entries
        .iter()
        .find(|entry| entry.event_id.ends_with("tool-search"))
        .expect("search entry should exist");
    assert_eq!(search_entry.kind, BridgeEventKind::CommandDelta);
    assert_eq!(
        search_entry
            .annotations
            .as_ref()
            .and_then(|annotations| annotations.exploration_kind),
        Some(ThreadTimelineExplorationKind::Search)
    );
    assert_eq!(
        search_entry
            .annotations
            .as_ref()
            .and_then(|annotations| annotations.entry_label.as_deref()),
        Some("Search")
    );

    let read_entry = snapshot
        .entries
        .iter()
        .find(|entry| entry.event_id.ends_with("tool-read"))
        .expect("read entry should exist");
    assert_eq!(read_entry.kind, BridgeEventKind::CommandDelta);
    assert_eq!(
        read_entry
            .annotations
            .as_ref()
            .and_then(|annotations| annotations.exploration_kind),
        Some(ThreadTimelineExplorationKind::Read)
    );
    assert_eq!(
        read_entry
            .annotations
            .as_ref()
            .and_then(|annotations| annotations.entry_label.as_deref()),
        Some("Read live_codex_regular_flow_probe.txt")
    );

    let edit_entry = snapshot
        .entries
        .iter()
        .find(|entry| entry.event_id.ends_with("tool-edit"))
        .expect("edit entry should exist");
    assert_eq!(edit_entry.kind, BridgeEventKind::FileChange);
    assert_eq!(
        edit_entry.payload["path"],
        "tmp/live_codex_regular_flow/probe.txt"
    );

    let edit_result_entry = snapshot
        .entries
        .iter()
        .find(|entry| entry.event_id.ends_with("tool-edit-result"))
        .expect("edit result entry should exist");
    assert_eq!(edit_result_entry.kind, BridgeEventKind::FileChange);
    assert_eq!(
        edit_result_entry.payload["path"],
        "tmp/live_codex_regular_flow/probe.txt"
    );
}

#[test]
fn scalar_command_output_does_not_recurse_during_annotation_detection() {
    let payload = json!({
        "command": "/bin/zsh -lc 'adb -s RFCW70FTAVB reverse tcp:3310 tcp:3310'",
        "aggregatedOutput": "3310\n",
    });

    let annotations =
        timeline_annotations_for_event("turn-1-call-1", BridgeEventKind::CommandDelta, &payload);
    assert!(annotations.is_none());
}

#[test]
fn command_execution_annotations_use_command_even_when_output_is_scalar_json() {
    let snapshot = map_thread_snapshot(CodexThread {
        id: "thread-command-output-scalar".to_string(),
        name: Some("Scalar output".to_string()),
        preview: Some("scalar output".to_string()),
        status: CodexThreadStatus {
            kind: "idle".to_string(),
        },
        cwd: "/Users/test/codex-mobile-companion".to_string(),
        path: None,
        git_info: Some(CodexGitInfo {
            branch: Some("main".to_string()),
            origin_url: Some("git@github.com:openai/codex-mobile-companion.git".to_string()),
        }),
        created_at: 1_710_000_000,
        updated_at: 1_710_000_300,
        source: Value::String("cli".to_string()),
        turns: vec![CodexTurn {
            id: "turn-command-output-scalar".to_string(),
            items: vec![json!({
                "id": "call-adb-reverse",
                "type": "commandExecution",
                "command": "/bin/zsh -lc 'adb -s RFCW70FTAVB reverse tcp:3310 tcp:3310'",
                "cwd": "/Users/test/codex-mobile-companion",
                "status": "completed",
                "aggregatedOutput": "3310\n",
                "exitCode": 0,
                "durationMs": 0
            })],
        }],
    });

    assert_eq!(snapshot.entries.len(), 1);
    assert_eq!(snapshot.entries[0].kind, BridgeEventKind::CommandDelta);
    assert!(snapshot.entries[0].annotations.is_none());
}

#[test]
fn summarize_claude_stderr_prefers_human_readable_error_lines() {
    let stderr = "Error: Session ID 123 is already in use.\n    at main (file:///tmp/cli.js:1:1)";
    assert_eq!(
        summarize_claude_stderr(stderr).as_deref(),
        Some("Error: Session ID 123 is already in use.")
    );
}

#[test]
fn summarize_claude_stderr_hides_minified_stack_noise() {
    let stderr = "file:///Users/test/node_modules/@anthropic-ai/claude-code/cli.js:489\n`)},Q.code=Z.error.code,Q.errors=Z.error.errors;else Q.message=Z.error.message;";
    assert_eq!(
        summarize_claude_stderr(stderr).as_deref(),
        Some("Claude CLI crashed before it returned a usable error message.")
    );
}

#[test]
fn claude_project_slug_normalizes_workspace_path() {
    assert_eq!(
        claude_project_slug("/Users/test/Library/Application Support/CodexBar/ClaudeProbe"),
        "-Users-test-Library-Application-Support-CodexBar-ClaudeProbe"
    );
}

#[test]
fn claude_session_archive_path_uses_claude_home_override() {
    let _env_lock = crate::test_support::lock_test_env();
    let claude_home =
        std::env::temp_dir().join(format!("gateway-claude-session-{}", std::process::id()));
    let previous_claude_home = std::env::var_os("CLAUDE_HOME");

    unsafe {
        std::env::set_var("CLAUDE_HOME", &claude_home);
    }

    let session_path = claude_session_archive_path(
        "/Users/test/Library/Application Support/CodexBar/ClaudeProbe",
        "session-123",
    )
    .expect("Claude session path should resolve");

    assert_eq!(
        session_path,
        claude_home
            .join("projects")
            .join("-Users-test-Library-Application-Support-CodexBar-ClaudeProbe")
            .join("session-123.jsonl")
    );

    unsafe {
        if let Some(previous_claude_home) = previous_claude_home {
            std::env::set_var("CLAUDE_HOME", previous_claude_home);
        } else {
            std::env::remove_var("CLAUDE_HOME");
        }
    }
}

#[test]
fn turn_start_input_includes_text_and_image_parts() {
    let input = build_turn_start_input(
        "Describe this image",
        &["data:image/png;base64,AAA".to_string()],
    );

    assert_eq!(
        input,
        json!([
            {
                "type": "text",
                "text": "Describe this image",
                "text_elements": [],
            },
            {
                "type": "image",
                "url": "data:image/png;base64,AAA",
            }
        ])
    );
}

#[test]
fn parse_data_url_image_decodes_png_payload() {
    let parsed =
        parse_data_url_image("data:image/png;base64,QUJD").expect("data URL image should decode");

    assert_eq!(parsed.mime_type, "image/png");
    assert_eq!(parsed.base64_data, "QUJD");
}

#[test]
fn build_claude_message_content_emits_native_image_blocks() {
    let content = build_claude_message_content(
        "Describe the screenshot",
        &["data:image/png;base64,QUJD".to_string()],
    )
    .expect("Claude turn content should prepare");

    assert_eq!(
        content,
        json!([
            {
                "type": "text",
                "text": "Describe the screenshot",
            },
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/png",
                    "data": "QUJD",
                },
            }
        ])
    );
}

#[test]
fn build_claude_input_message_emits_sdk_user_message_ndjson() {
    let line = build_claude_input_message(
        "Describe the screenshot",
        &["data:image/png;base64,QUJD".to_string()],
    )
    .expect("Claude turn input line should encode");

    let decoded: Value = serde_json::from_str(line.trim()).expect("line should decode");
    assert_eq!(decoded["type"], "user");
    assert_eq!(decoded["message"]["role"], "user");
    assert_eq!(
        decoded["message"]["content"][1]["source"]["media_type"],
        "image/png"
    );
    assert_eq!(decoded["message"]["content"][1]["source"]["data"], "QUJD");
}

#[test]
fn normalize_message_item_preserves_image_urls_from_codex_content() {
    let item = json!({
        "id": "msg-1",
        "type": "userMessage",
        "content": [
            {
                "type": "text",
                "text": "Screenshot attached",
            },
            {
                "type": "image",
                "url": "data:image/png;base64,AAA",
            }
        ],
    });

    let (kind, payload) = normalize_codex_item_payload(&item).expect("message should normalize");
    assert_eq!(kind, BridgeEventKind::MessageDelta);
    assert_eq!(payload["role"], "user");
    assert_eq!(payload["images"], json!(["data:image/png;base64,AAA"]));
}

#[test]
fn map_thread_snapshot_surfaces_pending_plan_questions_without_protocol_messages() {
    let snapshot = map_thread_snapshot(CodexThread {
        id: "thread-plan".to_string(),
        name: Some("Plan mode".to_string()),
        preview: Some("preview".to_string()),
        status: CodexThreadStatus {
            kind: "idle".to_string(),
        },
        cwd: "/workspace/repo".to_string(),
        path: None,
        git_info: Some(CodexGitInfo {
            branch: Some("main".to_string()),
            origin_url: Some("git@github.com:example/repo.git".to_string()),
        }),
        created_at: 1_710_000_000,
        updated_at: 1_710_000_300,
        source: Value::String("cli".to_string()),
        turns: vec![CodexTurn {
            id: "turn-plan".to_string(),
            items: vec![
                json!({
                    "id": "msg-hidden-user",
                    "type": "userMessage",
                    "text": "You are running in mobile plan intake mode.\nReturn only one XML-like block.",
                }),
                json!({
                    "id": "msg-hidden-assistant",
                    "type": "agentMessage",
                    "text": "<codex-plan-questions>{\"title\":\"Clarify the implementation\",\"detail\":\"Pick a focus.\",\"questions\":[{\"question_id\":\"scope\",\"prompt\":\"What should the test cover first?\",\"options\":[{\"option_id\":\"core\",\"label\":\"Core flows\",\"description\":\"Focus on pairing and thread navigation.\",\"is_recommended\":true},{\"option_id\":\"plan\",\"label\":\"Plan mode\",\"description\":\"Focus on plan mode only.\",\"is_recommended\":false},{\"option_id\":\"polish\",\"label\":\"UI polish\",\"description\":\"Focus on layout and copy.\",\"is_recommended\":false}]}]}</codex-plan-questions>",
                }),
            ],
        }],
    });

    assert!(snapshot.entries.is_empty());
    let pending_user_input = snapshot
        .pending_user_input
        .expect("pending user input should be reconstructed");
    assert_eq!(pending_user_input.title, "Clarify the implementation");
    assert_eq!(pending_user_input.questions.len(), 1);
    assert_eq!(pending_user_input.questions[0].question_id, "scope");
}

#[test]
fn parses_model_catalog_from_codex_response() {
    let models = parse_model_options(json!({
        "data": [
            {
                "id": "gpt-5.4",
                "model": "gpt-5.4",
                "displayName": "GPT-5.4",
                "description": "Best reasoning",
                "isDefault": true,
                "defaultReasoningEffort": "high",
                "supportedReasoningEfforts": [
                    {"reasoningEffort": "medium"},
                    {"reasoningEffort": "high"}
                ]
            }
        ]
    }));

    assert_eq!(models.len(), 1);
    assert_eq!(models[0].id, "gpt-5.4");
    assert_eq!(models[0].display_name, "GPT-5.4");
    assert!(models[0].is_default);
    assert_eq!(models[0].default_reasoning_effort.as_deref(), Some("high"));
    assert_eq!(models[0].supported_reasoning_efforts.len(), 2);
}

#[test]
fn generated_thread_title_is_normalized() {
    assert_eq!(
        normalize_generated_thread_title("  \"Fix stale thread state.\"  "),
        Some("Fix stale thread state".to_string())
    );
    assert_eq!(normalize_generated_thread_title("Untitled thread"), None);
}

#[test]
fn generated_thread_title_prefers_structured_json_field() {
    assert_eq!(
        extract_generated_thread_title(Some(r#"{"title":"Add todo list to Flutter app"}"#)),
        Some("Add todo list to Flutter app".to_string())
    );
}

#[test]
fn thread_summary_ignores_preview_when_name_is_missing() {
    let summary = map_thread_summary(CodexThread {
        id: "thread-1".to_string(),
        name: None,
        preview: Some("This should stay a preview".to_string()),
        status: CodexThreadStatus {
            kind: "idle".to_string(),
        },
        cwd: "/Users/test/project".to_string(),
        path: None,
        git_info: Some(CodexGitInfo {
            branch: Some("main".to_string()),
            origin_url: Some("git@github.com:openai/codex-mobile-companion.git".to_string()),
        }),
        created_at: 0,
        updated_at: 0,
        source: json!("cli"),
        turns: Vec::new(),
    });

    assert_eq!(summary.title, "Untitled thread");
}

#[test]
fn rpc_and_archive_timelines_are_merged_without_losing_archive_freshness() {
    let rpc_entries = vec![ThreadTimelineEntryDto {
        event_id: "evt-msg".to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
        summary: "assistant message".to_string(),
        payload: json!({"text":"assistant message"}),
        annotations: None,
    }];

    let archive_entries = vec![
        ThreadTimelineEntryDto {
            event_id: "evt-msg-archive".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
            summary: "assistant message".to_string(),
            payload: json!({"text":"assistant message"}),
            annotations: None,
        },
        ThreadTimelineEntryDto {
            event_id: "evt-cmd".to_string(),
            kind: BridgeEventKind::CommandDelta,
            occurred_at: "2026-03-21T10:00:01.000Z".to_string(),
            summary: "Called exec_command".to_string(),
            payload: json!({"command":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}),
            annotations: None,
        },
    ];

    let selected = merge_rpc_and_archive_timeline_entries(rpc_entries, archive_entries);

    assert_eq!(selected.len(), 2);
    assert_eq!(selected[0].event_id, "evt-msg");
    assert_eq!(selected[1].kind, BridgeEventKind::CommandDelta);
}

#[test]
fn archive_entries_fill_gaps_when_rpc_snapshot_misses_latest_turn_messages() {
    let rpc_entries = vec![
        ThreadTimelineEntryDto {
            event_id: "status-running".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
            summary: "running".to_string(),
            payload: json!({"status":"running"}),
            annotations: None,
        },
        ThreadTimelineEntryDto {
            event_id: "status-completed".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-21T10:00:05.000Z".to_string(),
            summary: "completed".to_string(),
            payload: json!({"status":"completed"}),
            annotations: None,
        },
    ];
    let archive_entries = vec![
        ThreadTimelineEntryDto {
            event_id: "status-running".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
            summary: "running".to_string(),
            payload: json!({"status":"running"}),
            annotations: None,
        },
        ThreadTimelineEntryDto {
            event_id: "evt-user".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T10:00:01.000Z".to_string(),
            summary: "Why is formatter missing?".to_string(),
            payload: json!({"type":"userMessage","text":"Why is formatter missing?"}),
            annotations: None,
        },
        ThreadTimelineEntryDto {
            event_id: "evt-assistant".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T10:00:04.000Z".to_string(),
            summary: "Because dart is not on PATH.".to_string(),
            payload: json!({"type":"agentMessage","text":"Because dart is not on PATH."}),
            annotations: None,
        },
        ThreadTimelineEntryDto {
            event_id: "status-completed".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-21T10:00:05.000Z".to_string(),
            summary: "completed".to_string(),
            payload: json!({"status":"completed"}),
            annotations: None,
        },
    ];

    let merged = merge_rpc_and_archive_timeline_entries(rpc_entries, archive_entries);

    assert_eq!(merged.len(), 4);
    assert_eq!(merged[1].event_id, "evt-user");
    assert_eq!(merged[2].event_id, "evt-assistant");
}

#[test]
fn archive_fallback_surfaces_threads_when_live_list_is_empty() {
    let _env_lock = crate::test_support::lock_test_env();
    let codex_home =
        std::env::temp_dir().join(format!("gateway-archive-fallback-{}", std::process::id()));
    let claude_home = std::env::temp_dir().join(format!(
        "gateway-claude-archive-fallback-{}",
        std::process::id()
    ));
    let sessions_directory = codex_home.join("sessions/2026/03/23");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::create_dir_all(&claude_home).expect("test Claude home directory should exist");
    fs::write(
        sessions_directory.join("rollout-2026-03-23T18-04-18-thread-archive-no-index.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-23T18:04:20.876Z","type":"session_meta","payload":{"id":"thread-archive-no-index","timestamp":"2026-03-23T18:04:18.254Z","cwd":"/home/lubo/codex-mobile-companion/apps/linux-shell","source":"cli","git":{"branch":"main","repository_url":"git@github.com:openai/codex-mobile-companion.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-23T18:04:21.018Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let previous_codex_home = std::env::var_os("CODEX_HOME");
    let previous_claude_home = std::env::var_os("CLAUDE_HOME");
    unsafe {
        std::env::set_var("CODEX_HOME", &codex_home);
        std::env::set_var("CLAUDE_HOME", &claude_home);
    }

    let summaries = fetch_thread_summaries_from_archive(&BridgeCodexConfig {
        mode: CodexRuntimeMode::Spawn,
        endpoint: None,
        command: "definitely-missing-codex".to_string(),
        args: vec!["app-server".to_string()],
        desktop_ipc_socket_path: None,
    })
    .expect("archive fallback should load thread summaries");

    unsafe {
        if let Some(previous_codex_home) = previous_codex_home {
            std::env::set_var("CODEX_HOME", previous_codex_home);
        } else {
            std::env::remove_var("CODEX_HOME");
        }
        if let Some(previous_claude_home) = previous_claude_home {
            std::env::set_var("CLAUDE_HOME", previous_claude_home);
        } else {
            std::env::remove_var("CLAUDE_HOME");
        }
    }
    let _ = fs::remove_dir_all(&codex_home);
    let _ = fs::remove_dir_all(&claude_home);

    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].thread_id, "codex:thread-archive-no-index");
    assert_eq!(summaries[0].repository, "codex-mobile-companion");
}

#[test]
#[ignore = "requires a live local Codex app-server"]
fn live_create_thread_and_stream_turn_response() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime should build");
    runtime.block_on(async {
        let workspace = std::env::var("CODEX_LIVE_TEST_WORKSPACE")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| {
                std::env::current_dir()
                    .expect("cwd should resolve")
                    .display()
                    .to_string()
            });
        let codex_bin = std::env::var("CODEX_LIVE_TEST_CODEX_BIN")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "codex".to_string());

        let gateway = CodexGateway::new(BridgeCodexConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: None,
            command: codex_bin,
            args: vec!["app-server".to_string()],
            desktop_ipc_socket_path: None,
        });

        let create_started_at = Instant::now();
        let snapshot = tokio::time::timeout(
            Duration::from_secs(10),
            gateway.create_thread(ProviderKind::Codex, &workspace, None),
        )
        .await
        .expect("create_thread should not hang")
        .expect("create_thread should succeed");
        assert!(
            !snapshot.thread.thread_id.trim().is_empty(),
            "create_thread returned an empty thread id"
        );
        assert_eq!(snapshot.thread.workspace, workspace);
        eprintln!(
            "LIVE_GATEWAY_CREATE thread_id={} create_ms={}",
            snapshot.thread.thread_id,
            create_started_at.elapsed().as_millis()
        );

        let token = format!("LIVE_GATEWAY_TOKEN_{}", snapshot.thread.thread_id);
        let prompt = format!("Reply with exactly {token}");
        let (event_tx, event_rx) = mpsc::channel();
        gateway
            .start_turn_streaming(
                &snapshot.thread.thread_id,
                TurnStartRequest {
                    request_id: None,
                    prompt: prompt.clone(),
                    images: Vec::new(),
                    model: None,
                    effort: None,
                    permission_mode: None,
                },
                move |event| {
                    let _ = event_tx.send(event);
                },
                |_| Ok(None),
                |_| {},
                |_| {},
            )
            .expect("turn should start");

        let wait_deadline = Instant::now() + Duration::from_secs(60);
        let mut saw_token = false;
        while Instant::now() < wait_deadline {
            let Ok(event) = event_rx.recv_timeout(Duration::from_secs(5)) else {
                continue;
            };
            if event.kind != BridgeEventKind::MessageDelta {
                continue;
            }

            let payload_text =
                serde_json::to_string(&event.payload).expect("payload should serialize");
            if payload_text.contains(&token) {
                saw_token = true;
                break;
            }
        }

        assert!(
            saw_token,
            "did not observe assistant stream payload containing {token}"
        );
    });
}

#[test]
#[ignore = "requires a live local Codex app-server"]
fn live_regular_codex_flow_surfaces_search_read_and_edit_events() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime should build");
    runtime.block_on(async {
        let workspace = std::env::temp_dir().join(format!(
            "bridge-live-regular-flow-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should be after unix epoch")
                .as_nanos()
        ));
        fs::create_dir_all(workspace.join("docs")).expect("workspace should exist");
        let needle = format!("LIVE_BRIDGE_FLOW_NEEDLE_{}", std::process::id());
        fs::write(
            workspace.join("README.md"),
            "# Regular bridge flow probe\n\nNeedle file lives somewhere under docs/.\n"
                .to_string(),
        )
        .expect("readme should be writable");
        fs::write(
            workspace.join("docs/probe.txt"),
            format!("{needle}\nREGULAR_FLOW_CONFIRMATION=bridge flow working\n"),
        )
        .expect("probe file should be writable");

        let codex_bin = std::env::var("CODEX_LIVE_TEST_CODEX_BIN")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "codex".to_string());
        let gateway = CodexGateway::new(BridgeCodexConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: None,
            command: codex_bin,
            args: vec!["app-server".to_string()],
            desktop_ipc_socket_path: None,
        });

        let snapshot = tokio::time::timeout(
            Duration::from_secs(10),
            gateway.create_thread(
                ProviderKind::Codex,
                &workspace.display().to_string(),
                None,
            ),
        )
        .await
        .expect("create_thread should not hang")
        .expect("create_thread should succeed");
        let thread_id = snapshot.thread.thread_id.clone();

        let done_token = format!("BRIDGE_FLOW_DONE_{}", std::process::id());
        let output_relative_path = "output/result.txt";
        let output_path = workspace.join(output_relative_path);
        let prompt = format!(
            "Use workspace tools to do these steps in order: \
1. Search the workspace for the exact string {needle}. \
2. Read the file that contains that exact string. \
3. Create the file {output_relative_path} with exactly these two lines:\\nNeedle: {needle}\\nStatus: bridge flow working\\n\
After completing those steps, reply with exactly {done_token}."
        );

        let (event_tx, event_rx) = mpsc::channel();
        let (completed_tx, completed_rx) = mpsc::channel();
        gateway
            .start_turn_streaming(
                &thread_id,
                TurnStartRequest {
                    request_id: None,
                    prompt,
                    images: Vec::new(),
                    model: None,
                    effort: None,
                    permission_mode: None,
                },
                move |event| {
                    let _ = event_tx.send(event);
                },
                move |control| match control {
                    GatewayTurnControlRequest::CodexApproval { method, params, .. } => {
                        let response = match method.as_str() {
                            "item/commandExecution/requestApproval"
                            | "item/fileChange/requestApproval" => {
                                json!({"decision":"acceptForSession"})
                            }
                            "item/permissions/requestApproval" => json!({
                                "permissions": params
                                    .get("permissions")
                                    .cloned()
                                    .unwrap_or_else(|| json!({})),
                                "scope": "session",
                            }),
                            _ => return Ok(None),
                        };
                        Ok(Some(response))
                    }
                    _ => Ok(None),
                },
                move |_| {
                    let _ = completed_tx.send(());
                },
                |_| {},
            )
            .expect("turn should start");

        completed_rx
            .recv_timeout(Duration::from_secs(120))
            .expect("turn should complete");

        let mut events = Vec::new();
        while let Ok(event) = event_rx.recv_timeout(Duration::from_millis(100)) {
            events.push(event);
        }

        assert!(
            events.iter().any(|event| {
                event.kind == BridgeEventKind::CommandDelta && {
                    let payload = serde_json::to_string(&event.payload).unwrap_or_default();
                    payload.contains("rg -n")
                        || payload.contains("\"rg ")
                        || payload.contains("grep ")
                        || payload.contains("find ")
                }
            }),
            "expected a search command event in the live turn"
        );
        assert!(
            events.iter().any(|event| {
                event.kind == BridgeEventKind::CommandDelta && {
                    let payload = serde_json::to_string(&event.payload).unwrap_or_default();
                    payload.contains("docs/probe.txt")
                        && (payload.contains("sed -n")
                            || payload.contains("cat ")
                            || payload.contains("head ")
                            || payload.contains("tail "))
                }
            }),
            "expected a read command event in the live turn"
        );
        assert!(
            events.iter().any(|event| {
                event.kind == BridgeEventKind::FileChange
                    && serde_json::to_string(&event.payload)
                        .map(|payload| payload.contains(output_relative_path))
                        .unwrap_or(false)
            }),
            "expected a file change event in the live turn"
        );
        assert!(
            events.iter().any(|event| {
                event.kind == BridgeEventKind::MessageDelta
                    && serde_json::to_string(&event.payload)
                        .map(|payload| payload.contains(&done_token))
                        .unwrap_or(false)
            }),
            "expected the final assistant token in the live turn"
        );
        assert_eq!(
            fs::read_to_string(&output_path).expect("output file should exist"),
            format!("Needle: {needle}\nStatus: bridge flow working\n")
        );

        let _ = fs::remove_dir_all(&workspace);
    });
}
