use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};
use shared_contracts::{
    CONTRACT_VERSION, SpeechModelMutationAcceptedDto, SpeechModelStateDto, SpeechModelStatusDto,
    SpeechTranscriptionResultDto,
};
use tokio::fs;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, RwLock, Semaphore};

use crate::server::config::BridgeConfig;

const SPEECH_PROVIDER: &str = "fluid_audio";
const PARAKEET_MODEL_ID: &str = "parakeet-tdt-0.6b-v3-coreml";

pub type ProgressCallback = Arc<dyn Fn(u8) + Send + Sync>;

#[async_trait]
pub trait SpeechBackend: Send + Sync + std::fmt::Debug {
    async fn status(&self) -> Result<SpeechModelStatusDto, SpeechError>;
    async fn ensure_model(
        &self,
        progress_callback: Option<ProgressCallback>,
    ) -> Result<SpeechModelStatusDto, SpeechError>;
    async fn remove_model(&self) -> Result<SpeechModelStatusDto, SpeechError>;
    async fn transcribe_file(
        &self,
        audio_file: &Path,
    ) -> Result<SpeechTranscriptionResultDto, SpeechError>;
}

#[derive(Debug, Clone)]
pub struct SpeechService {
    backend: Arc<dyn SpeechBackend>,
    status: Arc<RwLock<SpeechModelStatusDto>>,
    operation_semaphore: Arc<Semaphore>,
    temp_directory: PathBuf,
}

#[derive(Debug, Clone)]
pub struct SpeechError {
    status_code: StatusCode,
    error: &'static str,
    code: &'static str,
    message: String,
}

#[derive(Debug)]
pub struct UnsupportedSpeechBackend;

#[derive(Debug)]
pub struct MacSpeechBackend {
    helper_binary: PathBuf,
    model_root: PathBuf,
    session: Mutex<Option<HelperSession>>,
}

#[derive(Debug)]
struct HelperSession {
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

#[derive(Debug, Serialize)]
struct HelperRequest<'a> {
    id: &'a str,
    command: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_path: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum HelperEnvelope {
    Progress {
        id: String,
        progress: u8,
    },
    Response {
        id: String,
        ok: bool,
        #[serde(default)]
        payload: Option<serde_json::Value>,
        #[serde(default)]
        error_code: Option<String>,
        #[serde(default)]
        message: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
struct HelperStatusPayload {
    provider: String,
    model_id: String,
    state: SpeechModelStateDto,
    #[serde(default)]
    last_error: Option<String>,
    #[serde(default)]
    installed_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct HelperTranscriptionPayload {
    text: String,
    duration_ms: u64,
}

impl SpeechError {
    pub fn status_code(&self) -> StatusCode {
        self.status_code
    }

    pub fn error(&self) -> &'static str {
        self.error
    }

    pub fn code(&self) -> &'static str {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            status_code: StatusCode::NOT_IMPLEMENTED,
            error: "speech_unavailable",
            code: "speech_unsupported",
            message: message.into(),
        }
    }

    pub fn not_installed() -> Self {
        Self {
            status_code: StatusCode::CONFLICT,
            error: "speech_transcription_failed",
            code: "speech_not_installed",
            message: "Parakeet is not installed on this Mac.".to_string(),
        }
    }

    pub fn install_failed(message: impl Into<String>) -> Self {
        Self {
            status_code: StatusCode::BAD_GATEWAY,
            error: "speech_install_failed",
            code: "speech_install_failed",
            message: message.into(),
        }
    }

    pub fn busy() -> Self {
        Self {
            status_code: StatusCode::CONFLICT,
            error: "speech_busy",
            code: "speech_busy",
            message: "Another speech operation is already in progress.".to_string(),
        }
    }

    pub fn helper_unavailable(message: impl Into<String>) -> Self {
        Self {
            status_code: StatusCode::SERVICE_UNAVAILABLE,
            error: "speech_helper_unavailable",
            code: "speech_helper_unavailable",
            message: message.into(),
        }
    }

    pub fn invalid_audio(message: impl Into<String>) -> Self {
        Self {
            status_code: StatusCode::BAD_REQUEST,
            error: "speech_invalid_audio",
            code: "speech_invalid_audio",
            message: message.into(),
        }
    }

    pub fn transcription_failed(message: impl Into<String>) -> Self {
        Self {
            status_code: StatusCode::BAD_GATEWAY,
            error: "speech_transcription_failed",
            code: "speech_transcription_failed",
            message: message.into(),
        }
    }
}

impl SpeechService {
    pub async fn from_config(config: &BridgeConfig) -> Self {
        let model_root = resolve_model_root(&config.state_directory);
        let temp_directory = config.state_directory.join("speech").join("tmp");
        let backend: Arc<dyn SpeechBackend> = if cfg!(target_os = "macos") {
            if let Some(helper_binary) = config.speech_helper_binary.clone() {
                Arc::new(MacSpeechBackend::new(helper_binary, model_root))
            } else {
                Arc::new(UnsupportedSpeechBackend)
            }
        } else {
            Arc::new(UnsupportedSpeechBackend)
        };

        let initial_status = match backend.status().await {
            Ok(status) => status,
            Err(error) => status_from_error(&error),
        };

        Self {
            backend,
            status: Arc::new(RwLock::new(initial_status)),
            operation_semaphore: Arc::new(Semaphore::new(1)),
            temp_directory,
        }
    }

