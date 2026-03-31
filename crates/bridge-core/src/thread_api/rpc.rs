use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{ModelOptionDto, ProviderKind, ReasoningEffortOptionDto};

use crate::codex_transport::CodexJsonTransport;

use super::native_thread_id_for_provider;

pub(super) fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

pub(super) fn read_thread_with_resume(
    client: &mut CodexRpcClient,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThread, String> {
    match client.read_thread(thread_id, include_turns) {
        Ok(thread) => Ok(thread),
        Err(error) if should_resume_thread(&error) => {
            client.resume_thread(thread_id)?;
            client.read_thread(thread_id, include_turns)
        }
        Err(error) => Err(error),
    }
}

pub(super) fn start_turn_with_resume(
    client: &mut CodexRpcClient,
    thread_id: &str,
    prompt: &str,
) -> Result<CodexTurn, String> {
    match client.start_turn(thread_id, prompt) {
        Ok(turn) => Ok(turn),
        Err(error) if should_resume_thread(&error) => {
            client.resume_thread(thread_id)?;
            client.start_turn(thread_id, prompt)
        }
        Err(error) => Err(error),
    }
}

pub(super) fn normalize_turn_text(raw: Option<&str>, fallback: &str) -> String {
    let normalized = raw.unwrap_or(fallback).trim();
    if normalized.is_empty() {
        fallback.to_string()
    } else {
        normalized.to_string()
    }
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

fn parse_model_options(result: Value) -> Vec<ModelOptionDto> {
    let Some(items) = result.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(parse_model_option)
        .collect::<Vec<_>>()
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
        .collect::<Vec<_>>()
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

fn text_user_input(text: &str) -> Value {
    json!({
        "type": "text",
        "text": text,
        "text_elements": [],
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadListResult {
    data: Vec<CodexThread>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadReadResult {
    thread: CodexThread,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnStartResult {
    turn: CodexTurn,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadResumeResult {
    thread: CodexThread,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnSteerResult {
    #[serde(rename = "turnId")]
    turn_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(super) struct CodexThread {
    pub(super) id: String,
    #[serde(default)]
    pub(super) name: Option<String>,
    #[serde(default)]
    pub(super) preview: Option<String>,
    pub(super) status: CodexThreadStatus,
    pub(super) cwd: String,
    #[serde(rename = "gitInfo")]
    pub(super) git_info: Option<CodexGitInfo>,
    #[serde(rename = "createdAt")]
    pub(super) created_at: i64,
    #[serde(rename = "updatedAt")]
    pub(super) updated_at: i64,
    #[serde(default)]
    pub(super) source: Value,
    #[serde(default)]
    pub(super) turns: Vec<CodexTurn>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(super) struct CodexThreadStatus {
    #[serde(rename = "type")]
    pub(super) kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(super) struct CodexGitInfo {
    pub(super) branch: Option<String>,
    #[serde(rename = "originUrl")]
    pub(super) origin_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(super) struct CodexTurn {
    pub(super) id: String,
    #[serde(default)]
    pub(super) items: Vec<Value>,
}

#[derive(Debug)]
pub(super) struct CodexRpcClient {
    transport: CodexJsonTransport,
}

impl CodexRpcClient {
    pub(super) const MAX_THREADS_TO_FETCH: usize = 50;

    pub(super) fn start(
        command: &str,
        args: &[String],
        endpoint: Option<&str>,
    ) -> Result<Self, String> {
        Ok(Self {
            transport: CodexJsonTransport::start(command, args, endpoint)?,
        })
    }

    pub(super) fn fetch_all_threads(&mut self) -> Result<Vec<CodexThread>, String> {
        let mut threads = Vec::new();
        let mut cursor: Option<String> = None;

        loop {
            if threads.len() >= Self::MAX_THREADS_TO_FETCH {
                break;
            }

            let mut params = serde_json::Map::new();
            if let Some(cursor) = &cursor {
                params.insert("cursor".to_string(), Value::String(cursor.clone()));
            }

            let result = self.request("thread/list", Value::Object(params))?;
            let response: CodexThreadListResult =
                serde_json::from_value(result).map_err(|error| {
                    format!("invalid thread/list response from codex app-server: {error}")
                })?;

            let remaining = Self::MAX_THREADS_TO_FETCH.saturating_sub(threads.len());
            for thread in response.data.into_iter().take(remaining) {
                let thread_id = thread.id.clone();
                match self.request(
                    "thread/read",
                    json!({
                        "threadId": thread_id,
                        "includeTurns": true,
                    }),
                ) {
                    Ok(read_result) => {
                        let read_response: CodexThreadReadResult =
                            serde_json::from_value(read_result).map_err(|error| {
                                format!(
                                    "invalid thread/read response from codex app-server: {error}"
                                )
                            })?;
                        threads.push(read_response.thread);
                    }
                    Err(_) => {
                        threads.push(thread);
                    }
                }
            }

            if let Some(next_cursor) = response.next_cursor {
                cursor = Some(next_cursor);
            } else {
                break;
            }
        }

        Ok(threads)
    }

    pub(super) fn read_thread(
        &mut self,
        thread_id: &str,
        include_turns: bool,
    ) -> Result<CodexThread, String> {
        let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
            .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
        let result = self.request(
            "thread/read",
            json!({
                "threadId": native_thread_id,
                "includeTurns": include_turns,
            }),
        )?;
        let response: CodexThreadReadResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid thread/read response from codex app-server: {error}")
        })?;
        Ok(response.thread)
    }

    pub(super) fn resume_thread(&mut self, thread_id: &str) -> Result<CodexThread, String> {
        let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
            .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
        let result = self.request(
            "thread/resume",
            json!({
                "threadId": native_thread_id,
            }),
        )?;
        let response: CodexThreadResumeResult =
            serde_json::from_value(result).map_err(|error| {
                format!("invalid thread/resume response from codex app-server: {error}")
            })?;
        Ok(response.thread)
    }

    pub(super) fn list_models(&mut self) -> Result<Vec<ModelOptionDto>, String> {
        let result = self.request(
            "model/list",
            json!({
                "cursor": Value::Null,
                "limit": 50,
                "includeHidden": false,
            }),
        )?;
        Ok(parse_model_options(result))
    }

    pub(super) fn start_turn(
        &mut self,
        thread_id: &str,
        prompt: &str,
    ) -> Result<CodexTurn, String> {
        let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
            .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
        let result = self.request(
            "turn/start",
            json!({
                "threadId": native_thread_id,
                "input": [text_user_input(prompt)],
            }),
        )?;
        let response: CodexTurnStartResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid turn/start response from codex app-server: {error}")
        })?;
        Ok(response.turn)
    }

    pub(super) fn steer_turn(
        &mut self,
        thread_id: &str,
        expected_turn_id: &str,
        instruction: &str,
    ) -> Result<String, String> {
        let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
            .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
        let result = self.request(
            "turn/steer",
            json!({
                "threadId": native_thread_id,
                "expectedTurnId": expected_turn_id,
                "input": [text_user_input(instruction)],
            }),
        )?;
        let response: CodexTurnSteerResult = serde_json::from_value(result).map_err(|error| {
            format!("invalid turn/steer response from codex app-server: {error}")
        })?;
        Ok(response.turn_id)
    }

    pub(super) fn interrupt_turn(&mut self, thread_id: &str, turn_id: &str) -> Result<(), String> {
        let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
            .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
        self.request(
            "turn/interrupt",
            json!({
                "threadId": native_thread_id,
                "turnId": turn_id,
            }),
        )?;
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.transport.request(method, params)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        fallback_model_options, normalize_turn_text, parse_model_options, should_resume_thread,
    };

    #[test]
    fn parse_model_options_accepts_snake_and_camel_case_fields() {
        let models = parse_model_options(json!({
            "data": [
                {
                    "id": "gpt-5.4",
                    "model": "gpt-5.4",
                    "displayName": "GPT-5.4",
                    "defaultReasoningEffort": "medium",
                    "supportedReasoningEfforts": [
                        {"reasoningEffort": "low"},
                        {"reasoning_effort": "high", "description": "deep"}
                    ],
                    "isDefault": true
                }
            ]
        }));

        assert_eq!(models.len(), 1);
        assert_eq!(models[0].display_name, "GPT-5.4");
        assert_eq!(
            models[0].default_reasoning_effort.as_deref(),
            Some("medium")
        );
        assert_eq!(models[0].supported_reasoning_efforts.len(), 2);
        assert!(models[0].is_default);
    }

    #[test]
    fn fallback_models_remain_non_empty_and_turn_text_stays_safe() {
        assert!(!fallback_model_options().is_empty());
        assert_eq!(normalize_turn_text(Some("   "), "Continue"), "Continue");
        assert!(should_resume_thread("thread not found upstream"));
    }
}
