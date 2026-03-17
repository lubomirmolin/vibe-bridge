use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use serde_json::json;
use tungstenite::{Message, accept};

use codex_runtime::{
    CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, RuntimeSnapshot,
};
use logging::{InMemoryLogSink, StructuredLogger};
use pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingRevokeRequest, PairingSessionService,
};
use persistence::PersistenceBoundary;
use secure_storage::InMemorySecureStore;
use stream_router::StreamRouter;
use thread_api::{MutationDispatch, ThreadApiService};

pub mod codex_runtime;
pub mod logging;
pub mod pairing;
pub mod persistence;
pub mod secure_storage;
pub mod stream_router;
pub mod thread_api;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Config {
    host: String,
    port: u16,
    admin_port: u16,
    pairing_base_url: String,
    codex_runtime: CodexRuntimeConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeFoundations {
    pub persistence: PersistenceBoundary,
    pub secure_store: InMemorySecureStore,
    pub logger: StructuredLogger<InMemoryLogSink>,
}

pub fn build_foundations(base_directory: impl Into<PathBuf>) -> BridgeFoundations {
    BridgeFoundations {
        persistence: PersistenceBoundary::new(base_directory),
        secure_store: InMemorySecureStore::new(),
        logger: StructuredLogger::new(InMemoryLogSink::default()),
    }
}

pub fn run_from_env() -> Result<(), String> {
    run(std::env::args().skip(1))
}

fn run<I>(args: I) -> Result<(), String>
where
    I: IntoIterator<Item = String>,
{
    let config = parse_args(args)?;
    let foundations = build_foundations(".");

    let mut runtime = CodexRuntimeSupervisor::new(config.codex_runtime.clone());
    runtime.initialize()?;

    let thread_api = ThreadApiService::from_codex_app_server(
        &config.codex_runtime.command,
        &config.codex_runtime.args,
    )
    .unwrap_or_else(|error| {
        eprintln!("failed to load codex-backed thread data: {error}");
        ThreadApiService::empty()
    });

    let app = Arc::new(BridgeApplication::new(
        thread_api,
        runtime,
        StreamRouter::new(),
        PairingSessionService::new(
            config.host.as_str(),
            config.port,
            config.pairing_base_url.clone(),
            foundations.persistence.state_directory(),
        ),
    ));

    let api_listener = TcpListener::bind((config.host.as_str(), config.port)).map_err(|error| {
        format!(
            "failed to bind API listener on {}:{}: {error}",
            config.host, config.port
        )
    })?;
    let admin_listener =
        TcpListener::bind((config.host.as_str(), config.admin_port)).map_err(|error| {
            format!(
                "failed to bind admin listener on {}:{}: {error}",
                config.host, config.admin_port
            )
        })?;

    let api_app = Arc::clone(&app);
    let api_server = thread::spawn(move || serve_listener(api_listener, api_app));

    let admin_app = Arc::clone(&app);
    let admin_server = thread::spawn(move || serve_listener(admin_listener, admin_app));

    api_server
        .join()
        .map_err(|_| "API server thread panicked".to_string())?;
    admin_server
        .join()
        .map_err(|_| "admin server thread panicked".to_string())?;

    Ok(())
}

fn parse_args<I>(args: I) -> Result<Config, String>
where
    I: IntoIterator<Item = String>,
{
    let mut host = String::from("127.0.0.1");
    let mut port = 3110_u16;
    let mut admin_port = 3111_u16;

    let mut codex_mode = CodexRuntimeMode::Auto;
    let mut codex_endpoint = Some("ws://127.0.0.1:4222".to_string());
    let mut codex_command = String::from("codex");
    let mut codex_args = vec!["app-server".to_string()];
    let mut codex_args_overridden = false;
    let mut pairing_base_url: Option<String> = None;

    let mut args_iter = args.into_iter();
    while let Some(argument) = args_iter.next() {
        match argument.as_str() {
            "--host" => {
                host = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --host"))?;
            }
            "--port" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --port"))?;
                port = value
                    .parse()
                    .map_err(|_| format!("invalid --port value: {value}"))?;
            }
            "--admin-port" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --admin-port"))?;
                admin_port = value
                    .parse()
                    .map_err(|_| format!("invalid --admin-port value: {value}"))?;
            }
            "--codex-mode" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-mode"))?;
                codex_mode = CodexRuntimeMode::from_flag(&value)?;
            }
            "--codex-endpoint" => {
                codex_endpoint = Some(
                    args_iter
                        .next()
                        .ok_or_else(|| String::from("missing value for --codex-endpoint"))?,
                );
            }
            "--codex-command" => {
                codex_command = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-command"))?;
            }
            "--codex-arg" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-arg"))?;
                if !codex_args_overridden {
                    codex_args.clear();
                    codex_args_overridden = true;
                }
                codex_args.push(value);
            }
            "--pairing-base-url" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --pairing-base-url"))?;
                pairing_base_url = Some(value.trim().to_string());
            }
            "--help" | "-h" => {
                return Err(String::from(
                    "usage: bridge-server [--host <ip-or-hostname>] [--port <u16>] [--admin-port <u16>] [--pairing-base-url <https://bridge.ts.net>] [--codex-mode <auto|spawn|attach>] [--codex-endpoint <ws-url>] [--codex-command <binary>] [--codex-arg <arg>]",
                ));
            }
            _ => {
                return Err(format!("unknown argument: {argument}"));
            }
        }
    }

    if codex_mode == CodexRuntimeMode::Attach && codex_endpoint.is_none() {
        return Err(String::from(
            "--codex-endpoint is required when --codex-mode attach",
        ));
    }

    let pairing_base_url = pairing_base_url.unwrap_or_else(|| format!("http://{host}:{port}"));

    Ok(Config {
        host,
        port,
        admin_port,
        pairing_base_url,
        codex_runtime: CodexRuntimeConfig {
            mode: codex_mode,
            endpoint: codex_endpoint,
            command: codex_command,
            args: codex_args,
        },
    })
}