    #[cfg(test)]
    pub fn new_for_tests(
        backend: Arc<dyn SpeechBackend>,
        temp_directory: PathBuf,
        initial_status: SpeechModelStatusDto,
    ) -> Self {
        Self {
            backend,
            status: Arc::new(RwLock::new(initial_status)),
            operation_semaphore: Arc::new(Semaphore::new(1)),
            temp_directory,
        }
    }

    pub async fn status(&self) -> SpeechModelStatusDto {
        let cached = self.status.read().await.clone();
        if matches!(
            cached.state,
            SpeechModelStateDto::Installing | SpeechModelStateDto::Busy
        ) {
            return cached;
        }

        let refreshed = match self.backend.status().await {
            Ok(status) => status,
            Err(error) => status_from_error(&error),
        };
        *self.status.write().await = refreshed.clone();
        refreshed
    }

    pub async fn ensure_model(&self) -> Result<SpeechModelMutationAcceptedDto, SpeechError> {
        let current_status = self.status().await;
        match current_status.state {
            SpeechModelStateDto::Ready => {
                return Ok(mutation_response(
                    current_status.state,
                    "Parakeet is already installed.",
                ));
            }
            SpeechModelStateDto::Installing => {
                return Ok(mutation_response(
                    current_status.state,
                    "Parakeet download is already in progress.",
                ));
            }
            SpeechModelStateDto::Unsupported => {
                return Err(SpeechError::unsupported(
                    current_status.last_error.unwrap_or_else(|| {
                        "Speech transcription is unsupported on this platform.".to_string()
                    }),
                ));
            }
            SpeechModelStateDto::Busy => return Err(SpeechError::busy()),
            SpeechModelStateDto::NotInstalled | SpeechModelStateDto::Failed => {}
        }

        let permit = self
            .operation_semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| SpeechError::busy())?;

        *self.status.write().await = SpeechModelStatusDto {
            contract_version: CONTRACT_VERSION.to_string(),
            provider: SPEECH_PROVIDER.to_string(),
            model_id: PARAKEET_MODEL_ID.to_string(),
            state: SpeechModelStateDto::Installing,
            download_progress: Some(0),
            last_error: None,
            installed_bytes: current_status.installed_bytes,
        };

        let backend = Arc::clone(&self.backend);
        let status = Arc::clone(&self.status);
        tokio::spawn(async move {
            let status_for_progress = Arc::clone(&status);
            let progress_callback: ProgressCallback = Arc::new(move |progress| {
                let status_for_progress = Arc::clone(&status_for_progress);
                tokio::spawn(async move {
                    let previous = status_for_progress.read().await.clone();
                    *status_for_progress.write().await = SpeechModelStatusDto {
                        download_progress: Some(progress),
                        ..previous
                    };
                });
            });

            let next_status = match backend.ensure_model(Some(progress_callback)).await {
                Ok(model_status) => model_status,
                Err(error) => status_from_error(&error),
            };
            *status.write().await = next_status;
            drop(permit);
        });

        Ok(mutation_response(
            SpeechModelStateDto::Installing,
            "Started downloading Parakeet.",
        ))
    }

    pub async fn remove_model(&self) -> Result<SpeechModelMutationAcceptedDto, SpeechError> {
        let current_status = self.status().await;
        if current_status.state == SpeechModelStateDto::Installing {
            return Err(SpeechError::busy());
        }
        if current_status.state == SpeechModelStateDto::Unsupported {
            return Err(SpeechError::unsupported(
                current_status.last_error.unwrap_or_else(|| {
                    "Speech transcription is unsupported on this platform.".to_string()
                }),
            ));
        }
        if current_status.state == SpeechModelStateDto::NotInstalled {
            return Ok(mutation_response(
                SpeechModelStateDto::NotInstalled,
                "Parakeet is not installed.",
            ));
        }

        let permit = self
            .operation_semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| SpeechError::busy())?;
        let result = self.backend.remove_model().await;
        drop(permit);

