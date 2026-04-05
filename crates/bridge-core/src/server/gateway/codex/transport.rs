use super::super::*;

pub(super) fn connect_transport(config: &BridgeCodexConfig) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Attach => {
            CodexJsonTransport::start(&config.command, &config.args, config.endpoint.as_deref())
        }
        CodexRuntimeMode::Spawn => CodexJsonTransport::start(&config.command, &config.args, None),
        CodexRuntimeMode::Auto => {
            if let Some(endpoint) = config.endpoint.as_deref()
                && let Ok(transport) =
                    CodexJsonTransport::start(&config.command, &config.args, Some(endpoint))
            {
                return Ok(transport);
            }
            CodexJsonTransport::start(&config.command, &config.args, None)
        }
    }
}

pub(super) fn connect_read_transport(
    config: &BridgeCodexConfig,
) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Spawn => connect_transport(config),
        CodexRuntimeMode::Attach | CodexRuntimeMode::Auto => {
            CodexJsonTransport::start(&config.command, &config.args, None)
                .or_else(|_| connect_transport(config))
        }
    }
}