#[derive(Debug)]
struct BridgeApplication {
    thread_api: Mutex<ThreadApiService>,
    runtime: Mutex<CodexRuntimeSupervisor>,
    stream_router: StreamRouter,
    pairing_sessions: Mutex<PairingSessionService>,
}

impl BridgeApplication {
    fn new(
        thread_api: ThreadApiService,
        runtime: CodexRuntimeSupervisor,
        stream_router: StreamRouter,
        pairing_sessions: PairingSessionService,
    ) -> Self {
        Self {
            thread_api: Mutex::new(thread_api),
            runtime: Mutex::new(runtime),
            stream_router,
            pairing_sessions: Mutex::new(pairing_sessions),
        }
    }

    fn runtime_snapshot(&self) -> RuntimeSnapshot {
        self.runtime
            .lock()
            .expect("runtime mutex should not be poisoned")
            .snapshot()
    }
}

fn serve_listener(listener: TcpListener, app: Arc<BridgeApplication>) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let app = Arc::clone(&app);
                thread::spawn(move || {
                    if let Err(error) = handle_connection(stream, &app) {
                        eprintln!("connection error: {error}");
                    }
                });
            }
            Err(error) => {
                eprintln!("listener error: {error}");
                break;
            }
        }
    }
}

fn handle_connection(mut stream: TcpStream, app: &Arc<BridgeApplication>) -> Result<(), String> {
    let mut preview_buffer = [0_u8; 4096];
    let preview_bytes = stream
        .peek(&mut preview_buffer)
        .map_err(|error| format!("failed to peek request: {error}"))?;

    let preview_text = String::from_utf8_lossy(&preview_buffer[..preview_bytes]);
    let request_line = preview_text.lines().next().unwrap_or_default();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let target = request_parts.next().unwrap_or_default();

    if method == "GET"
        && target.starts_with("/stream")
        && is_websocket_upgrade_request(&preview_text)
    {
        return handle_websocket_connection(stream, app, target);
    }

    let mut request_buffer = [0_u8; 8192];
    let bytes_read = stream
        .read(&mut request_buffer)
        .map_err(|error| format!("failed to read request: {error}"))?;
    let request_text = String::from_utf8_lossy(&request_buffer[..bytes_read]);
    let request_line = request_text.lines().next().unwrap_or_default();

    let response = route_request(request_line, app);
    stream
        .write_all(response.as_bytes())
        .map_err(|error| format!("failed to write response: {error}"))
}