        let next_status = match result {
            Ok(model_status) => model_status,
            Err(error) => return Err(error),
        };
        *self.status.write().await = next_status.clone();
        Ok(mutation_response(
            next_status.state,
            "Removed local Parakeet files.",
        ))
    }

    pub async fn transcribe_bytes(
        &self,
        file_name: Option<&str>,
        audio_bytes: &[u8],
    ) -> Result<SpeechTranscriptionResultDto, SpeechError> {
        if !is_wav(audio_bytes) {
            return Err(SpeechError::invalid_audio(
                "Only WAV uploads are supported in this build.",
            ));
        }

        let current_status = self.status().await;
        match current_status.state {
            SpeechModelStateDto::Unsupported => {
                return Err(SpeechError::unsupported(
                    current_status.last_error.unwrap_or_else(|| {
                        "Speech transcription is unsupported on this platform.".to_string()
                    }),
                ));
            }
            SpeechModelStateDto::NotInstalled => return Err(SpeechError::not_installed()),
            SpeechModelStateDto::Installing | SpeechModelStateDto::Busy => {
                return Err(SpeechError::busy());
            }
            SpeechModelStateDto::Failed => {
                return Err(SpeechError::transcription_failed(
                    current_status.last_error.unwrap_or_else(|| {
                        "Speech transcription is unavailable right now.".to_string()
                    }),
                ));
            }
            SpeechModelStateDto::Ready => {}
        }

        let permit = self
            .operation_semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| SpeechError::busy())?;
        let previous_status = current_status.clone();
        *self.status.write().await = SpeechModelStatusDto {
            state: SpeechModelStateDto::Busy,
            download_progress: None,
            ..current_status
        };

        fs::create_dir_all(&self.temp_directory)
            .await
            .map_err(|error| {
                SpeechError::helper_unavailable(format!(
                    "Failed to prepare speech temp directory: {error}"
                ))
            })?;
        let temp_file = self.temp_directory.join(unique_wav_file_name(file_name));
        fs::write(&temp_file, audio_bytes).await.map_err(|error| {
            SpeechError::helper_unavailable(format!("Failed to stage audio upload: {error}"))
        })?;

        let transcription_result = self.backend.transcribe_file(&temp_file).await;
        let _ = fs::remove_file(&temp_file).await;
        drop(permit);

        match transcription_result {
            Ok(result) => {
                let refreshed_status = match self.backend.status().await {
                    Ok(status) => status,
                    Err(error) => status_from_error(&error),
                };
                *self.status.write().await = refreshed_status;
                Ok(result)
            }
            Err(error) => {
                *self.status.write().await = SpeechModelStatusDto {
                    state: previous_status.state,
                    last_error: Some(error.message.clone()),
                    ..previous_status
                };
                Err(error)
            }
        }
    }
}

impl MacSpeechBackend {
    pub fn new(helper_binary: PathBuf, model_root: PathBuf) -> Self {
        Self {
            helper_binary,
            model_root,
            session: Mutex::new(None),
        }
    }

