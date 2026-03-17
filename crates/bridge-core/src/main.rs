use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Config {
    host: String,
    port: u16,
    admin_port: u16,
}

fn main() -> Result<(), String> {
    let config = parse_args(std::env::args().skip(1))?;

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

    let api_server = thread::spawn(move || serve_listener(api_listener));
    let admin_server = thread::spawn(move || serve_listener(admin_listener));

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
            "--help" | "-h" => {
                return Err(String::from(
                    "usage: bridge-server [--host <ip-or-hostname>] [--port <u16>] [--admin-port <u16>]",
                ));
            }
            _ => {
                return Err(format!("unknown argument: {argument}"));
            }
        }
    }

    Ok(Config {
        host,
        port,
        admin_port,
    })
}

fn serve_listener(listener: TcpListener) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle_connection(stream) {
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

fn handle_connection(mut stream: TcpStream) -> Result<(), String> {
    let mut request_buffer = [0_u8; 1024];
    let bytes_read = stream
        .read(&mut request_buffer)
        .map_err(|error| format!("failed to read request: {error}"))?;

    let request_text = String::from_utf8_lossy(&request_buffer[..bytes_read]);
    let request_line = request_text.lines().next().unwrap_or_default();

    let response = if request_line.starts_with("GET /health ") {
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    } else {
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found"
    };

    stream
        .write_all(response.as_bytes())
        .map_err(|error| format!("failed to write response: {error}"))
}

#[cfg(test)]
mod tests {
    use super::Config;
    use super::parse_args;

    #[test]
    fn parse_args_uses_defaults() {
        let config = parse_args(Vec::<String>::new()).expect("defaults should parse");

        assert_eq!(
            config,
            Config {
                host: "127.0.0.1".to_string(),
                port: 3110,
                admin_port: 3111,
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
        ])
        .expect("explicit values should parse");

        assert_eq!(
            config,
            Config {
                host: "0.0.0.0".to_string(),
                port: 9999,
                admin_port: 9998,
            }
        );
    }

    #[test]
    fn parse_args_rejects_unknown_flag() {
        let error =
            parse_args(vec!["--unknown".to_string()]).expect_err("unknown flag should fail");

        assert!(error.contains("unknown argument"));
    }
}