fn handle_websocket_connection(
    stream: TcpStream,
    app: &BridgeApplication,
    target: &str,
) -> Result<(), String> {
    let mut websocket =
        accept(stream).map_err(|error| format!("websocket accept failed: {error}"))?;

    let mut thread_ids = parse_stream_thread_ids(target);
    if thread_ids.is_empty() {
        thread_ids = app
            .thread_api
            .lock()
            .expect("thread API mutex should not be poisoned")
            .list_response()
            .threads
            .into_iter()
            .map(|thread| thread.thread_id)
            .collect::<Vec<_>>();
    }

    let subscription = app.stream_router.subscribe(thread_ids.clone());
    let subscribed = json!({
        "contract_version": shared_contracts::CONTRACT_VERSION,
        "event": "subscribed",
        "thread_ids": thread_ids,
    });

    websocket
        .send(Message::Text(subscribed.to_string()))
        .map_err(|error| format!("failed to send websocket subscription ack: {error}"))?;

    let result = loop {
        match subscription.receiver.recv_timeout(Duration::from_secs(15)) {
            Ok(event) => {
                let frame = serde_json::to_string(&event)
                    .expect("websocket event serialization should not fail");
                if let Err(error) = websocket.send(Message::Text(frame)) {
                    break Err(format!("failed to send websocket event: {error}"));
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                if websocket.send(Message::Ping(Vec::new())).is_err() {
                    break Ok(());
                }
            }
            Err(RecvTimeoutError::Disconnected) => break Ok(()),
        }
    };

    app.stream_router.unsubscribe(subscription.id);
    result
}

fn is_websocket_upgrade_request(request_preview: &str) -> bool {
    let mut has_upgrade_header = false;
    let mut has_connection_upgrade = false;

    for line in request_preview.lines() {
        let normalized = line.trim().to_ascii_lowercase();
        if normalized.starts_with("upgrade:") && normalized.contains("websocket") {
            has_upgrade_header = true;
        }
        if normalized.starts_with("connection:") && normalized.contains("upgrade") {
            has_connection_upgrade = true;
        }
    }

    has_upgrade_header && has_connection_upgrade
}

fn parse_stream_thread_ids(target: &str) -> Vec<String> {
    let query = target
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default();

    let mut thread_ids = HashSet::new();
    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (raw_key, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        let key = decode_component(raw_key);
        if key != "thread_id" && key != "thread_ids" {
            continue;
        }

        let value = decode_component(raw_value);
        for thread_id in value.split(',') {
            let thread_id = thread_id.trim();
            if !thread_id.is_empty() {
                thread_ids.insert(thread_id.to_string());
            }
        }
    }

    thread_ids.into_iter().collect::<Vec<_>>()
}

fn route_request(request_line: &str, app: &BridgeApplication) -> String {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();

    if method != "GET" && method != "POST" {
        return method_not_allowed_response();
    }

    let (path, query) = split_target(target);

    match (method, path) {
        ("GET", "/health") => {
            let seeded_thread_count = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .list_response()
                .threads
                .len();
            let payload = HealthResponse {
                status: "ok",
                runtime: app.runtime_snapshot(),
                api: ApiSurface {
                    endpoints: vec![
                        "POST /pairing/session",
                        "POST /pairing/finalize",
                        "POST /pairing/handshake",
                        "POST /pairing/trust/revoke",
                        "GET /threads",
                        "GET /threads/:id",
                        "GET /threads/:id/timeline",
                        "GET /threads/:id/git/status",
                        "POST /threads/:id/turns/start",
                        "POST /threads/:id/turns/steer",
                        "POST /threads/:id/turns/interrupt",
                        "POST /threads/:id/git/branch-switch",
                        "POST /threads/:id/git/pull",
                        "POST /threads/:id/git/push",
                        "WS /stream?thread_id=<id>",
                    ],
                    seeded_thread_count,
                },
            };
            json_response("200 OK", &payload)
        }
        ("GET", "/threads") => {
            let response = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .list_response();
            json_response("200 OK", &response)
        }
        (_, "/stream") => upgrade_required_response(),
        _ => route_pairing_request(method, path, &query, app)
            .or_else(|| route_thread_request(method, path, &query, app))
            .unwrap_or_else(not_found_response),
    }
}

fn route_pairing_request(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    app: &BridgeApplication,
) -> Option<String> {
    match (method, path) {
        ("POST", "/pairing/session") | ("GET", "/pairing/session") => {
            let session = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .issue_session();
            Some(json_response("200 OK", &session))
        }
        ("POST", "/pairing/finalize") => {
            let Some(session_id) = query_required(query, "session_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: session_id",
                ));
            };
            let Some(pairing_token) = query_required(query, "pairing_token") else {
                return Some(bad_request_response(
                    "missing_required_query_param: pairing_token",
                ));
            };
            let Some(phone_id) = query_required(query, "phone_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_id",
                ));
            };
            let Some(phone_name) = query_required(query, "phone_name") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_name",
                ));
            };
            let Some(bridge_id) = query_required(query, "bridge_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: bridge_id",
                ));
            };

            let request = PairingFinalizeRequest {
                session_id,
                pairing_token,
                phone_id,
                phone_name,
                bridge_id,
            };

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .finalize_trust(request);

            Some(match result {
                Ok(response) => json_response("200 OK", &response),
                Err(error) => pairing_finalize_error_response(error),
            })
        }
        ("POST", "/pairing/handshake") => {
            let Some(phone_id) = query_required(query, "phone_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_id",
                ));
            };
            let Some(bridge_id) = query_required(query, "bridge_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: bridge_id",
                ));
            };
            let Some(session_token) = query_required(query, "session_token") else {
                return Some(bad_request_response(
                    "missing_required_query_param: session_token",
                ));
            };

            let request = PairingHandshakeRequest {
                phone_id,
                bridge_id,
                session_token,
            };

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .handshake(request);

            Some(match result {
                Ok(response) => json_response("200 OK", &response),
                Err(error) => pairing_handshake_error_response(error),
            })
        }
        ("POST", "/pairing/trust/revoke") => {
            let phone_id = query
                .get("phone_id")
                .map(|value| value.trim())
                .and_then(|value| {
                    if value.is_empty() {
                        None
                    } else {
                        Some(value.to_string())
                    }
                });

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .revoke_trust(PairingRevokeRequest { phone_id });

            Some(match result {
                Ok(response) => json_response("200 OK", &response),
                Err(error) => json_error_response(
                    "500 Internal Server Error",
                    "pairing_revoke_failed",
                    "storage_error",
                    &error,
                ),
            })
        }
        _ => None,
    }
}