    async fn send_request(
        &self,
        command: &'static str,
        file_path: Option<&Path>,
        progress_callback: Option<ProgressCallback>,
    ) -> Result<serde_json::Value, SpeechError> {
        let request_id = next_request_id();
        let request = HelperRequest {
            id: &request_id,
            command,
            file_path: file_path.and_then(Path::to_str),
        };
        let request_json = serde_json::to_string(&request).map_err(|error| {
            SpeechError::helper_unavailable(format!("Failed to encode helper request: {error}"))
        })?;

        let mut session_guard = self.session.lock().await;
        if session_guard.is_none() {
            *session_guard = Some(self.start_process().await?);
        }
        let session = session_guard
            .as_mut()
            .expect("speech helper session should be initialized");

        if let Err(error) = session.stdin.write_all(request_json.as_bytes()).await {
            *session_guard = None;
            return Err(SpeechError::helper_unavailable(format!(
                "Failed to send request to speech helper: {error}"
            )));
        }
        if let Err(error) = session.stdin.write_all(b"\n").await {
            *session_guard = None;
            return Err(SpeechError::helper_unavailable(format!(
                "Failed to terminate speech helper request: {error}"
            )));
        }
        if let Err(error) = session.stdin.flush().await {
            *session_guard = None;
            return Err(SpeechError::helper_unavailable(format!(
                "Failed to flush speech helper request: {error}"
            )));
        }

        loop {
            let mut line = String::new();
            let bytes_read = match session.stdout.read_line(&mut line).await {
                Ok(bytes_read) => bytes_read,
                Err(error) => {
                    *session_guard = None;
                    return Err(SpeechError::helper_unavailable(format!(
                        "Failed to read speech helper response: {error}"
                    )));
                }
            };
            if bytes_read == 0 {
                *session_guard = None;
                return Err(SpeechError::helper_unavailable(
                    "Speech helper exited unexpectedly.".to_string(),
                ));
            }

            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let envelope: HelperEnvelope = serde_json::from_str(trimmed).map_err(|error| {
                SpeechError::helper_unavailable(format!(
                    "Speech helper returned malformed JSON: {error}"
                ))
            })?;

            match envelope {
                HelperEnvelope::Progress { id, progress } if id == request_id => {
                    if let Some(callback) = &progress_callback {
                        callback(progress);
                    }
                }
                HelperEnvelope::Response {
                    id,
                    ok,
                    payload,
                    error_code,
                    message,
                } if id == request_id => {
                    if ok {
                        return Ok(payload.unwrap_or(serde_json::Value::Null));
                    }
                    let message = message.unwrap_or_else(|| {
                        "Speech helper returned an unknown failure.".to_string()
                    });
                    return Err(match error_code.as_deref() {
                        Some("speech_unsupported") => SpeechError::unsupported(message),
                        Some("speech_not_installed") => SpeechError::not_installed(),
                        Some("speech_invalid_audio") => SpeechError::invalid_audio(message),
                        Some("speech_install_failed") => SpeechError::install_failed(message),
                        Some("speech_transcription_failed") => {
                            SpeechError::transcription_failed(message)
                        }
                        _ => SpeechError::helper_unavailable(message),
                    });
                }
                _ => {}
            }
        }
    }

    async fn start_process(&self) -> Result<HelperSession, SpeechError> {
        if !self.helper_binary.is_file() {
            return Err(SpeechError::helper_unavailable(format!(
                "Speech helper binary was not found at {}.",
                self.helper_binary.display()
            )));
        }

        let mut command = Command::new(&self.helper_binary);
        command.kill_on_drop(true);
        command.env(
            "CODEX_MOBILE_COMPANION_SPEECH_MODEL_ROOT",
            self.model_root.as_os_str(),
        );
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::null());

        let mut child = command.spawn().map_err(|error| {
            SpeechError::helper_unavailable(format!(
                "Failed to launch speech helper {}: {error}",
                self.helper_binary.display()
            ))
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            SpeechError::helper_unavailable("Speech helper stdin is unavailable.".to_string())
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            SpeechError::helper_unavailable("Speech helper stdout is unavailable.".to_string())
        })?;

        Ok(HelperSession {
            _child: child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }
}

#[async_trait]
impl SpeechBackend for UnsupportedSpeechBackend {
    async fn status(&self) -> Result<SpeechModelStatusDto, SpeechError> {
        Ok(unsupported_status())
    }

    async fn ensure_model(
        &self,
        _progress_callback: Option<ProgressCallback>,
    ) -> Result<SpeechModelStatusDto, SpeechError> {
        Err(SpeechError::unsupported(
            "Speech transcription is only available from the macOS shell runtime.".to_string(),
        ))
    }

    async fn remove_model(&self) -> Result<SpeechModelStatusDto, SpeechError> {
        Err(SpeechError::unsupported(
            "Speech transcription is only available from the macOS shell runtime.".to_string(),
        ))
    }

    async fn transcribe_file(
        &self,
        _audio_file: &Path,
    ) -> Result<SpeechTranscriptionResultDto, SpeechError> {
        Err(SpeechError::unsupported(
            "Speech transcription is only available from the macOS shell runtime.".to_string(),
        ))
    }
}

#[async_trait]
impl SpeechBackend for MacSpeechBackend {
    async fn status(&self) -> Result<SpeechModelStatusDto, SpeechError> {
        let payload = self.send_request("get_status", None, None).await?;
        let status: HelperStatusPayload = serde_json::from_value(payload).map_err(|error| {
            SpeechError::helper_unavailable(format!(
                "Failed to decode speech helper status response: {error}"
            ))
        })?;
        Ok(SpeechModelStatusDto {
            contract_version: CONTRACT_VERSION.to_string(),
            provider: status.provider,
            model_id: status.model_id,
            state: status.state,
            download_progress: None,
            last_error: status.last_error,
            installed_bytes: status.installed_bytes,
        })
    }

