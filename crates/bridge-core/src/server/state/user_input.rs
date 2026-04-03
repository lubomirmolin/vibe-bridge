use super::*;

pub(super) fn build_hidden_plan_question_prompt(user_prompt: &str) -> String {
    format!(
        concat!(
            "You are running in mobile plan intake mode.\n",
            "Do not edit files, do not run commands, and do not produce the plan yet.\n",
            "Return only one XML-like block with no markdown fences and no extra prose.\n",
            "Use this exact wrapper: <codex-plan-questions>{{JSON}}</codex-plan-questions>\n",
            "The JSON must contain:\n",
            "- title: short string\n",
            "- detail: short string\n",
            "- questions: array of 1 to 3 questions\n",
            "Each question must contain question_id, prompt, and exactly 3 options.\n",
            "Each option must contain option_id, label, description, and is_recommended.\n",
            "Keep the choices mutually exclusive and concise.\n",
            "Original user request:\n{user_prompt}\n"
        ),
        user_prompt = user_prompt
    )
}

pub(super) fn build_hidden_plan_followup_prompt(
    original_prompt: &str,
    questionnaire: &PendingUserInputDto,
    answers: &[UserInputAnswerDto],
    free_text: Option<&str>,
) -> String {
    format!(
        concat!(
            "You are continuing a mobile planning workflow.\n",
            "Do not edit files or run commands.\n",
            "Use the user's original request plus their selected answers to produce a concrete execution plan.\n",
            "If appropriate, emit update_plan with 3 to 7 actionable steps.\n",
            "After the plan, summarize the main tradeoffs briefly.\n\n",
            "Original request:\n{original_prompt}\n\n",
            "Questionnaire:\n{questionnaire_json}\n\n",
            "Selected answers:\n{answers_json}\n\n",
            "Additional free text:\n{free_text}\n"
        ),
        original_prompt = original_prompt,
        questionnaire_json =
            serde_json::to_string_pretty(questionnaire).unwrap_or_else(|_| "{}".to_string()),
        answers_json = serde_json::to_string_pretty(answers).unwrap_or_else(|_| "[]".to_string()),
        free_text = free_text.unwrap_or(""),
    )
}

pub(super) fn render_user_input_response_summary(
    questionnaire: &PendingUserInputDto,
    answers: &[UserInputAnswerDto],
    free_text: Option<&str>,
) -> String {
    let mut lines = vec!["Plan clarification".to_string()];

    for answer in answers {
        let question_prompt = questionnaire
            .questions
            .iter()
            .find(|question| question.question_id == answer.question_id)
            .map(|question| question.prompt.as_str())
            .unwrap_or("Question");
        let option_label = questionnaire
            .questions
            .iter()
            .find(|question| question.question_id == answer.question_id)
            .and_then(|question| {
                question
                    .options
                    .iter()
                    .find(|option| option.option_id == answer.option_id)
            })
            .map(|option| option.label.as_str())
            .unwrap_or("Selected");
        lines.push(format!("- {question_prompt}: {option_label}"));
    }

    if let Some(free_text) = free_text {
        lines.push(format!("- Something else: {free_text}"));
    }

    lines.join("\n")
}

pub(super) fn parse_provider_approval_selection(
    answers: &[UserInputAnswerDto],
) -> Option<ProviderApprovalSelection> {
    let selected_option_id = answers
        .iter()
        .find(|answer| answer.question_id == "approval_decision")
        .or_else(|| answers.first())
        .map(|answer| answer.option_id.as_str())?;
    match selected_option_id {
        USER_INPUT_OPTION_ALLOW_ONCE => Some(ProviderApprovalSelection::AllowOnce),
        USER_INPUT_OPTION_ALLOW_SESSION => Some(ProviderApprovalSelection::AllowForSession),
        USER_INPUT_OPTION_DENY => Some(ProviderApprovalSelection::Deny),
        _ => None,
    }
}

pub(super) fn looks_like_provider_approval_questionnaire(
    questionnaire: &PendingUserInputDto,
) -> bool {
    questionnaire.questions.len() == 1
        && questionnaire.questions[0].question_id == "approval_decision"
        && questionnaire.questions[0]
            .options
            .iter()
            .map(|option| option.option_id.as_str())
            .eq([
                USER_INPUT_OPTION_ALLOW_ONCE,
                USER_INPUT_OPTION_ALLOW_SESSION,
                USER_INPUT_OPTION_DENY,
            ])
}