fn query_required(query: &HashMap<String, String>, key: &str) -> Option<String> {
    query
        .get(key)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn route_thread_request(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    app: &BridgeApplication,
) -> Option<String> {
    let thread_path = path.strip_prefix("/threads/")?;
    let segments = thread_path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();
    let thread_id = *segments.first()?;

    match (method, segments.as_slice()) {
        ("GET", [_]) => {
            let detail = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .detail_response(thread_id)?;
            Some(json_response("200 OK", &detail))
        }
        ("GET", [_, "timeline"]) => {
            let timeline = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .timeline_response(thread_id)?;
            Some(json_response("200 OK", &timeline))
        }
        ("GET", [_, "git", "status"]) => {
            let status = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .git_status_response(thread_id)?;
            Some(json_response("200 OK", &status))
        }
        ("POST", [_, "turns", "start"]) => {
            let prompt = query.get("prompt").map(String::as_str);
            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .start_turn(thread_id, prompt)?;
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "turns", "steer"]) => {
            let instruction = query.get("instruction").map(String::as_str);
            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .steer_turn(thread_id, instruction)?;
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "turns", "interrupt"]) => {
            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .interrupt_turn(thread_id)?;
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "branch-switch"]) => {
            let Some(branch) = query.get("branch") else {
                return Some(bad_request_response("missing_required_query_param: branch"));
            };

            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .switch_branch(thread_id, branch)?;
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "pull"]) => {
            let remote = query.get("remote").map(String::as_str);
            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .pull_repo(thread_id, remote)?;
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "push"]) => {
            let remote = query.get("remote").map(String::as_str);
            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .push_repo(thread_id, remote)?;
            Some(dispatch_response(app, dispatch))
        }
        _ => Some(method_not_allowed_response()),
    }
}