    async fn ensure_model(
        &self,
        progress_callback: Option<ProgressCallback>,
    ) -> Result<SpeechModelStatusDto, SpeechError> {
        let payload = self
            .send_request("ensure_model", None, progress_callback)
            .await?;
        let status: HelperStatusPayload = serde_json::from_value(payload).map_err(|error| {
            SpeechError::install_failed(format!(
                "Failed to decode speech helper install response: {error}"
            ))
        })?;
        Ok(SpeechModelStatusDto {
            contract_version: CONTRACT_VERSION.to_string(),
            provider: status.provider,
            model_id: status.model_id,
            state: status.state,
            download_progress: Some(100),
            last_error: status.last_error,
            installed_bytes: status.installed_bytes,
        })
    }

    async fn remove_model(&self) -> Result<SpeechModelStatusDto, SpeechError> {
        let payload = self.send_request("remove_model", None, None).await?;
        let status: HelperStatusPayload = serde_json::from_value(payload).map_err(|error| {
            SpeechError::helper_unavailable(format!(
                "Failed to decode speech helper remove response: {error}"
            ))
        })?;
        Ok(SpeechModelStatusDto {
            contract_version: CONTRACT_VERSION.to_string(),
            provider: status.provider,
            model_id: status.model_id,
            state: status.state,
            download_progress: None,
            last_error: status.last_error,
            installed_bytes: status.installed_bytes,
        })
    }

    async fn transcribe_file(
        &self,
        audio_file: &Path,
    ) -> Result<SpeechTranscriptionResultDto, SpeechError> {
        let payload = self
            .send_request("transcribe_file", Some(audio_file), None)
            .await?;
        let transcription: HelperTranscriptionPayload =
            serde_json::from_value(payload).map_err(|error| {
                SpeechError::transcription_failed(format!(
                    "Failed to decode speech helper transcription response: {error}"
                ))
            })?;
        Ok(SpeechTranscriptionResultDto {
            contract_version: CONTRACT_VERSION.to_string(),
            provider: SPEECH_PROVIDER.to_string(),
            model_id: PARAKEET_MODEL_ID.to_string(),
            text: transcription.text,
            duration_ms: transcription.duration_ms,
        })
    }
}

fn resolve_model_root(state_directory: &Path) -> PathBuf {
    state_directory
        .parent()
        .unwrap_or(state_directory)
        .join("FluidAudio")
        .join("Models")
        .join(PARAKEET_MODEL_ID)
}

fn unsupported_status() -> SpeechModelStatusDto {
    SpeechModelStatusDto {
        contract_version: CONTRACT_VERSION.to_string(),
        provider: SPEECH_PROVIDER.to_string(),
        model_id: PARAKEET_MODEL_ID.to_string(),
        state: SpeechModelStateDto::Unsupported,
        download_progress: None,
        last_error: Some(
            "Speech transcription is only available when the macOS shell provides a speech helper."
                .to_string(),
        ),
        installed_bytes: None,
    }
}

fn status_from_error(error: &SpeechError) -> SpeechModelStatusDto {
    SpeechModelStatusDto {
        contract_version: CONTRACT_VERSION.to_string(),
        provider: SPEECH_PROVIDER.to_string(),
        model_id: PARAKEET_MODEL_ID.to_string(),
        state: match error.code {
            "speech_unsupported" => SpeechModelStateDto::Unsupported,
            "speech_not_installed" => SpeechModelStateDto::NotInstalled,
            "speech_busy" => SpeechModelStateDto::Busy,
            _ => SpeechModelStateDto::Failed,
        },
        download_progress: None,
        last_error: Some(error.message.clone()),
        installed_bytes: None,
    }
}

fn mutation_response(
    state: SpeechModelStateDto,
    message: impl Into<String>,
) -> SpeechModelMutationAcceptedDto {
    SpeechModelMutationAcceptedDto {
        contract_version: CONTRACT_VERSION.to_string(),
        provider: SPEECH_PROVIDER.to_string(),
        model_id: PARAKEET_MODEL_ID.to_string(),
        state,
        message: message.into(),
    }
}

fn next_request_id() -> String {
    format!(
        "speech-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic enough")
            .as_nanos()
    )
}

fn unique_wav_file_name(file_name: Option<&str>) -> String {
    let hint = file_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(|value| Path::new(value).file_name())
        .and_then(|value| value.to_str())
        .unwrap_or("voice-message.wav");
    format!("{}-{}", next_request_id(), hint)
}

fn is_wav(audio_bytes: &[u8]) -> bool {
    audio_bytes.len() >= 12 && &audio_bytes[0..4] == b"RIFF" && &audio_bytes[8..12] == b"WAVE"
}
