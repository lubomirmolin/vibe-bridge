use super::super::mapping::map_thread_snapshot;
use super::archive::fetch_thread_snapshot_from_archive;
use super::notifications::CodexNotificationNormalizer;
use super::rpc::{
    read_thread_with_resume, should_resume_thread, start_turn, start_turn_with_resume,
};
use super::transport::{connect_read_transport, connect_transport};
use super::*;

type EventCallback = Box<dyn Fn(BridgeEventEnvelope<Value>) + Send + 'static>;
type NotificationEventCallback = Arc<dyn Fn(BridgeEventEnvelope<Value>) + Send + Sync + 'static>;
type NotificationStaleCallback = Arc<dyn Fn(String) + Send + Sync + 'static>;
type TurnCompletedCallback = Box<dyn Fn(String) + Send + 'static>;
type ControlRequestHandler =
    Arc<dyn Fn(GatewayTurnControlRequest) -> Result<Option<Value>, String> + Send + Sync + 'static>;
type StreamFinishedCallback =
    Arc<dyn Fn(String, GatewayTurnStreamActivity) + Send + Sync + 'static>;

#[derive(Debug, Default)]
pub(in crate::server::gateway) struct CodexThreadActors {
    actors: Mutex<HashMap<String, Arc<CodexThreadActor>>>,
}

impl CodexThreadActors {
    pub(in crate::server::gateway) fn actor(
        &self,
        thread_id: &str,
        config: &BridgeCodexConfig,
    ) -> Arc<CodexThreadActor> {
        let mut actors = self
            .actors
            .lock()
            .expect("codex thread actor lock should not be poisoned");
        actors
            .entry(thread_id.to_string())
            .or_insert_with(|| {
                Arc::new(CodexThreadActor::new(thread_id.to_string(), config.clone()))
            })
            .clone()
    }

    pub(in crate::server::gateway) fn prime_actor(
        &self,
        thread_id: &str,
        config: &BridgeCodexConfig,
        transport: CodexJsonTransport,
    ) -> Result<Arc<CodexThreadActor>, String> {
        let actor = self.actor(thread_id, config);
        actor.prime_transport(transport)?;
        Ok(actor)
    }
}

#[derive(Debug)]
pub(in crate::server::gateway) struct CodexThreadActor {
    sender: mpsc::Sender<ActorCommand>,
}

impl CodexThreadActor {
    fn new(thread_id: String, config: BridgeCodexConfig) -> Self {
        let (sender, receiver) = mpsc::channel::<ActorCommand>();
        let actor_sender = sender.clone();
        std::thread::Builder::new()
            .name(format!("codex-thread-actor-{thread_id}"))
            .spawn(move || run_actor_loop(thread_id, config, receiver, actor_sender))
            .expect("codex thread actor should spawn");
        Self { sender }
    }

    pub(in crate::server::gateway) fn prime_transport(
        &self,
        transport: CodexJsonTransport,
    ) -> Result<(), String> {
        self.sender
            .send(ActorCommand::PrimeTransport { transport })
            .map_err(|error| format!("failed to prime codex thread actor transport: {error}"))
    }

