use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;

use serde::Serialize;
use serde_json::json;

use codex_runtime::{
    CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, RuntimeSnapshot,
};
use logging::{InMemoryLogSink, StructuredLogger};
use persistence::PersistenceBoundary;
use secure_storage::InMemorySecureStore;
use thread_api::ThreadApiService;

pub mod codex_runtime;
pub mod logging;
pub mod persistence;
pub mod secure_storage;
pub mod thread_api;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Config {
    host: String,
    port: u16,
    admin_port: u16,
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
    let _foundations = build_foundations(".");

    let mut runtime = CodexRuntimeSupervisor::new(config.codex_runtime.clone());
    runtime.initialize()?;

    let app = Arc::new(BridgeApplication::new(ThreadApiService::sample(), runtime));

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
            "--help" | "-h" => {
                return Err(String::from(
                    "usage: bridge-server [--host <ip-or-hostname>] [--port <u16>] [--admin-port <u16>] [--codex-mode <auto|spawn|attach>] [--codex-endpoint <ws-url>] [--codex-command <binary>] [--codex-arg <arg>]",
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

    Ok(Config {
        host,
        port,
        admin_port,
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
    thread_api: ThreadApiService,
    runtime: Mutex<CodexRuntimeSupervisor>,
}

impl BridgeApplication {
    fn new(thread_api: ThreadApiService, runtime: CodexRuntimeSupervisor) -> Self {
        Self {
            thread_api,
            runtime: Mutex::new(runtime),
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
                if let Err(error) = handle_connection(stream, &app) {
                    eprintln!("connection error: {error}");
                }
            }
            Err(error) => {
                eprintln!("listener error: {error}");
                break;
            }
        }
    }
}

fn handle_connection(mut stream: TcpStream, app: &BridgeApplication) -> Result<(), String> {
    let mut request_buffer = [0_u8; 4096];
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

fn route_request(request_line: &str, app: &BridgeApplication) -> String {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();

    if method != "GET" {
        return json_response(
            "405 Method Not Allowed",
            &json!({ "error": "method_not_allowed" }),
        );
    }

    let path = target.split('?').next().unwrap_or(target);

    match path {
        "/health" => {
            let payload = HealthResponse {
                status: "ok",
                runtime: app.runtime_snapshot(),
                api: ApiSurface {
                    endpoints: vec![
                        "GET /threads",
                        "GET /threads/:id",
                        "GET /threads/:id/timeline",
                    ],
                    seeded_thread_count: app.thread_api.list_response().threads.len(),
                },
            };
            json_response("200 OK", &payload)
        }
        "/threads" => json_response("200 OK", &app.thread_api.list_response()),
        _ => {
            if let Some(thread_path) = path.strip_prefix("/threads/") {
                if let Some(thread_id) = thread_path.strip_suffix("/timeline") {
                    if thread_id.is_empty() || thread_id.contains('/') {
                        return not_found_response();
                    }
                    return match app.thread_api.timeline_response(thread_id) {
                        Some(timeline) => json_response("200 OK", &timeline),
                        None => not_found_response(),
                    };
                }

                if thread_path.is_empty() || thread_path.contains('/') {
                    return not_found_response();
                }

                return match app.thread_api.detail_response(thread_path) {
                    Some(detail) => json_response("200 OK", &detail),
                    None => not_found_response(),
                };
            }

            not_found_response()
        }
    }
}

fn not_found_response() -> String {
    json_response("404 Not Found", &json!({ "error": "not_found" }))
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
    use super::{
        BridgeApplication, CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, Config,
        build_foundations, parse_args, route_request,
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
        ])
        .expect("explicit values should parse");

        assert_eq!(
            config,
            Config {
                host: "0.0.0.0".to_string(),
                port: 9999,
                admin_port: 9998,
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

        BridgeApplication::new(ThreadApiService::sample(), runtime)
    }
}
