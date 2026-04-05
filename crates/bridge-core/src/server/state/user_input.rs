use super::*;

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

#[cfg(test)]
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
        workflow_kind: Some(PROVIDER_APPROVAL_WORKFLOW_KIND.to_string()),
        original_prompt: None,
        provider_request_id: None,
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

pub(super) fn stringify_request_id(raw_request_id: &Value) -> String {
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
            let provider_request_id = stringify_request_id(raw_request_id);
            Some(ProviderApprovalPrompt {
                questionnaire: with_provider_request_context(
                    build_provider_approval_questionnaire(
                        thread_id,
                        "Approve command execution?".to_string(),
                        join_optional_detail_lines([reason, command, cwd]),
                    ),
                    &provider_request_id,
                ),
                provider_request_id,
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
            let provider_request_id = stringify_request_id(raw_request_id);
            Some(ProviderApprovalPrompt {
                questionnaire: with_provider_request_context(
                    build_provider_approval_questionnaire(
                        thread_id,
                        "Approve file changes?".to_string(),
                        join_optional_detail_lines([reason, grant_root]),
                    ),
                    &provider_request_id,
                ),
                provider_request_id,
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
            let provider_request_id = stringify_request_id(raw_request_id);
            Some(ProviderApprovalPrompt {
                questionnaire: with_provider_request_context(
                    build_provider_approval_questionnaire(
                        thread_id,
                        "Approve additional permissions?".to_string(),
                        join_optional_detail_lines([reason, permission_summary]),
                    ),
                    &provider_request_id,
                ),
                provider_request_id,
                context: ProviderApprovalContext::CodexPermissions { turn_id },
            })
        }
        _ => None,
    };
    Ok(prompt)
}

pub(super) fn build_pending_plan_questionnaire_from_codex_request(
    raw_request_id: &Value,
    params: &Value,
    original_prompt: &str,
) -> Option<PendingUserInputDto> {
    let questions = params
        .get("questions")
        .and_then(Value::as_array)?
        .iter()
        .filter_map(|question| {
            let question_id = question
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)?;
            let prompt = question
                .get("question")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .or_else(|| {
                    question
                        .get("header")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                })?;

            let mut options = question
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
                    let (normalized_label, is_recommended) =
                        parse_codex_request_user_input_option_label(label);
                    Some(UserInputOptionDto {
                        option_id: sanitize_user_input_id(&normalized_label),
                        label: normalized_label,
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .unwrap_or_default()
                            .to_string(),
                        is_recommended,
                    })
                })
                .collect::<Vec<_>>();

            if question
                .get("isOther")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                options.push(UserInputOptionDto {
                    option_id: "something_else".to_string(),
                    label: "Something else".to_string(),
                    description: "Provide a custom response below.".to_string(),
                    is_recommended: false,
                });
            }

            if options.is_empty() {
                options.push(UserInputOptionDto {
                    option_id: "freeform_response".to_string(),
                    label: "Respond below".to_string(),
                    description: "Type your response below and submit it.".to_string(),
                    is_recommended: true,
                });
            }

            Some(UserInputQuestionDto {
                question_id,
                prompt: prompt.to_string(),
                options,
            })
        })
        .collect::<Vec<_>>();
    if questions.is_empty() {
        return None;
    }

    let title = params
        .get("questions")
        .and_then(Value::as_array)
        .and_then(|questions| questions.first())
        .and_then(|question| question.get("header"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Clarify the plan")
        .to_string();
    let provider_request_id = params
        .get("itemId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    Some(PendingUserInputDto {
        request_id: stringify_request_id(raw_request_id),
        title,
        detail: Some(
            "Answer the plan questions below. Codex will continue the same turn after you submit."
                .to_string(),
        ),
        workflow_kind: Some(PLAN_WORKFLOW_KIND.to_string()),
        original_prompt: Some(original_prompt.trim().to_string()),
        provider_request_id,
        questions,
    })
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
    let questionnaire = with_provider_request_context(
        build_provider_approval_questionnaire(thread_id, format!("Approve {tool_name}?"), detail),
        &request_id,
    );
    Ok(ProviderApprovalPrompt {
        questionnaire,
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

pub(super) fn build_codex_request_user_input_response(
    questionnaire: &PendingUserInputDto,
    answers: &[UserInputAnswerDto],
    free_text: Option<&str>,
) -> Value {
    let selected_option_by_question_id = answers
        .iter()
        .map(|answer| (answer.question_id.as_str(), answer.option_id.as_str()))
        .collect::<HashMap<_, _>>();
    let free_text = free_text
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let free_text_target_question_id = questionnaire
        .questions
        .iter()
        .find(|question| {
            selected_option_by_question_id
                .get(question.question_id.as_str())
                .is_some_and(|option_id| {
                    matches!(*option_id, "something_else" | "freeform_response")
                })
        })
        .map(|question| question.question_id.as_str())
        .or_else(|| {
            questionnaire
                .questions
                .iter()
                .find(|question| {
                    selected_option_by_question_id.contains_key(question.question_id.as_str())
                })
                .map(|question| question.question_id.as_str())
        })
        .or_else(|| {
            questionnaire
                .questions
                .first()
                .map(|question| question.question_id.as_str())
        });

    let answers_by_question_id = questionnaire
        .questions
        .iter()
        .map(|question| {
            let mut answer_list = Vec::new();
            if let Some(selected_option_id) =
                selected_option_by_question_id.get(question.question_id.as_str())
                && let Some(selected_option) = question
                    .options
                    .iter()
                    .find(|option| option.option_id == *selected_option_id)
                && !matches!(
                    selected_option.option_id.as_str(),
                    "something_else" | "freeform_response"
                )
            {
                answer_list.push(selected_option.label.clone());
            }
            if free_text_target_question_id == Some(question.question_id.as_str())
                && let Some(free_text) = free_text.as_ref()
            {
                answer_list.push(format!("user_note: {free_text}"));
            }
            (
                question.question_id.clone(),
                json!({
                    "answers": answer_list,
                }),
            )
        })
        .collect::<serde_json::Map<_, _>>();

    json!({
        "answers": answers_by_question_id,
    })
}

pub(super) fn with_provider_request_context(
    mut questionnaire: PendingUserInputDto,
    provider_request_id: &str,
) -> PendingUserInputDto {
    questionnaire.workflow_kind = Some(PROVIDER_APPROVAL_WORKFLOW_KIND.to_string());
    questionnaire.provider_request_id = Some(provider_request_id.to_string());
    questionnaire
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

fn parse_codex_request_user_input_option_label(label: &str) -> (String, bool) {
    let trimmed = label.trim();
    if let Some(normalized) = trimmed.strip_suffix("(Recommended)") {
        return (normalized.trim().to_string(), true);
    }
    (trimmed.to_string(), false)
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
