use super::*;

pub(super) fn fetch_model_catalog(transport: &mut CodexJsonTransport) -> Vec<ModelOptionDto> {
    match transport.request(
        "model/list",
        serde_json::json!({
            "cursor": Value::Null,
            "limit": 50,
            "includeHidden": false,
        }),
    ) {
        Ok(response) => {
            let models = parse_model_options(response);
            if models.is_empty() {
                fallback_model_options()
            } else {
                models
            }
        }
        Err(_) => fallback_model_options(),
    }
}

pub(super) fn fallback_claude_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "claude-sonnet-4-6".to_string(),
            model: "claude-sonnet-4-6".to_string(),
            display_name: "Claude Sonnet 4.6".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-6".to_string(),
            model: "claude-opus-4-6".to_string(),
            display_name: "Claude Opus 4.6".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-sonnet-4-5".to_string(),
            model: "claude-sonnet-4-5".to_string(),
            display_name: "Claude Sonnet 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-5".to_string(),
            model: "claude-opus-4-5".to_string(),
            display_name: "Claude Opus 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
    ]
}

pub(super) fn fallback_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "gpt-5".to_string(),
            model: "gpt-5".to_string(),
            display_name: "GPT-5".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "gpt-5-mini".to_string(),
            model: "gpt-5-mini".to_string(),
            display_name: "GPT-5 Mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "o4-mini".to_string(),
            model: "o4-mini".to_string(),
            display_name: "o4-mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
    ]
}

fn claude_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
    vec![
        ReasoningEffortOptionDto {
            reasoning_effort: "low".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "medium".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "high".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "max".to_string(),
            description: None,
        },
    ]
}

fn fallback_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
    vec![
        ReasoningEffortOptionDto {
            reasoning_effort: "low".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "medium".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "high".to_string(),
            description: None,
        },
    ]
}

pub(super) fn parse_model_options(result: Value) -> Vec<ModelOptionDto> {
    let Some(items) = result.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };

    items.iter().filter_map(parse_model_option).collect()
}

fn parse_model_option(item: &Value) -> Option<ModelOptionDto> {
    let model = value_text(item.get("model")).or_else(|| value_text(item.get("id")))?;
    let id = value_text(item.get("id")).unwrap_or_else(|| model.clone());
    let display_name = value_text(item.get("displayName"))
        .or_else(|| value_text(item.get("display_name")))
        .unwrap_or_else(|| model.clone());
    let description = value_text(item.get("description")).unwrap_or_default();
    let default_reasoning_effort = value_text(item.get("defaultReasoningEffort"))
        .or_else(|| value_text(item.get("default_reasoning_effort")));
    let supported_reasoning_efforts = parse_reasoning_efforts(
        item.get("supportedReasoningEfforts")
            .or_else(|| item.get("supported_reasoning_efforts")),
    );
    let is_default = item
        .get("isDefault")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            item.get("is_default")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });

    Some(ModelOptionDto {
        id,
        model,
        display_name,
        description,
        is_default,
        default_reasoning_effort,
        supported_reasoning_efforts,
    })
}

fn parse_reasoning_efforts(value: Option<&Value>) -> Vec<ReasoningEffortOptionDto> {
    let Some(items) = value.and_then(Value::as_array) else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(|item| {
            let effort = value_text(item.get("reasoningEffort"))
                .or_else(|| value_text(item.get("reasoning_effort")))?;
            let description = value_text(item.get("description"));
            Some(ReasoningEffortOptionDto {
                reasoning_effort: effort,
                description,
            })
        })
        .collect()
}

fn value_text(value: Option<&Value>) -> Option<String> {
    let value = value?;
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}
