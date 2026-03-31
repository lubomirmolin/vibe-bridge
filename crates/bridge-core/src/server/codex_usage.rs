use std::env;
use std::path::PathBuf;

use serde::Deserialize;
use shared_contracts::ThreadUsageWindowDto;

const DEFAULT_USAGE_ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";

#[derive(Debug, Clone)]
pub struct CodexUsageClient {
    auth_path: PathBuf,
    endpoint: String,
    http_client: reqwest::Client,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexUsageSnapshot {
    pub plan_type: Option<String>,
    pub primary_window: ThreadUsageWindowDto,
    pub secondary_window: Option<ThreadUsageWindowDto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexUsageError {
    AuthUnavailable(String),
    UpstreamUnavailable(String),
    InvalidResponse(String),
}

impl CodexUsageError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::AuthUnavailable(_) => "codex_usage_auth_unavailable",
            Self::UpstreamUnavailable(_) => "codex_usage_upstream_unavailable",
            Self::InvalidResponse(_) => "codex_usage_invalid_response",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::AuthUnavailable(message)
            | Self::UpstreamUnavailable(message)
            | Self::InvalidResponse(message) => message,
        }
    }
}

impl CodexUsageClient {
    pub fn new(auth_path: PathBuf, endpoint: impl Into<String>) -> Self {
        Self {
            auth_path,
            endpoint: endpoint.into(),
            http_client: reqwest::Client::builder()
                .build()
                .expect("reqwest client should build"),
        }
    }

    pub fn default_auth_path() -> Result<PathBuf, String> {
        let codex_home = resolve_codex_home_dir()?;
        Ok(codex_home.join("auth.json"))
    }

    pub fn default_endpoint() -> &'static str {
        DEFAULT_USAGE_ENDPOINT
    }

    pub async fn fetch_usage(&self) -> Result<CodexUsageSnapshot, CodexUsageError> {
        let auth_raw = tokio::fs::read_to_string(&self.auth_path)
            .await
            .map_err(|error| {
                CodexUsageError::AuthUnavailable(format!(
                    "Codex auth is unavailable at {}: {error}",
                    self.auth_path.display()
                ))
            })?;
        let auth: CodexAuthFile = serde_json::from_str(&auth_raw).map_err(|error| {
            CodexUsageError::InvalidResponse(format!("Codex auth file is invalid JSON: {error}"))
        })?;
        let token = auth
            .tokens
            .and_then(|tokens| tokens.access_token)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                CodexUsageError::AuthUnavailable(
                    "Codex auth does not contain a usable access token.".to_string(),
                )
            })?;

        let response = self
            .http_client
            .get(&self.endpoint)
            .bearer_auth(token)
            .header(reqwest::header::ACCEPT, "application/json")
            .header(reqwest::header::USER_AGENT, "codex-mobile-companion/bridge")
            .send()
            .await
            .map_err(|error| {
                CodexUsageError::UpstreamUnavailable(format!(
                    "Could not reach ChatGPT usage endpoint: {error}"
                ))
            })?;

        let status = response.status();
        let body = response.text().await.map_err(|error| {
            CodexUsageError::UpstreamUnavailable(format!(
                "Could not read ChatGPT usage response: {error}"
            ))
        })?;

        if !status.is_success() {
            return Err(CodexUsageError::UpstreamUnavailable(format!(
                "ChatGPT usage endpoint returned HTTP {}.",
                status.as_u16()
            )));
        }

        let decoded: WhamUsageResponse = serde_json::from_str(&body).map_err(|error| {
            CodexUsageError::InvalidResponse(format!(
                "ChatGPT usage response was invalid JSON: {error}"
            ))
        })?;

        Ok(CodexUsageSnapshot {
            plan_type: decoded
                .plan_type
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            primary_window: decoded.rate_limit.primary_window.into(),
            secondary_window: decoded.rate_limit.secondary_window.map(Into::into),
        })
    }
}

impl Default for CodexUsageClient {
    fn default() -> Self {
        let auth_path =
            Self::default_auth_path().unwrap_or_else(|_| PathBuf::from(".codex").join("auth.json"));
        Self::new(auth_path, Self::default_endpoint())
    }
}

