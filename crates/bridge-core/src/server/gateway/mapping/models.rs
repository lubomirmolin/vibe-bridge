use super::super::*;

pub(crate) fn parse_model_options(result: Value) -> Vec<ModelOptionDto> {
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