    pub(in crate::server::gateway) fn fetch_snapshot(&self) -> Result<ThreadSnapshotDto, String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::FetchSnapshot { reply: reply_tx })
            .map_err(|error| format!("failed to request codex thread snapshot: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive codex thread snapshot: {error}"))?
    }

    pub(in crate::server::gateway) fn start_turn_streaming(
        &self,
        request: TurnStartRequest,
        on_event: EventCallback,
        on_control_request: ControlRequestHandler,
        on_turn_completed: TurnCompletedCallback,
        on_stream_finished: StreamFinishedCallback,
    ) -> Result<GatewayTurnMutation, String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::StartTurnStreaming {
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
                reply: reply_tx,
            })
            .map_err(|error| format!("failed to start codex turn stream via actor: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive codex turn-start result: {error}"))?
    }

    pub(in crate::server::gateway) fn resolve_active_turn_id(&self) -> Result<String, String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::ResolveActiveTurnId { reply: reply_tx })
            .map_err(|error| format!("failed to resolve active turn id via actor: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive active turn id: {error}"))?
    }

    pub(in crate::server::gateway) fn lifecycle_state(
        &self,
    ) -> Result<GatewayThreadLifecycleState, String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::LifecycleState { reply: reply_tx })
            .map_err(|error| format!("failed to request actor lifecycle state: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive actor lifecycle state: {error}"))?
    }

    pub(in crate::server::gateway) fn interrupt_turn(
        &self,
        turn_id: String,
    ) -> Result<GatewayTurnMutation, String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::InterruptTurn {
                turn_id,
                reply: reply_tx,
            })
            .map_err(|error| format!("failed to request interrupt via actor: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive interrupt response: {error}"))?
    }

    pub(in crate::server::gateway) fn set_thread_name(&self, name: String) -> Result<(), String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::SetThreadName {
                name,
                reply: reply_tx,
            })
            .map_err(|error| format!("failed to request thread rename via actor: {error}"))?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive thread rename response: {error}"))?
    }

    pub(in crate::server::gateway) fn ensure_notification_stream(
        &self,
        on_event: NotificationEventCallback,
        on_stale_rollout: NotificationStaleCallback,
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.sender
            .send(ActorCommand::EnsureNotificationStream {
                on_event,
                on_stale_rollout,
                reply: reply_tx,
            })
            .map_err(|error| {
                format!("failed to request codex notification stream via actor: {error}")
            })?;
        reply_rx
            .recv()
            .map_err(|error| format!("failed to receive notification stream result: {error}"))?
    }
}

enum ActorCommand {
    PrimeTransport {
        transport: CodexJsonTransport,
    },
    FetchSnapshot {
        reply: mpsc::SyncSender<Result<ThreadSnapshotDto, String>>,
    },
    StartTurnStreaming {
        request: TurnStartRequest,
        on_event: EventCallback,
        on_control_request: ControlRequestHandler,
        on_turn_completed: TurnCompletedCallback,
        on_stream_finished: StreamFinishedCallback,
        reply: mpsc::SyncSender<Result<GatewayTurnMutation, String>>,
    },
    ResolveActiveTurnId {
        reply: mpsc::SyncSender<Result<String, String>>,
    },
    LifecycleState {
        reply: mpsc::SyncSender<Result<GatewayThreadLifecycleState, String>>,
    },
    InterruptTurn {
        turn_id: String,
        reply: mpsc::SyncSender<Result<GatewayTurnMutation, String>>,
    },
    SetThreadName {
        name: String,
        reply: mpsc::SyncSender<Result<(), String>>,
    },
    EnsureNotificationStream {
        on_event: NotificationEventCallback,
        on_stale_rollout: NotificationStaleCallback,
        reply: mpsc::SyncSender<Result<(), String>>,
    },
    StreamFinished {
        transport: CodexJsonTransport,
    },
    NotificationStreamFinished {
        stale_rollout: bool,
    },
}

#[derive(Debug, Clone, Default)]
struct ActiveTurnAccumulator {
    saw_user_message: bool,
    saw_assistant_message: bool,
    saw_workflow_event: bool,
    saw_turn_completed: bool,
}

impl ActiveTurnAccumulator {
    fn record_event(&mut self, event: &BridgeEventEnvelope<Value>) {
        match event.kind {
            BridgeEventKind::MessageDelta => {
                match event.payload.get("role").and_then(Value::as_str) {
                    Some("user") => self.saw_user_message = true,
                    Some("assistant") => self.saw_assistant_message = true,
                    _ => {}
                }
            }
            BridgeEventKind::PlanDelta
            | BridgeEventKind::CommandDelta
            | BridgeEventKind::FileChange
            | BridgeEventKind::UserInputRequested => {
                self.saw_workflow_event = true;
            }
            _ => {}
        }
    }

    fn record_control_request(&mut self, request: &GatewayTurnControlRequest) {
        if matches!(
            request,
            GatewayTurnControlRequest::CodexApproval { .. }
                | GatewayTurnControlRequest::CodexRequestUserInput { .. }
        ) {
            self.saw_workflow_event = true;
        }
    }