fn resolve_codex_home_dir() -> Result<PathBuf, String> {
    if let Some(codex_home) = env::var_os("CODEX_HOME") {
        let path = PathBuf::from(codex_home);
        if !path.as_os_str().is_empty() {
            return Ok(path);
        }
    }

    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set; could not resolve Codex state directory".to_string())?;
    Ok(home.join(".codex"))
}

#[derive(Debug, Deserialize)]
struct CodexAuthFile {
    #[serde(default)]
    tokens: Option<CodexAuthTokens>,
}

#[derive(Debug, Deserialize)]
struct CodexAuthTokens {
    #[serde(default)]
    access_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WhamUsageResponse {
    #[serde(default)]
    plan_type: Option<String>,
    rate_limit: WhamRateLimit,
}

#[derive(Debug, Deserialize)]
struct WhamRateLimit {
    primary_window: WhamWindow,
    #[serde(default)]
    secondary_window: Option<WhamWindow>,
}

#[derive(Debug, Deserialize)]
struct WhamWindow {
    used_percent: u64,
    limit_window_seconds: u64,
    reset_after_seconds: u64,
    reset_at: i64,
}

impl From<WhamWindow> for ThreadUsageWindowDto {
    fn from(value: WhamWindow) -> Self {
        Self {
            used_percent: value.used_percent.min(100) as u8,
            limit_window_seconds: value.limit_window_seconds,
            reset_after_seconds: value.reset_after_seconds,
            reset_at: value.reset_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use axum::Json;
    use axum::Router;
    use axum::extract::State;
    use axum::routing::get;
    use serde_json::json;
    use tokio::net::TcpListener;
    use tokio::sync::Mutex;

    use super::{CodexUsageClient, CodexUsageError};

    #[tokio::test]
    async fn fetch_usage_reads_access_token_and_maps_primary_and_secondary_windows() {
        let auth_path = unique_temp_path("codex-usage-auth.json");
        let auth_body = json!({
            "tokens": {
                "access_token": "test-access-token"
            }
        });
        tokio::fs::write(
            &auth_path,
            serde_json::to_vec(&auth_body).expect("auth body should encode"),
        )
        .await
        .expect("auth file should write");

        let recorded_auth_header = Arc::new(Mutex::new(None::<String>));
        let app = Router::new()
            .route("/backend-api/wham/usage", get(test_usage_handler))
            .with_state(recorded_auth_header.clone());
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("listener should bind");
        let address = listener.local_addr().expect("local addr should resolve");
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("server should run");
        });

        let client = CodexUsageClient::new(
            auth_path.clone(),
            format!("http://{address}/backend-api/wham/usage"),
        );
        let usage = client.fetch_usage().await.expect("usage should load");

        assert_eq!(usage.plan_type.as_deref(), Some("pro"));
        assert_eq!(usage.primary_window.used_percent, 6);
        assert_eq!(usage.primary_window.reset_after_seconds, 12223);
        assert_eq!(
            usage
                .secondary_window
                .as_ref()
                .expect("secondary window should be present")
                .used_percent,
            42
        );
        assert_eq!(
            recorded_auth_header.lock().await.as_deref(),
            Some("Bearer test-access-token")
        );

        server.abort();
        let _ = tokio::fs::remove_file(auth_path).await;
    }

    #[tokio::test]
    async fn fetch_usage_reports_missing_access_token() {
        let auth_path = unique_temp_path("codex-usage-auth-missing.json");
        tokio::fs::write(&auth_path, "{\"tokens\":{}}")
            .await
            .expect("auth file should write");

        let client = CodexUsageClient::new(auth_path.clone(), "http://127.0.0.1:1/unused");
        let error = client.fetch_usage().await.expect_err("usage should fail");
        assert!(matches!(error, CodexUsageError::AuthUnavailable(_)));

        let _ = tokio::fs::remove_file(auth_path).await;
    }

    async fn test_usage_handler(
        State(recorded_auth_header): State<Arc<Mutex<Option<String>>>>,
        headers: axum::http::HeaderMap,
    ) -> Json<serde_json::Value> {
        let auth = headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .map(ToString::to_string);
        *recorded_auth_header.lock().await = auth;
        Json(json!({
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 6,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 12223,
                    "reset_at": 1774996694
                },
                "secondary_window": {
                    "used_percent": 42,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 213053,
                    "reset_at": 1775197525
                }
            }
        }))
    }

    fn unique_temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("{name}-{}", uuid::Uuid::new_v4()))
    }
}