pub(super) fn build_provider_approval_questionnaire(
    thread_id: &str,
    title: String,
    detail: Option<String>,
) -> PendingUserInputDto {
    PendingUserInputDto {
        request_id: format!(
            "provider-approval-{}-{}",
            thread_id,
            Utc::now().timestamp_millis()
        ),
        title,
        detail,
        questions: vec![UserInputQuestionDto {
            question_id: "approval_decision".to_string(),
            prompt: "Choose an action".to_string(),
            options: vec![
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_ALLOW_ONCE.to_string(),
                    label: "Allow once".to_string(),
                    description: "Approve this action one time.".to_string(),
                    is_recommended: true,
                },
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_ALLOW_SESSION.to_string(),
                    label: "Allow for session".to_string(),
                    description: "Approve now and remember for this session.".to_string(),
                    is_recommended: false,
                },
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_DENY.to_string(),
                    label: "Deny".to_string(),
                    description: "Deny this action and interrupt the turn.".to_string(),
                    is_recommended: false,
                },
            ],
        }],
    }
}

fn stringify_provider_request_id(raw_request_id: &Value) -> String {
    if let Some(text) = raw_request_id.as_str() {
        return text.to_string();
    }
    if let Some(value) = raw_request_id.as_i64() {
        return value.to_string();
    }
    if let Some(value) = raw_request_id.as_u64() {
        return value.to_string();
    }
    raw_request_id.to_string()
}

fn join_optional_detail_lines(lines: impl IntoIterator<Item = Option<String>>) -> Option<String> {
    let lines = lines
        .into_iter()
        .flatten()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    (!lines.is_empty()).then(|| lines.join("\n"))
}

pub(super) fn build_pending_provider_approval_from_codex(
    fallback_thread_id: &str,
    raw_request_id: &Value,
    method: &str,
    params: &Value,
) -> Result<Option<ProviderApprovalPrompt>, String> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback_thread_id);
    let reason = params
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let prompt = match method {
        "item/commandExecution/requestApproval" => {
            let command = params
                .get("command")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Command: {value}"));
            let cwd = params
                .get("cwd")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Working directory: {value}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve command execution?".to_string(),
                    join_optional_detail_lines([reason, command, cwd]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexCommandOrFile,
            })
        }
        "item/fileChange/requestApproval" => {
            let grant_root = params
                .get("grantRoot")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Requested write root: {value}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve file changes?".to_string(),
                    join_optional_detail_lines([reason, grant_root]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexCommandOrFile,
            })
        }
        "item/permissions/requestApproval" => {
            let turn_id = params
                .get("turnId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let requested_permissions = params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let permission_summary = summarize_codex_requested_permissions(&requested_permissions)
                .map(|summary| format!("Requested permissions: {summary}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve additional permissions?".to_string(),
                    join_optional_detail_lines([reason, permission_summary]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexPermissions { turn_id },
            })
        }
        _ => None,
    };
    Ok(prompt)
}

