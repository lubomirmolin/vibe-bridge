use crate::codex_runtime::CodexRuntimeMode;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewriteCodexConfig {
    pub mode: CodexRuntimeMode,
    pub endpoint: Option<String>,
    pub command: String,
    pub args: Vec<String>,
}

impl Default for RewriteCodexConfig {
    fn default() -> Self {
        Self {
            mode: CodexRuntimeMode::Auto,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewriteConfig {
    pub host: String,
    pub port: u16,
    pub codex: RewriteCodexConfig,
}

impl RewriteConfig {
    pub fn from_env_and_args<I>(args: I) -> Result<Self, String>
    where
        I: IntoIterator<Item = String>,
    {
        let mut host = std::env::var("BRIDGE_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
        let mut port = std::env::var("BRIDGE_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(3210);
        let mut codex_mode = CodexRuntimeMode::Auto;
        let mut codex_endpoint = Some("ws://127.0.0.1:4222".to_string());
        let mut codex_command = "codex".to_string();
        let mut codex_args = vec!["app-server".to_string()];
        let mut codex_args_overridden = false;

        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--host" => {
                    host = iter
                        .next()
                        .ok_or_else(|| "--host requires a value".to_string())?;
                }
                "--port" => {
                    let value = iter
                        .next()
                        .ok_or_else(|| "--port requires a value".to_string())?;
                    port = value
                        .parse::<u16>()
                        .map_err(|_| format!("invalid --port value: {value}"))?;
                }
                "--codex-mode" => {
                    let value = iter
                        .next()
                        .ok_or_else(|| "--codex-mode requires a value".to_string())?;
                    codex_mode = CodexRuntimeMode::from_flag(&value)?;
                }
                "--codex-endpoint" => {
                    codex_endpoint = Some(
                        iter.next()
                            .ok_or_else(|| "--codex-endpoint requires a value".to_string())?,
                    );
                }
                "--codex-command" => {
                    codex_command = iter
                        .next()
                        .ok_or_else(|| "--codex-command requires a value".to_string())?;
                }
                "--codex-arg" => {
                    let value = iter
                        .next()
                        .ok_or_else(|| "--codex-arg requires a value".to_string())?;
                    if !codex_args_overridden {
                        codex_args.clear();
                        codex_args_overridden = true;
                    }
                    codex_args.push(value);
                }
                _ => {}
            }
        }

        if codex_mode == CodexRuntimeMode::Attach && codex_endpoint.is_none() {
            return Err("--codex-endpoint is required when --codex-mode attach".to_string());
        }

        Ok(Self {
            host,
            port,
            codex: RewriteCodexConfig {
                mode: codex_mode,
                endpoint: codex_endpoint,
                command: codex_command,
                args: codex_args,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::RewriteConfig;

    #[test]
    fn parses_args_overriding_defaults() {
        let config = RewriteConfig::from_env_and_args([
            "--host".to_string(),
            "0.0.0.0".to_string(),
            "--port".to_string(),
            "3115".to_string(),
            "--codex-mode".to_string(),
            "spawn".to_string(),
            "--codex-command".to_string(),
            "codex-dev".to_string(),
            "--codex-arg".to_string(),
            "app-server".to_string(),
        ])
        .expect("config should parse");

        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.port, 3115);
        assert_eq!(
            config.codex.mode,
            crate::codex_runtime::CodexRuntimeMode::Spawn
        );
        assert_eq!(config.codex.command, "codex-dev");
        assert_eq!(config.codex.args, vec!["app-server".to_string()]);
    }
}