fn dispatch_response(app: &BridgeApplication, dispatch: MutationDispatch) -> String {
    for event in dispatch.events {
        app.stream_router.publish(event);
    }
    json_response("200 OK", &dispatch.response)
}

fn split_target(target: &str) -> (&str, HashMap<String, String>) {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    (path, parse_query_params(query))
}

fn parse_query_params(query: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();

    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (raw_key, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        params.insert(decode_component(raw_key), decode_component(raw_value));
    }

    params
}

fn decode_component(component: &str) -> String {
    let bytes = component.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                decoded.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                let maybe_hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
                if let Some(hex) = maybe_hex
                    && let Ok(value) = u8::from_str_radix(hex, 16)
                {
                    decoded.push(value);
                    index += 3;
                    continue;
                }
                decoded.push(bytes[index]);
                index += 1;
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }

    String::from_utf8_lossy(&decoded).to_string()
}

fn not_found_response() -> String {
    json_response("404 Not Found", &json!({ "error": "not_found" }))
}

fn method_not_allowed_response() -> String {
    json_response(
        "405 Method Not Allowed",
        &json!({ "error": "method_not_allowed" }),
    )
}

fn bad_request_response(message: &str) -> String {
    json_error_response("400 Bad Request", "bad_request", "bad_request", message)
}

fn pairing_finalize_error_response(error: PairingFinalizeError) -> String {
    let status = match error {
        PairingFinalizeError::UnknownPairingSession
        | PairingFinalizeError::InvalidPairingToken
        | PairingFinalizeError::PairingSessionExpired => "400 Bad Request",
        PairingFinalizeError::SessionAlreadyConsumed
        | PairingFinalizeError::TrustedPhoneConflict => "409 Conflict",
        PairingFinalizeError::BridgeIdentityMismatch
        | PairingFinalizeError::PrivateBridgePathRequired => "403 Forbidden",
        PairingFinalizeError::Storage(_) => "500 Internal Server Error",
    };

    json_error_response(
        status,
        "pairing_finalize_failed",
        error.code(),
        &error.message(),
    )
}

fn pairing_handshake_error_response(error: PairingHandshakeError) -> String {
    json_error_response(
        "403 Forbidden",
        "pairing_handshake_failed",
        error.code(),
        error.message(),
    )
}

fn json_error_response(status: &str, error: &str, code: &str, message: &str) -> String {
    json_response(
        status,
        &json!({
            "error": error,
            "code": code,
            "message": message,
        }),
    )
}

