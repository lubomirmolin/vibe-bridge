use super::*;
use crate::server::projection::item_state::ProjectionItemPhase;

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RawThreadEventSource {
    AppServerLive,
    AppServerNotification,
    DesktopIpc,
    SnapshotRepair,
    ArchiveRepair,
    BridgeLocal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RawThreadEventPhase {
    Delta,
    Completed,
    Repair,
    Status,
    UserInput,
    Approval,
    Metadata,
}

impl RawThreadEventPhase {
    fn projection_phase(self) -> Option<ProjectionItemPhase> {
        match self {
            Self::Delta => Some(ProjectionItemPhase::Delta),
            Self::Completed => Some(ProjectionItemPhase::Final),
            Self::Repair => Some(ProjectionItemPhase::Repair),
            _ => None,
        }
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(super) struct RawThreadEvent {
    pub(super) source: RawThreadEventSource,
    pub(super) thread_id: String,
    pub(super) turn_id: Option<String>,
    pub(super) item_id: Option<String>,
    pub(super) phase: RawThreadEventPhase,
    pub(super) event: BridgeEventEnvelope<Value>,
}

#[derive(Debug)]
pub(super) enum ThreadReducerCommand {
    ApplyEvent {
        raw: Box<RawThreadEvent>,
        ack: Option<oneshot::Sender<()>>,
    },
    MergeSnapshot {
        source: RawThreadEventSource,
        snapshot: Box<ThreadSnapshotDto>,
        events: Vec<BridgeEventEnvelope<Value>>,
        ack: Option<oneshot::Sender<()>>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum OutgoingTurnPhase {
    Queued,
    TurnStartAcked,
    UserItemSeen,
    FirstAssistantSignal,
    Completed,
    Timeout,
    Failed,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(super) struct OutgoingTurnTracker {
    pub(super) phase: OutgoingTurnPhase,
    pub(super) turn_id: Option<String>,
    pub(super) timeout_reason: Option<String>,
    pub(super) last_transition_at: String,
}

impl BridgeAppState {
    pub(super) async fn dispatch_thread_event(&self, raw: RawThreadEvent) {
        let sender = self.reducer_sender(&raw.thread_id).await;
        let _ = sender.send(ThreadReducerCommand::ApplyEvent {
            raw: Box::new(raw),
            ack: None,
        });
    }

    pub(super) async fn dispatch_snapshot_merge_and_wait(
        &self,
        source: RawThreadEventSource,
        snapshot: ThreadSnapshotDto,
        events: Vec<BridgeEventEnvelope<Value>>,
    ) {
        let sender = self.reducer_sender(&snapshot.thread.thread_id).await;
        let (ack_tx, ack_rx) = oneshot::channel();
        let _ = sender.send(ThreadReducerCommand::MergeSnapshot {
            source,
            snapshot: Box::new(snapshot),
            events,
            ack: Some(ack_tx),
        });
        let _ = ack_rx.await;
    }

    pub(super) async fn mark_outgoing_turn_phase(
        &self,
        thread_id: &str,
        phase: OutgoingTurnPhase,
        turn_id: Option<String>,
        timeout_reason: Option<String>,
    ) {
        self.inner.outgoing_turns.write().await.insert(
            thread_id.to_string(),
            OutgoingTurnTracker {
                phase,
                turn_id,
                timeout_reason,
                last_transition_at: Utc::now().to_rfc3339(),
            },
        );
    }

    pub(super) async fn clear_outgoing_turn_phase(&self, thread_id: &str) {
        self.inner.outgoing_turns.write().await.remove(thread_id);
    }

    async fn reducer_sender(
        &self,
        thread_id: &str,
    ) -> tokio_mpsc::UnboundedSender<ThreadReducerCommand> {
        let mut reducers = self
            .inner
            .thread_reducers
            .lock()
            .expect("thread reducers lock should not be poisoned");
        reducers
            .entry(thread_id.to_string())
            .or_insert_with(|| {
                let (tx, rx) = tokio_mpsc::unbounded_channel();
                let state = self.clone();
                let owned_thread_id = thread_id.to_string();
                tokio::spawn(async move {
                    state.run_thread_reducer(owned_thread_id, rx).await;
                });
                tx
            })
            .clone()
    }

    async fn run_thread_reducer(
        &self,
        thread_id: String,
        mut rx: tokio_mpsc::UnboundedReceiver<ThreadReducerCommand>,
    ) {
        let mut next_bridge_seq = self
            .projections()
            .latest_bridge_seq(&thread_id)
            .await
            .unwrap_or(0);
        while let Some(command) = rx.recv().await {
            match command {
                ThreadReducerCommand::ApplyEvent { raw, ack } => {
                    let raw = *raw;
                    if let Some(phase) = raw.phase.projection_phase() {
                        self.projections()
                            .apply_live_event_with_phase(&raw.event, phase)
                            .await;
                    } else {
                        self.projections().apply_live_event(&raw.event).await;
                    }

                    self.apply_reducer_side_effects(&raw.event).await;
                    self.advance_outgoing_turn_state(&raw).await;

                    next_bridge_seq = next_bridge_seq.saturating_add(1);
                    self.projections()
                        .set_latest_bridge_seq(&thread_id, next_bridge_seq)
                        .await;
                    self.event_hub()
                        .publish(raw.event.with_bridge_seq(Some(next_bridge_seq)));

                    if let Some(ack) = ack {
                        let _ = ack.send(());
                    }
                }
                ThreadReducerCommand::MergeSnapshot {
                    source,
                    snapshot,
                    events,
                    ack,
                } => {
                    let latest_bridge_seq = self.projections().latest_bridge_seq(&thread_id).await;
                    self.projections()
                        .merge_snapshot_repair(&snapshot, latest_bridge_seq)
                        .await;

                    for event in events {
                        let raw = build_raw_thread_event(source, event);
                        self.apply_reducer_side_effects(&raw.event).await;
                        self.advance_outgoing_turn_state(&raw).await;

                        next_bridge_seq = next_bridge_seq.saturating_add(1);
                        self.projections()
                            .set_latest_bridge_seq(&thread_id, next_bridge_seq)
                            .await;
                        self.event_hub()
                            .publish(raw.event.with_bridge_seq(Some(next_bridge_seq)));
                    }

                    if let Some(ack) = ack {
                        let _ = ack.send(());
                    }
                }
            }
        }
    }

    async fn apply_reducer_side_effects(&self, event: &BridgeEventEnvelope<Value>) {
        if should_clear_transient_thread_state(event) {
            self.clear_transient_thread_state(&event.thread_id).await;
        }
    }

    async fn advance_outgoing_turn_state(&self, raw: &RawThreadEvent) {
        match raw.phase {
            RawThreadEventPhase::Delta | RawThreadEventPhase::Completed => {
                if raw.event.kind == BridgeEventKind::MessageDelta
                    && raw.event.payload.get("role").and_then(Value::as_str) == Some("user")
                {
                    self.mark_outgoing_turn_phase(
                        &raw.thread_id,
                        OutgoingTurnPhase::UserItemSeen,
                        raw.turn_id.clone(),
                        None,
                    )
                    .await;
                    return;
                }

                let assistant_signal = matches!(
                    raw.event.kind,
                    BridgeEventKind::PlanDelta
                        | BridgeEventKind::CommandDelta
                        | BridgeEventKind::FileChange
                ) || (raw.event.kind == BridgeEventKind::MessageDelta
                    && raw.event.payload.get("role").and_then(Value::as_str) == Some("assistant"));
                if assistant_signal {
                    self.mark_outgoing_turn_phase(
                        &raw.thread_id,
                        OutgoingTurnPhase::FirstAssistantSignal,
                        raw.turn_id.clone(),
                        None,
                    )
                    .await;
                }
            }
            RawThreadEventPhase::Status => {
                let status = raw
                    .event
                    .payload
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if matches!(status, "completed" | "failed" | "interrupted") {
                    let phase = if status == "failed" {
                        OutgoingTurnPhase::Failed
                    } else {
                        OutgoingTurnPhase::Completed
                    };
                    self.mark_outgoing_turn_phase(&raw.thread_id, phase, raw.turn_id.clone(), None)
                        .await;
                    if phase != OutgoingTurnPhase::Failed {
                        self.clear_outgoing_turn_phase(&raw.thread_id).await;
                    }
                }
            }
            _ => {}
        }
    }
}

pub(super) fn build_raw_thread_event(
    source: RawThreadEventSource,
    event: BridgeEventEnvelope<Value>,
) -> RawThreadEvent {
    RawThreadEvent {
        source,
        thread_id: event.thread_id.clone(),
        turn_id: event
            .payload
            .get("turn_id")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        item_id: event
            .payload
            .get("id")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        phase: infer_raw_thread_event_phase(source, &event),
        event,
    }
}

pub(super) fn infer_raw_thread_event_phase(
    source: RawThreadEventSource,
    event: &BridgeEventEnvelope<Value>,
) -> RawThreadEventPhase {
    match event.kind {
        BridgeEventKind::ThreadStatusChanged => RawThreadEventPhase::Status,
        BridgeEventKind::UserInputRequested => RawThreadEventPhase::UserInput,
        BridgeEventKind::ApprovalRequested => RawThreadEventPhase::Approval,
        BridgeEventKind::SecurityAudit => RawThreadEventPhase::Metadata,
        BridgeEventKind::MessageDelta
        | BridgeEventKind::PlanDelta
        | BridgeEventKind::CommandDelta
        | BridgeEventKind::FileChange => match source {
            RawThreadEventSource::DesktopIpc
            | RawThreadEventSource::SnapshotRepair
            | RawThreadEventSource::ArchiveRepair => RawThreadEventPhase::Repair,
            _ => {
                if event
                    .payload
                    .get("delta")
                    .and_then(Value::as_str)
                    .is_some_and(|delta| !delta.is_empty())
                {
                    RawThreadEventPhase::Delta
                } else {
                    RawThreadEventPhase::Completed
                }
            }
        },
    }
}
