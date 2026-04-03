use super::super::super::*;

pub(crate) fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_archive_message)
        .unwrap_or(false)
}

pub(crate) fn payload_primary_text(payload: &Value) -> Option<&str> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed);
            }
        }
    }

    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|item| item.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn is_hidden_archive_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("You are running in mobile plan intake mode.")
        || trimmed.starts_with("You are continuing a mobile planning workflow.")
        || trimmed.contains("<codex-plan-questions>")
}

pub(super) fn summarize_web_search_action(item: &Value) -> String {
    let Some(action) = item.get("action").and_then(Value::as_object) else {
        return item
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
    };

    match action
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "search" => action
            .get("query")
            .and_then(Value::as_str)
            .map(|query| format!("search: {query}"))
            .unwrap_or_else(|| "search".to_string()),
        "open_page" => action
            .get("url")
            .and_then(Value::as_str)
            .map(|url| format!("open_page: {url}"))
            .unwrap_or_else(|| "open_page".to_string()),
        "find_in_page" => {
            let query = action
                .get("query")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let url = action
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match (query.is_empty(), url.is_empty()) {
                (false, false) => format!("find_in_page: {query} @ {url}"),
                (false, true) => format!("find_in_page: {query}"),
                (true, false) => format!("find_in_page: {url}"),
                (true, true) => "find_in_page".to_string(),
            }
        }
        _ => item
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}