fn summarize_codex_requested_permissions(permissions: &Value) -> Option<String> {
    let mut parts = Vec::new();
    let file_system = permissions.get("fileSystem");
    let read_paths = file_system
        .and_then(|profile| profile.get("read"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let write_paths = file_system
        .and_then(|profile| profile.get("write"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    if read_paths > 0 {
        parts.push(format!("read paths: {read_paths}"));
    }
    if write_paths > 0 {
        parts.push(format!("write paths: {write_paths}"));
    }
    if permissions
        .get("network")
        .and_then(|profile| profile.get("enabled"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        parts.push("network access".to_string());
    }
    (!parts.is_empty()).then(|| parts.join(", "))
}

pub(super) fn build_codex_approval_response(
    method: &str,
    params: &Value,
    selection: ProviderApprovalSelection,
) -> Result<Value, String> {
    let response = match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            let decision = match selection {
                ProviderApprovalSelection::AllowOnce => "accept",
                ProviderApprovalSelection::AllowForSession => "acceptForSession",
                ProviderApprovalSelection::Deny => "cancel",
            };
            json!({ "decision": decision })
        }
        "item/permissions/requestApproval" => {
            let requested_permissions = params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match selection {
                ProviderApprovalSelection::AllowOnce => json!({
                    "permissions": requested_permissions,
                    "scope": "turn",
                }),
                ProviderApprovalSelection::AllowForSession => json!({
                    "permissions": requested_permissions,
                    "scope": "session",
                }),
                ProviderApprovalSelection::Deny => json!({
                    "permissions": {},
                    "scope": "turn",
                }),
            }
        }
        _ => return Err(format!("unsupported codex approval method: {method}")),
    };
    Ok(response)
}

pub(super) fn build_pending_provider_approval_from_claude(
    thread_id: &str,
    request_id: String,
    request: Value,
) -> Result<ProviderApprovalPrompt, String> {
    if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
        return Err("unsupported Claude control request subtype".to_string());
    }
    let tool_name = request
        .get("display_name")
        .or_else(|| request.get("tool_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("tool");
    let detail = join_optional_detail_lines([
        request
            .get("description")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        summarize_claude_tool_input(request.get("input")),
    ]);
    let context = ProviderApprovalContext::ClaudeCanUseTool;
    Ok(ProviderApprovalPrompt {
        questionnaire: build_provider_approval_questionnaire(
            thread_id,
            format!("Approve {tool_name}?"),
            detail,
        ),
        provider_request_id: request_id,
        context,
    })
}

fn summarize_claude_tool_input(raw_input: Option<&Value>) -> Option<String> {
    let Some(input) = raw_input else {
        return None;
    };
    let Some(input_map) = input.as_object() else {
        return None;
    };
    let summary = input_map
        .iter()
        .take(3)
        .map(|(key, value)| {
            let formatted = value
                .as_str()
                .map(ToString::to_string)
                .unwrap_or_else(|| value.to_string());
            format!("{key}: {formatted}")
        })
        .collect::<Vec<_>>()
        .join(", ");
    (!summary.is_empty()).then(|| format!("Input: {summary}"))
}

pub(super) fn build_claude_tool_approval_response(
    selection: ProviderApprovalSelection,
    request: &Value,
) -> Value {
    let mut response = match selection {
        ProviderApprovalSelection::AllowOnce | ProviderApprovalSelection::AllowForSession => {
            json!({
                "behavior": "allow",
                "updatedInput": request
                    .get("input")
                    .cloned()
                    .unwrap_or_else(|| Value::Object(serde_json::Map::new())),
            })
        }
        ProviderApprovalSelection::Deny => json!({
            "behavior": "deny",
            "message": "Permission denied by mobile approval.",
            "interrupt": true,
        }),
    };
    if let Some(object) = response.as_object_mut() {
        if let Some(tool_use_id) = request.get("tool_use_id").and_then(Value::as_str) {
            object.insert(
                "toolUseID".to_string(),
                Value::String(tool_use_id.to_string()),
            );
        }
        if selection == ProviderApprovalSelection::AllowForSession
            && let Some(suggestions) = request.get("permission_suggestions")
        {
            object.insert("updatedPermissions".to_string(), suggestions.clone());
        }
    }
    response
}

pub(in crate::server) fn parse_pending_user_input_payload(
    message_text: &str,
    thread_id: &str,
) -> Option<PendingUserInputDto> {
    let start = message_text.find("<codex-plan-questions>")?;
    let end = message_text.find("</codex-plan-questions>")?;
    if end <= start {
        return None;
    }

    let json_payload = message_text[start + "<codex-plan-questions>".len()..end].trim();
    let parsed = serde_json::from_str::<Value>(json_payload).ok()?;
    let title = parsed
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Clarify the plan")
        .to_string();
    let detail = parsed
        .get("detail")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    let questions = parsed
        .get("questions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let prompt = entry
                .get("prompt")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?;
            let question_id = entry
                .get("question_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| sanitize_user_input_id(prompt));
            let options = entry
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|option| {
                    let label = option
                        .get("label")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())?;
                    Some(UserInputOptionDto {
                        option_id: option
                            .get("option_id")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string)
                            .unwrap_or_else(|| sanitize_user_input_id(label)),
                        label: label.to_string(),
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .unwrap_or_default()
                            .to_string(),
                        is_recommended: option
                            .get("is_recommended")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    })
                })
                .take(3)
                .collect::<Vec<_>>();

            if options.len() != 3 {
                return None;
            }

            Some(UserInputQuestionDto {
                question_id,
                prompt: prompt.to_string(),
                options,
            })
        })
        .take(3)
        .collect::<Vec<_>>();

    if questions.is_empty() {
        return None;
    }

    Some(PendingUserInputDto {
        request_id: format!("user-input-{}-{}", thread_id, Utc::now().timestamp_millis()),
        title,
        detail,
        questions,
    })
}

fn sanitize_user_input_id(value: &str) -> String {
    let mut identifier = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    while identifier.contains("--") {
        identifier = identifier.replace("--", "-");
    }
    identifier.trim_matches('-').to_string()
}

pub(super) fn build_hidden_commit_prompt() -> String {
    r#"<app-context>
Mobile quick action: the user tapped Commit in the current session. In the visible thread transcript, the user message should appear as exactly:

Commit

Treat that visible message as the full user request.

Analyze the current workspace changes for this session.
Stage only files that belong to the current task or clear logical units.
Split commits logically when the changes should not land as one commit.
Use concise commit messages consistent with the repository style.
If there are unrelated, risky, or incomplete changes, leave them unstaged and explain why.
If there is nothing appropriate to commit, say that clearly and do not create an empty commit.
After you finish, respond with a short summary of the commit split you made, including commit messages and any skipped files.
</app-context>"#
        .to_string()
}
