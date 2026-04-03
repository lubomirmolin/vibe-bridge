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

pub(super) fn take_reserved_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: &str,
) -> Option<CodexJsonTransport> {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.remove(thread_id).map(|entry| entry.transport)
}

pub(super) fn reserve_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: String,
    transport: CodexJsonTransport,
) {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.insert(
        thread_id,
        ReservedTransport {
            reserved_at: Instant::now(),
            transport,
        },
    );
}

fn prune_reserved_transports(reserved: &mut HashMap<String, ReservedTransport>) {
    reserved.retain(|_, entry| entry.reserved_at.elapsed() <= CodexGateway::RESERVED_TRANSPORT_TTL);
}