    fn record_turn_completed(&mut self) {
        self.saw_turn_completed = true;
    }

    fn finish(self) -> GatewayTurnStreamActivity {
        GatewayTurnStreamActivity {
            saw_user_message: self.saw_user_message,
            saw_assistant_message: self.saw_assistant_message,
            saw_workflow_event: self.saw_workflow_event,
            saw_turn_completed: self.saw_turn_completed,
        }
    }
}

enum ParsedActorStreamMessage {
    Ignore,
    Control {
        request_id: Value,
        request: GatewayTurnControlRequest,
    },
    Notification {
        method: String,
        event: Option<BridgeEventEnvelope<Value>>,
        turn_completed: bool,
    },
}

fn run_actor_loop(
    thread_id: String,
    config: BridgeCodexConfig,
    receiver: mpsc::Receiver<ActorCommand>,
    sender: mpsc::Sender<ActorCommand>,
) {
    let mut transport: Option<CodexJsonTransport> = None;
    let mut active_turn_id: Option<String> = None;
    let mut stream_active = false;
    let mut notification_requested = false;
    let mut notification_stream_active = false;
    let mut notification_on_event: Option<NotificationEventCallback> = None;
    let mut notification_on_stale_rollout: Option<NotificationStaleCallback> = None;

    while let Ok(command) = receiver.recv() {
        match command {
            ActorCommand::PrimeTransport {
                transport: primed_transport,
            } => {
                transport = Some(primed_transport);
            }
            ActorCommand::FetchSnapshot { reply } => {
                let result = fetch_snapshot_for_actor(&config, &thread_id, transport.as_mut());
                let _ = reply.send(result);
            }
            ActorCommand::StartTurnStreaming {
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
                reply,
            } => {
                if stream_active {
                    let _ = reply.send(Err(format!(
                        "thread {thread_id} already has an active codex stream"
                    )));
                    continue;
                }
                let had_actor_transport = transport.is_some();
                let mut stream_transport = match transport.take() {
                    Some(existing) => existing,
                    None => match connect_transport(&config) {
                        Ok(transport) => transport,
                        Err(error) => {
                            let _ = reply.send(Err(error));
                            continue;
                        }
                    },
                };

                let payload = if had_actor_transport {
                    match start_turn(
                        &mut stream_transport,
                        &thread_id,
                        &request.prompt,
                        &request.images,
                        request.model.as_deref(),
                        request.effort.as_deref(),
                        request.mode,
                    ) {
                        Ok(payload) => payload,
                        Err(error) if should_resume_thread(&error) => {
                            match start_turn_with_resume(
                                &mut stream_transport,
                                &thread_id,
                                &request.prompt,
                                &request.images,
                                request.model.as_deref(),
                                request.effort.as_deref(),
                                request.mode,
                            ) {
                                Ok(payload) => payload,
                                Err(error) => {
                                    transport = Some(stream_transport);
                                    let _ = reply.send(Err(error));
                                    continue;
                                }
                            }
                        }
                        Err(error) => {
                            transport = Some(stream_transport);
                            let _ = reply.send(Err(error));
                            continue;
                        }
                    }
                } else {
                    match start_turn_with_resume(
                        &mut stream_transport,
                        &thread_id,
                        &request.prompt,
                        &request.images,
                        request.model.as_deref(),
                        request.effort.as_deref(),
                        request.mode,
                    ) {
                        Ok(payload) => payload,
                        Err(error) => {
                            let _ = reply.send(Err(error));
                            continue;
                        }
                    }
                };

                let accepted_turn_id = payload.turn.id.clone();
                let accepted = GatewayTurnMutation {
                    response: TurnMutationAcceptedDto {
                        contract_version: CONTRACT_VERSION.to_string(),
                        thread_id: thread_id.clone(),
                        thread_status: ThreadStatus::Running,
                        message: format!("turn {} started", payload.turn.id),
                        turn_id: Some(payload.turn.id.clone()),
                        client_message_id: None,
                        client_turn_intent_id: request.client_turn_intent_id.clone(),
                    },
                    turn_id: Some(payload.turn.id),
                };

                if reply.send(Ok(accepted.clone())).is_err() {
                    transport = Some(stream_transport);
                    continue;
                }

                active_turn_id = Some(accepted_turn_id);
                stream_active = true;
                let stream_thread_id = thread_id.clone();
                let stream_sender = sender.clone();
                std::thread::spawn(move || {
                    run_stream_loop(
                        stream_thread_id,
                        stream_transport,
                        request.request_id,
                        on_event,
                        on_control_request,
                        on_turn_completed,
                        on_stream_finished,
                        stream_sender,
                    );
                });
            }
            ActorCommand::ResolveActiveTurnId { reply } => {
                let result = if let Some(turn_id) = active_turn_id.clone() {
                    Ok(turn_id)
                } else {
                    resolve_active_turn_id_for_actor(&config, &thread_id, transport.as_mut()).map(
                        |turn_id| {
                            active_turn_id = Some(turn_id.clone());
                            turn_id
                        },
                    )
                };
                let _ = reply.send(result);
            }
            ActorCommand::LifecycleState { reply } => {
                let _ = reply.send(Ok(GatewayThreadLifecycleState {
                    active_turn_id: active_turn_id.clone(),
                    stream_active,
                }));
            }
            ActorCommand::InterruptTurn { turn_id, reply } => {
                let result =
                    interrupt_turn_for_actor(&config, &thread_id, &turn_id, transport.as_mut())
                        .map(|mutation| {
                            active_turn_id = None;
                            mutation
                        });
                let _ = reply.send(result);
            }
            ActorCommand::SetThreadName { name, reply } => {
                let result =
                    set_thread_name_for_actor(&config, &thread_id, &name, transport.as_mut());
                let _ = reply.send(result);
            }
            ActorCommand::EnsureNotificationStream {
                on_event,
                on_stale_rollout,
                reply,
            } => {
                notification_requested = true;
                notification_on_event = Some(on_event);
                notification_on_stale_rollout = Some(on_stale_rollout);
                if !stream_active && !notification_stream_active {
                    start_notification_stream_loop(
                        &thread_id,
                        &config,
                        &sender,
                        notification_on_event.as_ref(),
                    );
                    notification_stream_active = true;
                }
                let _ = reply.send(Ok(()));
            }
            ActorCommand::StreamFinished {
                transport: returned_transport,
            } => {
                transport = Some(returned_transport);
                active_turn_id = None;
                stream_active = false;
                if notification_requested && !notification_stream_active {
                    start_notification_stream_loop(
                        &thread_id,
                        &config,
                        &sender,
                        notification_on_event.as_ref(),
                    );
                    notification_stream_active = true;
                }
            }
            ActorCommand::NotificationStreamFinished { stale_rollout } => {
                notification_stream_active = false;
                if stale_rollout {
                    notification_requested = false;
                    if let Some(on_stale_rollout) = notification_on_stale_rollout.as_ref() {
                        on_stale_rollout(thread_id.clone());
                    }
                    continue;
                }
                if notification_requested && !stream_active {
                    start_notification_stream_loop(
                        &thread_id,
                        &config,
                        &sender,
                        notification_on_event.as_ref(),
                    );
                    notification_stream_active = true;
                }
            }
        }
    }
}

