use super::super::*;

pub(crate) fn build_claude_input_message(
    prompt: &str,
    images: &[String],
) -> Result<String, String> {
    let content = build_claude_message_content(prompt, images)?;
    serde_json::to_string(&json!({
        "type": "user",
        "message": {
            "role": "user",
            "content": content,
        },
        "parent_tool_use_id": Value::Null,
    }))
    .map(|line| format!("{line}\n"))
    .map_err(|error| format!("failed to encode Claude turn input: {error}"))
}

pub(crate) fn build_claude_message_content(
    prompt: &str,
    images: &[String],
) -> Result<Value, String> {
    let trimmed_prompt = prompt.trim();
    if images.is_empty() {
        return Ok(Value::String(trimmed_prompt.to_string()));
    }

    let mut blocks = Vec::new();
    if !trimmed_prompt.is_empty() {
        blocks.push(json!({
            "type": "text",
            "text": trimmed_prompt,
        }));
    }
    for (index, image) in images.iter().enumerate() {
        let parsed = parse_data_url_image(image)
            .map_err(|error| format!("image attachment {} is invalid: {error}", index + 1))?;
        blocks.push(json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": parsed.mime_type,
                "data": parsed.base64_data,
            },
        }));
    }

    Ok(Value::Array(blocks))
}

pub(crate) struct ParsedDataUrlImage {
    pub(crate) mime_type: String,
    pub(crate) base64_data: String,
}

pub(crate) fn parse_data_url_image(data_url: &str) -> Result<ParsedDataUrlImage, String> {
    let trimmed = data_url.trim();
    let Some((metadata, payload)) = trimmed.split_once(',') else {
        return Err("data URL is missing a payload".to_string());
    };
    if !metadata.starts_with("data:") {
        return Err("image must be a data URL".to_string());
    }
    if !metadata.contains(";base64") {
        return Err("image data URL must be base64-encoded".to_string());
    }

    let mime_type = metadata
        .trim_start_matches("data:")
        .split(';')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "image data URL is missing a MIME type".to_string())?;
    if !matches!(
        mime_type,
        "image/jpeg" | "image/png" | "image/gif" | "image/webp"
    ) {
        return Err(format!(
            "unsupported MIME type {mime_type}; Claude Code currently supports image/jpeg, image/png, image/gif, and image/webp"
        ));
    }

    let base64_data = payload.trim();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .map_err(|error| format!("invalid base64 payload: {error}"))?;
    if decoded.is_empty() {
        return Err("image payload is empty".to_string());
    }

    Ok(ParsedDataUrlImage {
        mime_type: mime_type.to_string(),
        base64_data: base64_data.to_string(),
    })
}
