use super::super::*;

pub(crate) fn fallback_claude_model_options() -> Vec<ModelOptionDto> {
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