fn start_notification_stream_loop(
    thread_id: &str,
    config: &BridgeCodexConfig,
    sender: &mpsc::Sender<ActorCommand>,
    on_event: Option<&NotificationEventCallback>,
) {
    let Some(on_event) = on_event.cloned() else {
        return;
    };
    let thread_id = thread_id.to_string();
    let config = config.clone();
    let sender = sender.clone();
    std::thread::spawn(move || {
        run_notification_stream_loop(thread_id, config, on_event, sender);
    });
}

fn fetch_snapshot_for_actor(
    config: &BridgeCodexConfig,
    thread_id: &str,
    transport: Option<&mut CodexJsonTransport>,
) -> Result<ThreadSnapshotDto, String> {
    let use_actor_transport = transport.is_some();
    let mut owned_transport;
    let transport = if let Some(transport) = transport {
        transport
    } else {
        owned_transport = connect_read_transport(config)?;
        &mut owned_transport
    };

    match read_thread_with_resume(transport, thread_id, true) {
        Ok(payload) => {
            let rpc_snapshot = map_thread_snapshot(payload.thread);
            let archive_snapshot = fetch_thread_snapshot_from_archive(config, thread_id).ok();
            eprintln!(
                "bridge codex actor snapshot compare thread_id={thread_id} actor_transport={} rpc={} archive={}",
                use_actor_transport,
                summarize_snapshot_for_debug(&rpc_snapshot),
                archive_snapshot
                    .as_ref()
                    .map(summarize_snapshot_for_debug)
                    .unwrap_or_else(|| "<unavailable>".to_string())
            );
            Ok(rpc_snapshot)
        }
        Err(error) if error.contains("not found") => {
            fetch_thread_snapshot_from_archive(config, thread_id)
        }
        Err(error) => Err(error),
    }
}

