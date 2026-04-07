use super::super::super::*;
use super::annotations::value_to_text;
use super::hidden::summarize_web_search_action;

const PROPOSED_PLAN_OPEN_TAG: &str = "<proposed_plan>";
const PROPOSED_PLAN_CLOSE_TAG: &str = "</proposed_plan>";

pub(crate) fn normalize_codex_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    normalize_codex_item_payloads(item).into_iter().next()
}

pub(crate) fn normalize_codex_item_payloads(item: &Value) -> Vec<(BridgeEventKind, Value)> {
    let Some(item_type) = item.get("type").and_then(Value::as_str) else {
        return Vec::new();
    };
    let item_type = canonicalize_codex_item_type(item_type);
    match item_type {
        "userMessage" => vec![(
            BridgeEventKind::MessageDelta,
            normalize_message_item(item, "user"),
        )],
        "agentMessage" => normalize_agent_message_item_payloads(item),
        "plan" => vec![(BridgeEventKind::PlanDelta, normalize_plan_item(item))],
        "commandExecution" => {
            vec![(BridgeEventKind::CommandDelta, normalize_command_item(item))]
        }
        "fileChange" => vec![(
            BridgeEventKind::FileChange,
            normalize_file_change_item(item),
        )],
        "webSearch" => vec![(
            BridgeEventKind::CommandDelta,
            normalize_web_search_item(item),
        )],
        "functionCall" | "customToolCall" => normalize_codex_tool_invocation_item(item),
        "functionCallOutput" | "customToolCallOutput" => normalize_codex_tool_output_item(item),
        _ => Vec::new(),
    }
}

fn canonicalize_codex_item_type(item_type: &str) -> &str {
    match item_type {
        "function_call" => "functionCall",
        "function_call_output" => "functionCallOutput",
        "custom_tool_call" => "customToolCall",
        "custom_tool_call_output" => "customToolCallOutput",
        "web_search_call" => "webSearch",
        other => other,
    }
}

fn normalize_agent_message_item_payloads(item: &Value) -> Vec<(BridgeEventKind, Value)> {
    let payload = normalize_message_item(item, "assistant");
    let Some(text) = payload.get("text").and_then(Value::as_str) else {
        return vec![(BridgeEventKind::MessageDelta, payload)];
    };
    let Some(parsed) = extract_proposed_plan_block(text) else {
        return vec![(BridgeEventKind::MessageDelta, payload)];
    };

    let mut events = Vec::new();
    if !parsed.visible_text.is_empty() {
        let mut visible_payload = payload.clone();
        if let Some(object) = visible_payload.as_object_mut() {
            object.insert(
                "text".to_string(),
                Value::String(parsed.visible_text.clone()),
            );
        }
        events.push((BridgeEventKind::MessageDelta, visible_payload));
    }
    if !parsed.plan_text.is_empty() {
        events.push((
            BridgeEventKind::PlanDelta,
            json!({
                "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
                "type": "plan",
                "text": parsed.plan_text,
            }),
        ));
    }

    if events.is_empty() {
        vec![(BridgeEventKind::MessageDelta, payload)]
    } else {
        events
    }
}

fn normalize_codex_tool_invocation_item(item: &Value) -> Vec<(BridgeEventKind, Value)> {
    let tool_name = item
        .get("name")
        .and_then(Value::as_str)
        .or_else(|| item.get("command").and_then(Value::as_str))
        .unwrap_or("command");
    if tool_name == "update_plan"
        && let Some(payload) = normalize_update_plan_tool_item(item)
    {
        return vec![(BridgeEventKind::PlanDelta, payload)];
    }
    let input = item
        .get("input")
        .cloned()
        .or_else(|| item.get("arguments").cloned())
        .unwrap_or(Value::Null);
    let input_text = value_to_text(&input).unwrap_or_default();
    let is_file_change = is_file_change_custom_tool(tool_name) || is_file_change_text(&input_text);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("command".to_string(), Value::String(tool_name.to_string()));
        if is_file_change {
            if !input_text.trim().is_empty() {
                object.insert("change".to_string(), Value::String(input_text));
            }
        } else if !object.contains_key("arguments") {
            object.insert("arguments".to_string(), input);
        }
    }

    vec![(
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    )]
}

