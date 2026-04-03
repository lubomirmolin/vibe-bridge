use super::super::*;

pub(super) fn build_thread_title_prompt(prompt: &str) -> String {
    [
        "Generate a concise thread title for the user's request.",
        "Write the result into the structured response field title.",
        "Rules:",
        "- Keep the title under 80 characters.",
        "- Use plain text only in the title field.",
        "- Prefer an imperative title when the request is actionable.",
        "- Preserve important product or framework names like Flutter, Rust, macOS, Android, iOS, Codex, and Tailscale.",
        "- Do not include quotes, markdown, trailing punctuation, or filler words like 'Please' or 'Help me'.",
        "",
        "User request:",
        prompt,
    ]
    .join("\n")
}

pub(super) fn build_thread_title_output_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "title": {
                "type": "string",
                "minLength": 4,
                "maxLength": CodexGateway::THREAD_TITLE_MAX_CHARS,
            }
        },
        "required": ["title"],
    })
}

pub(crate) fn normalize_generated_thread_title(raw_title: &str) -> Option<String> {
    let normalized_whitespace = raw_title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim_matches(|ch: char| ch == '"' || ch == '\'' || ch == '`')
        .trim();
    if trimmed.is_empty() || super::super::mapping::is_placeholder_thread_title(trimmed) {
        return None;
    }

    let mut title = trimmed.to_string();
    if title.chars().count() > CodexGateway::THREAD_TITLE_MAX_CHARS {
        title = title
            .chars()
            .take(CodexGateway::THREAD_TITLE_MAX_CHARS)
            .collect::<String>()
            .trim()
            .to_string();
    }

    while title.ends_with('.') || title.ends_with(':') || title.ends_with(';') {
        title.pop();
    }

    let normalized = title.trim();
    if normalized.is_empty() || super::super::mapping::is_placeholder_thread_title(normalized) {
        return None;
    }
    Some(normalized.to_string())
}