fn resolve_active_turn_id_for_actor(
    config: &BridgeCodexConfig,
    thread_id: &str,
    transport: Option<&mut CodexJsonTransport>,
) -> Result<String, String> {
    let mut owned_transport;
    let transport = if let Some(transport) = transport {
        transport
    } else {
        owned_transport = connect_read_transport(config)?;
        &mut owned_transport
    };
    let payload = read_thread_with_resume(transport, thread_id, true)?;
    payload
        .thread
        .turns
        .last()
        .map(|turn| turn.id.clone())
        .ok_or_else(|| format!("no active turn found for thread {thread_id}"))
}

fn interrupt_turn_for_actor(
    config: &BridgeCodexConfig,
    thread_id: &str,
    turn_id: &str,
    transport: Option<&mut CodexJsonTransport>,
) -> Result<GatewayTurnMutation, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let mut owned_transport;
    let transport = if let Some(transport) = transport {
        transport
    } else {
        owned_transport = connect_transport(config)?;
        &mut owned_transport
    };
    transport.request(
        "turn/interrupt",
        json!({
            "threadId": native_thread_id,
            "turnId": turn_id,
        }),
    )?;
    Ok(GatewayTurnMutation {
        response: TurnMutationAcceptedDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            thread_status: ThreadStatus::Interrupted,
            message: "interrupt requested".to_string(),
            turn_id: None,
            client_message_id: None,
            client_turn_intent_id: None,
        },
        turn_id: None,
    })
}

fn set_thread_name_for_actor(
    config: &BridgeCodexConfig,
    thread_id: &str,
    name: &str,
    transport: Option<&mut CodexJsonTransport>,
) -> Result<(), String> {
    let normalized_name = name.trim();
    if normalized_name.is_empty() {
        return Ok(());
    }
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let mut owned_transport;
    let transport = if let Some(transport) = transport {
        transport
    } else {
        owned_transport = connect_transport(config)?;
        &mut owned_transport
    };
    transport.request(
        "thread/name/set",
        json!({
            "threadId": native_thread_id,
            "name": normalized_name,
        }),
    )?;
    Ok(())
}