fn normalize_update_plan_tool_item(item: &Value) -> Option<Value> {
    let plan_input = parse_update_plan_input(
        item.get("input")
            .or_else(|| item.get("arguments"))
            .unwrap_or(&Value::Null),
    )?;
    let steps = normalize_update_plan_steps(&plan_input);
    let explanation = plan_input
        .get("explanation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if steps.is_empty() && explanation.is_none() {
        return None;
    }

    let total_count = steps.len();
    let completed_count = steps
        .iter()
        .filter(|step| step.get("status").and_then(Value::as_str) == Some("completed"))
        .count();
    let text =
        render_update_plan_text(explanation.as_deref(), &steps, completed_count, total_count);

    let mut payload = json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "plan",
        "text": text,
    });
    if let Some(object) = payload.as_object_mut() {
        if let Some(explanation) = explanation {
            object.insert("explanation".to_string(), Value::String(explanation));
        }
        if !steps.is_empty() {
            object.insert("steps".to_string(), Value::Array(steps));
            object.insert("completed_count".to_string(), json!(completed_count));
            object.insert("total_count".to_string(), json!(total_count));
        }
    }

    Some(payload)
}

fn parse_update_plan_input(input: &Value) -> Option<Value> {
    match input {
        Value::String(text) => serde_json::from_str::<Value>(text).ok(),
        Value::Object(_) => Some(input.clone()),
        _ => None,
    }
}

fn normalize_update_plan_steps(plan_input: &Value) -> Vec<Value> {
    plan_input
        .get("plan")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let step = entry
                .get("step")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?;
            let status = entry
                .get("status")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("pending");
            Some(json!({
                "step": step,
                "status": status,
            }))
        })
        .collect()
}

fn render_update_plan_text(
    explanation: Option<&str>,
    steps: &[Value],
    completed_count: usize,
    total_count: usize,
) -> String {
    if total_count == 0 {
        return explanation.unwrap_or_default().to_string();
    }

    let task_label = if total_count == 1 { "task" } else { "tasks" };
    let mut lines = vec![format!(
        "{completed_count} out of {total_count} {task_label} completed"
    )];
    lines.extend(steps.iter().enumerate().filter_map(|(index, step)| {
        step.get("step")
            .and_then(Value::as_str)
            .map(|value| format!("{}. {value}", index + 1))
    }));
    lines.join("\n")
}

fn normalize_codex_tool_output_item(item: &Value) -> Vec<(BridgeEventKind, Value)> {
    let output = item
        .get("output")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized_output = normalize_custom_tool_output(output);
    let is_file_change = is_file_change_text(&normalized_output);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("output".to_string(), Value::String(normalized_output));
    }

    vec![(
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    )]
}

fn normalize_message_item(item: &Value, role: &str) -> Value {
    let mut payload = serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "message",
        "role": role,
        "text": extract_message_text(item),
    });

    let images = extract_message_images(item);
    if !images.is_empty()
        && let Some(object) = payload.as_object_mut()
    {
        object.insert(
            "images".to_string(),
            Value::Array(images.into_iter().map(Value::String).collect()),
        );
    }

    payload
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProposedPlanBlock {
    visible_text: String,
    plan_text: String,
}

fn extract_proposed_plan_block(text: &str) -> Option<ProposedPlanBlock> {
    let open_index = text.find(PROPOSED_PLAN_OPEN_TAG)?;
    let plan_start = open_index + PROPOSED_PLAN_OPEN_TAG.len();
    let close_relative = text[plan_start..].find(PROPOSED_PLAN_CLOSE_TAG)?;
    let close_index = plan_start + close_relative;

    let mut visible_text = String::new();
    visible_text.push_str(&text[..open_index]);
    visible_text.push_str(&text[close_index + PROPOSED_PLAN_CLOSE_TAG.len()..]);

    let visible_text = visible_text.trim().to_string();
    let plan_text = text[plan_start..close_index].trim().to_string();
    if visible_text.is_empty() && plan_text.is_empty() {
        return None;
    }

    Some(ProposedPlanBlock {
        visible_text,
        plan_text,
    })
}

fn normalize_plan_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "plan",
        "text": item.get("text").and_then(Value::as_str).unwrap_or_default(),
    })
}

