use super::*;

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
    assert_eq!(threads[0].id, codex_thread_id("thread-archive-1"));
    assert_eq!(threads[0].headline, "Investigate fallback");
    assert_eq!(threads[0].repository_name, "project");
    assert_eq!(threads[0].branch_name, "main");
    assert_eq!(threads[0].workspace_path, "/Users/test/workspace");
    assert_eq!(threads[0].source, "cli");

    let thread_timeline = timeline
        .get(&codex_thread_id("thread-archive-1"))
        .expect("timeline should exist for archived thread");
    assert_eq!(thread_timeline.len(), 2);
    assert_eq!(thread_timeline[0].event_type, "agent_message_delta");
    assert_eq!(thread_timeline[1].event_type, "command_output_delta");

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn archived_codex_sessions_load_without_session_index() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/23");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
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

    let (threads, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load without session index");

    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].id, codex_thread_id("thread-archive-no-index"));
    assert_eq!(
        threads[0].workspace_path,
        "/home/lubo/codex-mobile-companion/apps/linux-shell"
    );
    assert_eq!(threads[0].repository_name, "codex-mobile-companion");
    assert_eq!(threads[0].branch_name, "main");
    assert!(
        timeline.contains_key(&codex_thread_id("thread-archive-no-index")),
        "timeline should exist for discovered archive thread"
    );

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
        .get(&codex_thread_id("thread-archive-tools"))
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
        .get(&codex_thread_id("thread-archive-delete"))
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
        .get(&codex_thread_id("thread-archive-filtered"))
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
        .get(&codex_thread_id("thread-archive-legacy"))
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

    let requested_ids = HashSet::from([codex_thread_id("thread-target")]);
    let (_, timeline_by_thread_id) =
        super::load_thread_snapshot_from_codex_archive_for_ids(&codex_home, Some(&requested_ids))
            .expect("requested archive snapshot should load");

    let timeline = timeline_by_thread_id
        .get(&codex_thread_id("thread-target"))
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
    assert_eq!(records[0].id, codex_thread_id(requested_id));
    let timeline = timeline_by_thread_id
        .get(&codex_thread_id(requested_id))
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
        .get(&codex_thread_id(&thread_id))
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
        .get(&codex_thread_id(&thread_id))
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
            id: codex_thread_id("thread-123"),
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            codex_thread_id("thread-123"),
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
            id: codex_thread_id("thread-123"),
            native_id: "thread-123".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            codex_thread_id("thread-123"),
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
        .get(&codex_thread_id("thread-123"))
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
            id: codex_thread_id("thread-merge-dedupe"),
            native_id: "thread-merge-dedupe".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            codex_thread_id("thread-merge-dedupe"),
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
            id: codex_thread_id("thread-merge-dedupe"),
            native_id: "thread-merge-dedupe".to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            codex_thread_id("thread-merge-dedupe"),
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
        .get(&codex_thread_id("thread-merge-dedupe"))
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
    let thread_id = codex_thread_id("019d0d0c-07df-7632-81fa-a1636651400a");
    let rpc_snapshot = (
        vec![UpstreamThreadRecord {
            id: thread_id.clone(),
            native_id: thread_id.to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
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
            id: thread_id.clone(),
            native_id: thread_id.to_string(),
            provider: shared_contracts::ProviderKind::Codex,
            client: shared_contracts::ThreadClientKind::Cli,
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
            thread_id.clone(),
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
    assert_eq!(merged_record.lifecycle_state, "active");
    assert_eq!(
        merged_record.last_turn_summary,
        "All of the old local app/server processes are down."
    );
    assert_eq!(merged_record.updated_at, "2026-03-20T21:40:09.107Z");

    let detail = super::map_thread_detail(merged_record);
    assert_eq!(detail.status, ThreadStatus::Running);
    assert_eq!(
        detail.last_turn_summary,
        "All of the old local app/server processes are down."
    );
    assert_eq!(detail.updated_at, "2026-03-20T21:40:09.107Z");

    let timeline = timeline_by_thread_id
        .get(&thread_id)
        .expect("merged timeline should exist");
    assert_eq!(timeline.len(), 2);
    assert_eq!(timeline[1].id, format!("{thread_id}-archive-2"));
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
        .get(&codex_thread_id("thread-archive-images"))
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
fn archived_claude_style_user_message_images_become_data_urls() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-claude-images","thread_name":"Archive Claude images","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-claude-images.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-claude-images","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Here is the screenshot."},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get(&codex_thread_id("thread-archive-claude-images"))
        .expect("timeline should exist for archived thread");

    assert_eq!(thread_timeline.len(), 1);
    assert_eq!(thread_timeline[0].data["type"], "userMessage");
    assert_eq!(
        thread_timeline[0].data["content"][0]["text"],
        "Here is the screenshot."
    );
    assert_eq!(
        thread_timeline[0].data["content"][1]["image_url"],
        "data:image/png;base64,QUJD"
    );

    let _ = fs::remove_dir_all(codex_home);
}

#[test]
fn claude_archive_prefers_explicit_titles_over_slug() {
    let claude_home = unique_test_codex_home();
    let project_directory =
        claude_home.join("projects/-Users-test-PhpstormProjects-codex-mobile-companion");
    fs::create_dir_all(&project_directory).expect("test Claude projects directory should exist");

    let session_path = project_directory.join("thread-claude-title.jsonl");
    fs::write(
        &session_path,
        concat!(
            r#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-03-31T17:33:19.787Z","sessionId":"thread-claude-title","content":"Hello"}"#,
            "\n",
            r#"{"parentUuid":null,"isSidechain":false,"promptId":"prompt-1","type":"user","message":{"role":"user","content":"Hello from Claude"},"uuid":"user-1","timestamp":"2026-03-31T17:33:19.799Z","permissionMode":"default","userType":"external","entrypoint":"sdk-cli","cwd":"/Users/test/PhpstormProjects/codex-mobile-companion","sessionId":"thread-claude-title","version":"2.1.87","gitBranch":"develop","slug":"glistening-sleeping-seahorse"}"#,
            "\n",
            r#"{"type":"ai-title","sessionId":"thread-claude-title","aiTitle":"Fix bridge title parsing"}"#,
            "\n",
            r#"{"type":"custom-title","sessionId":"thread-claude-title","customTitle":"Bridge title regression"}"#,
            "\n"
        ),
    )
    .expect("Claude session log should be writable");

    let (threads, _) = super::load_thread_snapshot_from_claude_archive_for_ids(&claude_home, None)
        .expect("Claude archive should load");

    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].id, claude_thread_id("thread-claude-title"));
    assert_eq!(threads[0].headline, "Bridge title regression");
    assert_eq!(
        threads[0].workspace_path,
        "/Users/test/PhpstormProjects/codex-mobile-companion"
    );
    assert_eq!(threads[0].branch_name, "develop");
    assert_eq!(threads[0].source, "sdk-cli");

    let _ = fs::remove_dir_all(claude_home);
}