fn upgrade_required_response() -> String {
    json_response(
        "426 Upgrade Required",
        &json!({ "error": "upgrade_required", "upgrade": "websocket" }),
    )
}

fn json_response<TPayload>(status: &str, payload: &TPayload) -> String
where
    TPayload: Serialize,
{
    let body = serde_json::to_string(payload).expect("JSON serialization should not fail");
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct HealthResponse {
    status: &'static str,
    runtime: RuntimeSnapshot,
    api: ApiSurface,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApiSurface {
    endpoints: Vec<&'static str>,
    seeded_thread_count: usize,
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Duration;

    use serde_json::Value;

    use super::{
        BridgeApplication, CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, Config,
        PairingSessionService, StreamRouter, build_foundations, parse_args, route_request,
    };
    use crate::thread_api::ThreadApiService;

    #[test]
    fn parse_args_uses_defaults() {
        let config = parse_args(Vec::<String>::new()).expect("defaults should parse");

        assert_eq!(
            config,
            Config {
                host: "127.0.0.1".to_string(),
                port: 3110,
                admin_port: 3111,
                pairing_base_url: "http://127.0.0.1:3110".to_string(),
                codex_runtime: CodexRuntimeConfig {
                    mode: CodexRuntimeMode::Auto,
                    endpoint: Some("ws://127.0.0.1:4222".to_string()),
                    command: "codex".to_string(),
                    args: vec!["app-server".to_string()],
                },
            }
        );
    }

    #[test]
    fn parse_args_reads_explicit_values() {
        let config = parse_args(vec![
            "--host".to_string(),
            "0.0.0.0".to_string(),
            "--port".to_string(),
            "9999".to_string(),
            "--admin-port".to_string(),
            "9998".to_string(),
            "--codex-mode".to_string(),
            "spawn".to_string(),
            "--codex-command".to_string(),
            "sleep".to_string(),
            "--codex-arg".to_string(),
            "10".to_string(),
            "--pairing-base-url".to_string(),
            "https://bridge.ts.net".to_string(),
        ])
        .expect("explicit values should parse");

        assert_eq!(
            config,
            Config {
                host: "0.0.0.0".to_string(),
                port: 9999,
                admin_port: 9998,
                pairing_base_url: "https://bridge.ts.net".to_string(),
                codex_runtime: CodexRuntimeConfig {
                    mode: CodexRuntimeMode::Spawn,
                    endpoint: Some("ws://127.0.0.1:4222".to_string()),
                    command: "sleep".to_string(),
                    args: vec!["10".to_string()],
                },
            }
        );
    }

    #[test]
    fn parse_args_rejects_unknown_flag() {
        let error =
            parse_args(vec!["--unknown".to_string()]).expect_err("unknown flag should fail");

        assert!(error.contains("unknown argument"));
    }

    #[test]
    fn foundation_bootstrap_builds_consistent_paths() {
        let foundations = build_foundations("/tmp/bridge-core");
        let threads_path = foundations
            .persistence
            .sqlite_path_for(crate::persistence::PersistenceScope::ThreadsCache);

        assert_eq!(
            threads_path,
            std::path::PathBuf::from("/tmp/bridge-core/state/threads-cache.sqlite")
        );
    }

    #[test]
    fn parse_args_supports_codex_runtime_modes() {
        let config = parse_args(vec![
            "--codex-mode".to_string(),
            "attach".to_string(),
            "--codex-endpoint".to_string(),
            "ws://127.0.0.1:4222".to_string(),
        ])
        .expect("codex runtime flags should parse");

        assert_eq!(config.codex_runtime.mode, CodexRuntimeMode::Attach);
        assert_eq!(
            config.codex_runtime.endpoint.as_deref(),
            Some("ws://127.0.0.1:4222")
        );
    }

    #[test]
    fn thread_routes_are_available() {
        let app = test_application();

        let list_response = route_request("GET /threads HTTP/1.1", &app);
        assert!(list_response.starts_with("HTTP/1.1 200 OK"));
        assert!(list_response.contains("\"threads\""));
        assert!(!list_response.contains("lifecycle_state"));

        let detail_response = route_request("GET /threads/thread-123 HTTP/1.1", &app);
        assert!(detail_response.starts_with("HTTP/1.1 200 OK"));
        assert!(detail_response.contains("\"thread_id\":\"thread-123\""));
        assert!(detail_response.contains("\"last_turn_summary\""));

        let timeline_response = route_request("GET /threads/thread-123/timeline HTTP/1.1", &app);
        assert!(timeline_response.starts_with("HTTP/1.1 200 OK"));
        assert!(timeline_response.contains("\"events\""));
        assert!(timeline_response.contains("\"kind\":\"message_delta\""));
    }

    #[test]
    fn turn_and_git_mutation_routes_return_product_shaped_results() {
        let app = test_application();

        let turn_start = route_request(
            "POST /threads/thread-123/turns/start?prompt=Ship+threaded+streaming HTTP/1.1",
            &app,
        );
        assert!(turn_start.starts_with("HTTP/1.1 200 OK"));
        assert!(turn_start.contains("\"operation\":\"turn_start\""));
        assert!(turn_start.contains("\"thread_status\":\"running\""));

        let branch_switch = route_request(
            "POST /threads/thread-456/git/branch-switch?branch=release%2F2026 HTTP/1.1",
            &app,
        );
        assert!(branch_switch.starts_with("HTTP/1.1 200 OK"));
        assert!(branch_switch.contains("\"operation\":\"git_branch_switch\""));
        assert!(branch_switch.contains("\"repository\":\"codex-runtime-tools\""));
        assert!(branch_switch.contains("\"branch\":\"release/2026\""));

        let git_status = route_request("GET /threads/thread-456/git/status HTTP/1.1", &app);
        assert!(git_status.starts_with("HTTP/1.1 200 OK"));
        assert!(git_status.contains("\"remote\":\"upstream\""));
    }

    #[test]
    fn pairing_session_route_returns_bridge_identity_and_qr_payload() {
        let app = test_application();

        let response = route_request("POST /pairing/session HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 200 OK"));

        let body = parse_json_body(&response);
        assert_eq!(body["contract_version"], shared_contracts::CONTRACT_VERSION);
        assert_eq!(
            body["bridge_identity"]["display_name"],
            "Codex Mobile Companion"
        );
        assert_eq!(
            body["bridge_identity"]["api_base_url"],
            "https://bridge.ts.net"
        );
        assert_eq!(body["pairing_session"]["session_id"], "pairing-session-1");

        let qr_payload = body["qr_payload"]
            .as_str()
            .expect("qr payload should be a JSON string");
        let qr_payload: Value =
            serde_json::from_str(qr_payload).expect("qr payload should decode as JSON");

        assert_eq!(qr_payload["bridge_api_base_url"], "https://bridge.ts.net");
        assert_eq!(
            qr_payload["pairing_token"],
            body["pairing_session"]["pairing_token"]
        );
    }

    #[test]
    fn pairing_session_route_issues_new_session_on_each_request() {
        let app = test_application();

        let first = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let second = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));

        assert_ne!(
            first["pairing_session"]["session_id"],
            second["pairing_session"]["session_id"]
        );
        assert_ne!(
            first["pairing_session"]["pairing_token"],
            second["pairing_session"]["pairing_token"]
        );
    }

    #[test]
    fn stream_events_are_scoped_to_subscribed_thread() {
        let app = test_application();
        let thread_123 = app.stream_router.subscribe(vec!["thread-123".to_string()]);
        let thread_456 = app.stream_router.subscribe(vec!["thread-456".to_string()]);

        let response = route_request(
            "POST /threads/thread-123/turns/steer?instruction=Focus+on+routing HTTP/1.1",
            &app,
        );
        assert!(response.starts_with("HTTP/1.1 200 OK"));

        let event = thread_123
            .receiver
            .recv_timeout(Duration::from_millis(100))
            .expect("matching subscriber should receive event");
        assert_eq!(event.thread_id, "thread-123");

        let error = thread_456
            .receiver
            .recv_timeout(Duration::from_millis(100))
            .expect_err("non-matching subscriber should not receive event");
        assert!(matches!(error, RecvTimeoutError::Timeout));
    }

    #[test]
    fn pairing_finalize_consumes_session_and_rejects_reuse() {
        let app = test_application();

        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let first_finalize = route_request(&finalize_path, &app);
        assert!(first_finalize.starts_with("HTTP/1.1 200 OK"));

        let second_finalize = route_request(&finalize_path, &app);
        assert!(second_finalize.starts_with("HTTP/1.1 409 Conflict"));
        assert!(second_finalize.contains("\"code\":\"session_already_consumed\""));
    }

    #[test]
    fn pairing_handshake_fails_closed_on_bridge_identity_mismatch() {
        let app = test_application();

        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let finalize_response = route_request(&finalize_path, &app);
        assert!(finalize_response.starts_with("HTTP/1.1 200 OK"));

        let finalized = parse_json_body(&finalize_response);
        let session_token = finalized["session_token"]
            .as_str()
            .expect("session token should be present");

        let handshake_path = format!(
            "POST /pairing/handshake?phone_id=phone-1&bridge_id=bridge-other&session_token={session_token} HTTP/1.1"
        );
        let handshake = route_request(&handshake_path, &app);
        assert!(handshake.starts_with("HTTP/1.1 403 Forbidden"));
        assert!(handshake.contains("\"code\":\"bridge_identity_mismatch\""));
    }

    #[test]
    fn pairing_finalize_enforces_single_trusted_phone_per_mac() {
        let app = test_application();

        let first_session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let first_bridge_id = first_session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");
        let first_session_id = first_session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let first_pairing_token = first_session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");

        let first_finalize_path = format!(
            "POST /pairing/finalize?session_id={first_session_id}&pairing_token={first_pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={first_bridge_id} HTTP/1.1"
        );
        let first_finalize = route_request(&first_finalize_path, &app);
        assert!(first_finalize.starts_with("HTTP/1.1 200 OK"));

        let second_session =
            parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let second_session_id = second_session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let second_pairing_token = second_session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");

        let second_finalize_path = format!(
            "POST /pairing/finalize?session_id={second_session_id}&pairing_token={second_pairing_token}&phone_id=phone-2&phone_name=SecondPhone&bridge_id={first_bridge_id} HTTP/1.1"
        );
        let second_finalize = route_request(&second_finalize_path, &app);
        assert!(second_finalize.starts_with("HTTP/1.1 409 Conflict"));
        assert!(second_finalize.contains("\"code\":\"trusted_phone_conflict\""));
    }

    fn test_application() -> BridgeApplication {
        let mut runtime = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Attach,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
        });
        runtime
            .initialize()
            .expect("test runtime should initialize");

        BridgeApplication::new(
            ThreadApiService::sample(),
            runtime,
            StreamRouter::new(),
            PairingSessionService::new(
                "127.0.0.1",
                3110,
                "https://bridge.ts.net",
                unique_test_state_dir(),
            ),
        )
    }

    fn unique_test_state_dir() -> std::path::PathBuf {
        let unique = format!(
            "bridge-core-lib-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time before unix epoch")
                .as_nanos()
        );

        std::env::temp_dir().join(unique)
    }

    fn parse_json_body(response: &str) -> Value {
        let body = response
            .split("\r\n\r\n")
            .nth(1)
            .expect("response should include body");
        serde_json::from_str(body).expect("response body should decode as JSON")
    }
}