fn run_stream_loop(
    thread_id: String,
    mut transport: CodexJsonTransport,
    request_id: Option<String>,
    on_event: EventCallback,
    on_control_request: ControlRequestHandler,
    on_turn_completed: TurnCompletedCallback,
    on_stream_finished: StreamFinishedCallback,
    sender: mpsc::Sender<ActorCommand>,
) {
    let stream_started_at = Instant::now();
    let mut normalizer = CodexNotificationNormalizer::default();
    let mut activity = ActiveTurnAccumulator::default();
    let mut observed_notification_count: u64 = 0;
    let mut last_method = "<none>".to_string();

    loop {
        let message = match transport.next_message("turn stream") {
            Ok(Some(message)) => message,
            Ok(None) => {
                eprintln!(
                    "bridge codex actor stream ended unexpectedly (EOF) request_id={} thread_id={thread_id} notifications={observed_notification_count} elapsed_ms={}",
                    request_id.as_deref().unwrap_or("<none>"),
                    stream_started_at.elapsed().as_millis()
                );
                break;
            }
            Err(error) => {
                eprintln!(
                    "bridge codex actor stream next_message failed request_id={} thread_id={thread_id} notifications={observed_notification_count} last_method={last_method} elapsed_ms={} error={error}",
                    request_id.as_deref().unwrap_or("<none>"),
                    stream_started_at.elapsed().as_millis()
                );
                break;
            }
        };
        match parse_actor_stream_message(&thread_id, &mut normalizer, &message) {
            ParsedActorStreamMessage::Ignore => continue,
            ParsedActorStreamMessage::Control {
                request_id: request_id_value,
                request: control_request,
            } => {
                activity.record_control_request(&control_request);
                match on_control_request(control_request) {
                    Ok(Some(response_payload)) => {
                        if let Err(error) = transport.respond(&request_id_value, response_payload) {
                            eprintln!(
                                "failed to send codex actor control response for {thread_id}: {error}"
                            );
                            break;
                        }
                    }
                    Ok(None) => {}
                    Err(error) => {
                        let _ = transport.respond_error(&request_id_value, -32000, &error);
                    }
                }
            }
            ParsedActorStreamMessage::Notification {
                method,
                event,
                turn_completed,
            } => {
                observed_notification_count = observed_notification_count.saturating_add(1);
                last_method = method;
                if let Some(event) = event {
                    activity.record_event(&event);
                    on_event(event);
                }
                if turn_completed {
                    activity.record_turn_completed();
                    eprintln!(
                        "bridge codex actor stream completed request_id={} thread_id={thread_id} notifications={observed_notification_count} elapsed_ms={}",
                        request_id.as_deref().unwrap_or("<none>"),
                        stream_started_at.elapsed().as_millis()
                    );
                    on_turn_completed(thread_id.clone());
                    break;
                }
            }
        }
    }

    let activity = activity.finish();
    eprintln!(
        "bridge codex actor stream finished callback request_id={} thread_id={thread_id} notifications={observed_notification_count} last_method={last_method} elapsed_ms={} activity=user:{} assistant:{} workflow:{} completed:{}",
        request_id.as_deref().unwrap_or("<none>"),
        stream_started_at.elapsed().as_millis(),
        activity.saw_user_message,
        activity.saw_assistant_message,
        activity.saw_workflow_event,
        activity.saw_turn_completed
    );
    on_stream_finished(thread_id.clone(), activity);
    let _ = sender.send(ActorCommand::StreamFinished { transport });
}

fn parse_actor_stream_message(
    thread_id: &str,
    normalizer: &mut CodexNotificationNormalizer,
    message: &Value,
) -> ParsedActorStreamMessage {
    if let Some(request_id_value) = message.get("id").cloned() {
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return ParsedActorStreamMessage::Ignore;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let request = match method {
            "item/tool/requestUserInput" => GatewayTurnControlRequest::CodexRequestUserInput {
                request_id: request_id_value.clone(),
                params,
            },
            _ => GatewayTurnControlRequest::CodexApproval {
                request_id: request_id_value.clone(),
                method: method.to_string(),
                params,
            },
        };
        return ParsedActorStreamMessage::Control {
            request_id: request_id_value,
            request,
        };
    }

    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return ParsedActorStreamMessage::Ignore;
    };
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let event = normalizer
        .normalize(method, &params)
        .filter(|event| event.thread_id == thread_id);
    ParsedActorStreamMessage::Notification {
        method: method.to_string(),
        event,
        turn_completed: method == "turn/completed",
    }
}

