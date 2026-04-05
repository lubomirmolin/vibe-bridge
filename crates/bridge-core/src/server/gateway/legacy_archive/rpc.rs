use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::ProviderKind;

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
struct CodexThreadResumeResult {
    thread: CodexThread,
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

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.transport.request(method, params)
    }
}

#[cfg(test)]
mod tests {
    use super::should_resume_thread;

    #[test]
    fn should_resume_thread_matches_upstream_thread_not_found_errors() {
        assert!(should_resume_thread("thread not found upstream"));
    }
}
