use super::super::*;

pub(crate) fn fallback_model_options() -> Vec<ModelOptionDto> {
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