fn run_notification_stream_loop(
    thread_id: String,
    config: BridgeCodexConfig,
    on_event: NotificationEventCallback,
    sender: mpsc::Sender<ActorCommand>,
) {
    let endpoint = match config.mode {
        CodexRuntimeMode::Spawn => None,
        _ => config.endpoint.as_deref(),
    };
    let mut notifications = match super::notifications::CodexNotificationStream::start(
        &config.command,
        &config.args,
        endpoint,
    ) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!(
                "bridge codex actor notification stream failed to start thread_id={thread_id}: {error}"
            );
            std::thread::sleep(Duration::from_secs(1));
            let _ = sender.send(ActorCommand::NotificationStreamFinished {
                stale_rollout: false,
            });
            return;
        }
    };

    match resume_notification_thread_until_rollout_exists(&thread_id, |thread_id| {
        notifications.resume_thread(thread_id)
    }) {
        Ok(()) => {}
        Err(error) if is_stale_rollout_resume_error(&error) => {
            eprintln!(
                "bridge codex actor notification stream stale rollout thread_id={thread_id}: {error}"
            );
            let _ = sender.send(ActorCommand::NotificationStreamFinished {
                stale_rollout: true,
            });
            return;
        }
        Err(error) => {
            eprintln!(
                "bridge codex actor notification stream resume failed thread_id={thread_id}: {error}"
            );
            std::thread::sleep(Duration::from_secs(1));
            let _ = sender.send(ActorCommand::NotificationStreamFinished {
                stale_rollout: false,
            });
            return;
        }
    }

    loop {
        match notifications.next_event() {
            Ok(Some(event)) => {
                if event.thread_id == thread_id {
                    on_event(event);
                }
            }
            Ok(None) => {
                eprintln!("bridge codex actor notification stream closed thread_id={thread_id}");
                std::thread::sleep(Duration::from_secs(1));
                let _ = sender.send(ActorCommand::NotificationStreamFinished {
                    stale_rollout: false,
                });
                return;
            }
            Err(error) => {
                eprintln!(
                    "bridge codex actor notification stream failed thread_id={thread_id}: {error}"
                );
                std::thread::sleep(Duration::from_secs(1));
                let _ = sender.send(ActorCommand::NotificationStreamFinished {
                    stale_rollout: false,
                });
                return;
            }
        }
    }
}

