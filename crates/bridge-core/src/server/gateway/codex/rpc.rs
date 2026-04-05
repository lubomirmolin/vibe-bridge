use super::super::*;

pub(super) fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

pub(super) fn should_read_without_turns(error: &str) -> bool {
    error.contains("includeTurns is unavailable before first user message")
        || error.contains("is not materialized yet")
}

pub(super) fn read_thread_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    match read_thread(transport, thread_id, include_turns) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            resume_thread(transport, thread_id)?;
            read_thread(transport, thread_id, include_turns)
        }
        Err(error) => Err(error),
    }
}

fn read_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/read",
        serde_json::json!({
            "threadId": native_thread_id,
            "includeTurns": include_turns,
        }),
    )?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/read response from codex: {error}"))
}

fn resume_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
) -> Result<CodexThread, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/resume",
        serde_json::json!({
            "threadId": native_thread_id,
        }),
    )?;
    let payload: CodexThreadResumeResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/resume response from codex: {error}"))?;
    Ok(payload.thread)
}

pub(super) fn start_turn_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
    mode: TurnMode,
) -> Result<CodexTurnStartResult, String> {
    match start_turn(transport, thread_id, prompt, images, model, effort, mode) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            if let Err(resume_error) = resume_thread(transport, thread_id)
                && !resume_error.contains("no rollout found")
            {
                return Err(resume_error);
            }
            start_turn(transport, thread_id, prompt, images, model, effort, mode)
        }
        Err(error) => Err(error),
    }
}

pub(super) fn start_ephemeral_read_only_thread(
    transport: &mut CodexJsonTransport,
    workspace: &str,
    model: Option<&str>,
) -> Result<String, String> {
    let mut params = serde_json::Map::new();
    params.insert("cwd".to_string(), Value::String(workspace.to_string()));
    params.insert(
        "approvalPolicy".to_string(),
        Value::String("never".to_string()),
    );
    params.insert(
        "sandbox".to_string(),
        Value::String("read-only".to_string()),
    );
    params.insert("ephemeral".to_string(), Value::Bool(true));
    params.insert("persistExtendedHistory".to_string(), Value::Bool(false));
    params.insert("experimentalRawEvents".to_string(), Value::Bool(false));
    params.insert(
        "config".to_string(),
        json!({
            "web_search": "disabled",
            "model_reasoning_effort": "low",
        }),
    );
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }

    let response = transport.request("thread/start", Value::Object(params))?;
    let payload: CodexThreadStartResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/start response from codex: {error}"))?;
    Ok(payload.thread.id)
}

pub(super) fn start_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
    mode: TurnMode,
) -> Result<CodexTurnStartResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let mut params = serde_json::Map::new();
    params.insert(
        "threadId".to_string(),
        Value::String(native_thread_id.to_string()),
    );
    params.insert("input".to_string(), build_turn_start_input(prompt, images));
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }
    if let Some(collaboration_mode) = build_turn_start_collaboration_mode(mode, model, effort) {
        params.insert("collaborationMode".to_string(), collaboration_mode);
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

fn build_turn_start_collaboration_mode(
    mode: TurnMode,
    model: Option<&str>,
    effort: Option<&str>,
) -> Option<Value> {
    if mode != TurnMode::Plan {
        return None;
    }

    let mode_model = model
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("gpt-5");
    let mut settings = serde_json::Map::new();
    settings.insert("model".to_string(), Value::String(mode_model.to_string()));
    if let Some(effort) = effort.map(str::trim).filter(|value| !value.is_empty()) {
        settings.insert(
            "reasoningEffort".to_string(),
            Value::String(effort.to_string()),
        );
    }
    settings.insert("developerInstructions".to_string(), Value::Null);

    Some(json!({
        "mode": "plan",
        "settings": Value::Object(settings),
    }))
}

pub(super) fn start_structured_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    output_schema: Value,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_string(), Value::String(thread_id.to_string()));
    params.insert("input".to_string(), build_turn_start_input(prompt, &[]));
    params.insert("summary".to_string(), Value::String("auto".to_string()));
    params.insert("outputSchema".to_string(), output_schema);
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

pub(crate) fn build_turn_start_input(prompt: &str, images: &[String]) -> Value {
    let mut input = Vec::new();
    if !prompt.trim().is_empty() {
        input.push(serde_json::json!({
            "type": "text",
            "text": prompt,
            "text_elements": [],
        }));
    }
    for image in images
        .iter()
        .map(|image| image.trim())
        .filter(|image| !image.is_empty())
    {
        input.push(serde_json::json!({
            "type": "image",
            "url": image,
        }));
    }

    Value::Array(input)
}

pub(super) fn read_structured_agent_message(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    turn_id: &str,
    context: &str,
) -> Result<Option<String>, String> {
    let mut latest_agent_message: Option<String> = None;

    while let Some(message) = transport.next_message(context)? {
        if message.get("id").is_some() {
            continue;
        }

        let Some(method) = message.get("method").and_then(Value::as_str) else {
            continue;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        match method {
            "item/agentMessage/delta" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let delta = params
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if delta.is_empty() {
                    continue;
                }
                let next_value = latest_agent_message
                    .take()
                    .unwrap_or_default()
                    .chars()
                    .chain(delta.chars())
                    .collect::<String>();
                latest_agent_message = Some(next_value);
            }
            "item/completed" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let Some(item) = params.get("item") else {
                    continue;
                };
                if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                    continue;
                }
                latest_agent_message = item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(ToString::to_string);
            }
            "turn/completed" => {
                if params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != thread_id
                {
                    continue;
                }
                if params
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != turn_id
                {
                    continue;
                }
                let status = params
                    .get("turn")
                    .and_then(|turn| turn.get("status"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if status != "completed" {
                    return Ok(None);
                }
                return Ok(latest_agent_message);
            }
            _ => {}
        }
    }

    Ok(latest_agent_message)
}