#[test]
fn archived_update_plan_function_calls_become_plan_timeline_events() {
    let codex_home = unique_test_codex_home();
    let sessions_directory = codex_home.join("sessions/2026/03/19");
    fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
    fs::write(
        codex_home.join("session_index.jsonl"),
        r#"{"id":"thread-archive-plan","thread_name":"Archive plan","updated_at":"2026-03-19T10:00:00Z"}"#,
    )
    .expect("session index should be writable");
    fs::write(
        sessions_directory.join("rollout-2026-03-19T10-00-00-thread-archive-plan.jsonl"),
        concat!(
            r#"{"timestamp":"2026-03-19T09:55:00Z","type":"session_meta","payload":{"id":"thread-archive-plan","timestamp":"2026-03-19T09:55:00Z","cwd":"/Users/test/workspace","source":"cli","git":{"branch":"main","repository_url":"git@github.com:example/project.git"}}}"#,
            "\n",
            r#"{"timestamp":"2026-03-19T09:56:00Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Inspect bridge payload\",\"status\":\"completed\"},{\"step\":\"Add Flutter card\",\"status\":\"in_progress\"},{\"step\":\"Run tests\",\"status\":\"pending\"}]}"}}"#,
            "\n"
        ),
    )
    .expect("session log should be writable");

    let (_, timeline) = super::load_thread_snapshot_from_codex_archive(&codex_home)
        .expect("archive fallback should load");

    let thread_timeline = timeline
        .get(&codex_thread_id("thread-archive-plan"))
        .expect("timeline should exist for archived thread");

    assert_eq!(thread_timeline.len(), 1);
    assert_eq!(thread_timeline[0].event_type, "plan_delta");
    assert_eq!(thread_timeline[0].data["completed_count"], 1);
    assert_eq!(thread_timeline[0].data["total_count"], 3);
    assert_eq!(
        thread_timeline[0].data["steps"][1]["status"].as_str(),
        Some("in_progress")
    );

    let _ = fs::remove_dir_all(codex_home);
}