fn resume_notification_thread_until_rollout_exists<F>(
    thread_id: &str,
    mut resume_thread: F,
) -> Result<(), String>
where
    F: FnMut(&str) -> Result<(), String>,
{
    const MAX_ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_millis(50);

    let mut last_stale_rollout_error: Option<String> = None;
    for attempt in 0..MAX_ATTEMPTS {
        match resume_thread(thread_id) {
            Ok(()) => return Ok(()),
            Err(error) if is_stale_rollout_resume_error(&error) => {
                last_stale_rollout_error = Some(error);
                if attempt + 1 < MAX_ATTEMPTS {
                    std::thread::sleep(RETRY_DELAY);
                    continue;
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(last_stale_rollout_error
        .unwrap_or_else(|| format!("codex rpc request 'thread/resume' failed for {thread_id}")))
}

fn is_stale_rollout_resume_error(error: &str) -> bool {
    error.contains("no rollout found") || error.contains("rollout at") && error.contains("is empty")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::projection::ProjectionStore;
    use shared_contracts::{ProviderKind, ThreadClientKind, ThreadStatus, ThreadSummaryDto};

    fn mixed_stream_fixture(path: &str) -> &'static str {
        match path {
            "request_user_input_mixed_stream.jsonl" => {
                include_str!("test_fixtures/request_user_input_mixed_stream.jsonl")
            }
            "request_permissions_mixed_stream.jsonl" => {
                include_str!("test_fixtures/request_permissions_mixed_stream.jsonl")
            }
            _ => panic!("unknown mixed codex stream fixture: {path}"),
        }
    }

    fn replay_mixed_stream_fixture(
        path: &str,
        thread_id: &str,
    ) -> (
        Vec<GatewayTurnControlRequest>,
        Vec<BridgeEventEnvelope<Value>>,
        GatewayTurnStreamActivity,
    ) {
        let mut normalizer = CodexNotificationNormalizer::default();
        let mut controls = Vec::new();
        let mut events = Vec::new();
        let mut activity = ActiveTurnAccumulator::default();

        for line in mixed_stream_fixture(path)
            .lines()
            .filter(|line| !line.trim().is_empty())
        {
            let message: Value =
                serde_json::from_str(line).expect("mixed stream fixture line should decode");
            match parse_actor_stream_message(thread_id, &mut normalizer, &message) {
                ParsedActorStreamMessage::Ignore => {}
                ParsedActorStreamMessage::Control { request, .. } => {
                    activity.record_control_request(&request);
                    controls.push(request);
                }
                ParsedActorStreamMessage::Notification {
                    event,
                    turn_completed,
                    ..
                } => {
                    if let Some(event) = event {
                        activity.record_event(&event);
                        events.push(event);
                    }
                    if turn_completed {
                        activity.record_turn_completed();
                    }
                }
            }
        }

        (controls, events, activity.finish())
    }

    async fn store_for_thread(thread_id: &str) -> ProjectionStore {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                native_thread_id: thread_id
                    .strip_prefix("codex:")
                    .unwrap_or(thread_id)
                    .to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Fixture thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/codex-fixture".to_string(),
                repository: "codex-mobile-companion".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-04-05T00:00:00Z".to_string(),
            }])
            .await;
        store
    }

    #[tokio::test]
    async fn mixed_request_user_input_fixture_preserves_control_request_and_completion_shape() {
        let (controls, events, activity) = replay_mixed_stream_fixture(
            "request_user_input_mixed_stream.jsonl",
            "codex:thread-plan-control",
        );

        assert_eq!(controls.len(), 1);
        match &controls[0] {
            GatewayTurnControlRequest::CodexRequestUserInput { request_id, params } => {
                assert_eq!(
                    request_id,
                    &Value::String("request-user-input-1".to_string())
                );
                assert_eq!(params["itemId"], "call1");
            }
            other => panic!("expected request_user_input control request, got {other:?}"),
        }

        let store = store_for_thread("codex:thread-plan-control").await;
        for event in &events {
            store.apply_live_event(event).await;
        }
        let snapshot = store
            .snapshot("codex:thread-plan-control")
            .await
            .expect("mixed stream fixture should materialize snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);
        assert_eq!(
            snapshot
                .entries
                .iter()
                .filter(|entry| entry.kind == BridgeEventKind::MessageDelta)
                .count(),
            2
        );
        assert!(activity.saw_user_message);
        assert!(activity.saw_assistant_message);
        assert!(activity.saw_workflow_event);
        assert!(activity.saw_turn_completed);
        assert!(!activity.requires_completion_snapshot_refresh());
    }

    #[tokio::test]
    async fn mixed_permissions_fixture_preserves_approval_request_and_command_result() {
        let (controls, events, activity) = replay_mixed_stream_fixture(
            "request_permissions_mixed_stream.jsonl",
            "codex:thread-approval-control",
        );

        assert_eq!(controls.len(), 1);
        match &controls[0] {
            GatewayTurnControlRequest::CodexApproval { method, params, .. } => {
                assert_eq!(method, "item/permissions/requestApproval");
                assert_eq!(params["itemId"], "call1");
                assert_eq!(params["reason"], "Select a workspace root");
            }
            other => panic!("expected permissions approval request, got {other:?}"),
        }

        let store = store_for_thread("codex:thread-approval-control").await;
        for event in &events {
            store.apply_live_event(event).await;
        }
        let snapshot = store
            .snapshot("codex:thread-approval-control")
            .await
            .expect("mixed approval stream fixture should materialize snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);
        let command_entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.event_id == "turn-approval-control-1-call1")
            .expect("command event should exist");
        assert_eq!(command_entry.kind, BridgeEventKind::CommandDelta);
        assert_eq!(command_entry.payload["command"], "pwd");
        assert_eq!(command_entry.payload["output"], "/tmp/project");
        assert!(activity.saw_user_message);
        assert!(activity.saw_workflow_event);
        assert!(activity.saw_turn_completed);
        assert!(!activity.requires_completion_snapshot_refresh());
    }
}