fn normalize_command_item(item: &Value) -> Value {
    let arguments = item
        .get("arguments")
        .cloned()
        .or_else(|| item.get("input").cloned())
        .unwrap_or(Value::Null);

    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "command",
        "command": item
            .get("command")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "arguments": arguments,
        "output": item
            .get("output")
            .or_else(|| item.get("aggregatedOutput"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "cmd": item.get("cmd").and_then(Value::as_str),
        "workdir": item.get("cwd").and_then(Value::as_str),
    })
}

fn normalize_web_search_item(item: &Value) -> Value {
    let action = item.get("action").cloned().unwrap_or(Value::Null);

    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "command",
        "command": "web_search",
        "action": item
            .get("action")
            .and_then(Value::as_object)
            .and_then(|value| value.get("type"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "arguments": if action.is_null() {
            item.get("query").cloned().unwrap_or(Value::Null)
        } else {
            action
        },
        "output": summarize_web_search_action(item),
        "cmd": Value::Null,
        "workdir": Value::Null,
    })
}

fn normalize_file_change_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "file_change",
        "resolved_unified_diff": item
            .get("resolved_unified_diff")
            .or_else(|| item.get("output"))
            .or_else(|| item.get("change"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "path": extract_file_change_path(item),
    })
}

fn extract_message_text(item: &Value) -> String {
    if let Some(text) = item.get("text").and_then(Value::as_str) {
        return text.to_string();
    }

    item.get("content")
        .and_then(Value::as_array)
        .map(|content| {
            content
                .iter()
                .filter_map(|entry| entry.get("text").and_then(Value::as_str))
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn extract_message_images(item: &Value) -> Vec<String> {
    item.get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            entry
                .get("image_url")
                .or_else(|| entry.get("url"))
                .or_else(|| entry.get("path"))
                .and_then(Value::as_str)
        })
        .filter(|image| !image.trim().is_empty())
        .map(ToString::to_string)
        .collect()
}

fn extract_file_change_path(item: &Value) -> String {
    item.get("path")
        .or_else(|| item.get("file"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .or_else(|| {
            item.get("changes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find_map(|change| change.get("path").and_then(Value::as_str))
                .map(ToString::to_string)
        })
        .or_else(|| {
            ["resolved_unified_diff", "output", "change"]
                .into_iter()
                .filter_map(|key| item.get(key).and_then(Value::as_str))
                .find_map(extract_file_change_path_from_text)
        })
        .unwrap_or_default()
}

fn extract_file_change_path_from_text(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(path) = trimmed
            .strip_prefix("*** Update File: ")
            .or_else(|| trimmed.strip_prefix("*** Add File: "))
            .or_else(|| trimmed.strip_prefix("*** Delete File: "))
        {
            let path = path.trim();
            if !path.is_empty() {
                return Some(path.to_string());
            }
        }

        if let Some(path) = trimmed
            .strip_prefix("M ")
            .or_else(|| trimmed.strip_prefix("A "))
            .or_else(|| trimmed.strip_prefix("D "))
            .or_else(|| trimmed.strip_prefix("R "))
            .or_else(|| trimmed.strip_prefix("C "))
            .or_else(|| trimmed.strip_prefix("? "))
        {
            let path = path.trim();
            if !path.is_empty() {
                return Some(path.to_string());
            }
        }

        if let Some(path) = trimmed.strip_prefix("diff --git a/") {
            let path = path.split_whitespace().next().unwrap_or_default().trim();
            if !path.is_empty() {
                return Some(path.to_string());
            }
        }
    }

    None
}

fn is_file_change_custom_tool(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "apply_patch" | "replace_file_content" | "multi_replace_file_content"
    ) || tool_name.contains("edit_file")
}

fn is_file_change_text(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }

    text.contains("Updated the following files:")
        || text.contains("*** Begin Patch")
        || text.contains("*** Update File:")
        || text.contains("*** Add File:")
        || text.contains("[diff_block_start]")
        || text.contains("diff --git ")
}

fn normalize_custom_tool_output(raw_output: &str) -> String {
    if raw_output.trim().is_empty() {
        return String::new();
    }

    if let Ok(decoded) = serde_json::from_str::<Value>(raw_output)
        && let Some(text) = decoded.get("output").and_then(Value::as_str)
    {
        return text.to_string();
    }

    raw_output.to_string()
}
