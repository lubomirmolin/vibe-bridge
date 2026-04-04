use axum::extract::ws::{Message, WebSocket};
use serde::Deserialize;
use serde_json::Value;
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadSnapshotDto};
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub struct EventHub {
    sender: broadcast::Sender<BridgeEventEnvelope<Value>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EventSubscriptionQuery {
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub thread_id: Option<String>,
    #[serde(default)]
    pub after_event_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventSubscriptionScope {
    List,
    Thread(String),
}

impl EventHub {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self { sender }
    }

    pub fn publish(&self, event: BridgeEventEnvelope<Value>) {
        let _ = self.sender.send(event);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<BridgeEventEnvelope<Value>> {
        self.sender.subscribe()
    }
}

impl EventSubscriptionQuery {
    pub fn into_scope(self) -> EventSubscriptionScope {
        match self.scope.as_deref() {
            Some("thread") => self
                .thread_id
                .filter(|thread_id| !thread_id.trim().is_empty())
                .map(EventSubscriptionScope::Thread)
                .unwrap_or(EventSubscriptionScope::List),
            Some("list") => EventSubscriptionScope::List,
            _ => self
                .thread_id
                .filter(|thread_id| !thread_id.trim().is_empty())
                .map(EventSubscriptionScope::Thread)
                .unwrap_or(EventSubscriptionScope::List),
        }
    }
}

pub async fn stream_events(
    mut socket: WebSocket,
    mut receiver: broadcast::Receiver<BridgeEventEnvelope<Value>>,
    scope: EventSubscriptionScope,
    replay_events: Vec<BridgeEventEnvelope<Value>>,
) {
    let subscribed = serde_json::json!({
        "event": "subscribed",
        "contract_version": CONTRACT_VERSION,
        "scope": match &scope {
            EventSubscriptionScope::List => "list",
            EventSubscriptionScope::Thread(thread_id) => thread_id,
        },
    });

    if socket
        .send(Message::Text(subscribed.to_string()))
        .await
        .is_err()
    {
        return;
    }

    for event in replay_events {
        let Some(filtered) = filter_event_for_scope(event, &scope) else {
            continue;
        };
        let Ok(frame) = serde_json::to_string(&filtered) else {
            continue;
        };
        if socket.send(Message::Text(frame)).await.is_err() {
            return;
        }
    }

    loop {
        let event = match receiver.recv().await {
            Ok(event) => event,
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(broadcast::error::RecvError::Closed) => break,
        };
        let Some(filtered) = filter_event_for_scope(event, &scope) else {
            continue;
        };
        let Ok(frame) = serde_json::to_string(&filtered) else {
            continue;
        };
        if socket.send(Message::Text(frame)).await.is_err() {
            break;
        }
    }
}

pub fn replay_events_for_scope(
    snapshot: Option<&ThreadSnapshotDto>,
    scope: &EventSubscriptionScope,
    after_event_id: Option<&str>,
) -> Vec<BridgeEventEnvelope<Value>> {
    let Some(after_event_id) = after_event_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Vec::new();
    };

    let EventSubscriptionScope::Thread(thread_id) = scope else {
        return Vec::new();
    };

    let Some(snapshot) = snapshot.filter(|snapshot| snapshot.thread.thread_id == *thread_id) else {
        return Vec::new();
    };

    let Some(start_index) = snapshot
        .entries
        .iter()
        .position(|entry| entry.event_id == after_event_id)
        .map(|index| index + 1)
    else {
        return Vec::new();
    };

    snapshot.entries[start_index..]
        .iter()
        .map(|entry| BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: entry.event_id.clone(),
            thread_id: snapshot.thread.thread_id.clone(),
            kind: entry.kind,
            occurred_at: entry.occurred_at.clone(),
            payload: entry.payload.clone(),
            annotations: entry.annotations.clone(),
        })
        .collect()
}

fn filter_event_for_scope(
    event: BridgeEventEnvelope<Value>,
    scope: &EventSubscriptionScope,
) -> Option<BridgeEventEnvelope<Value>> {
    match scope {
        EventSubscriptionScope::Thread(thread_id) => {
            (event.thread_id == *thread_id).then_some(event)
        }
        EventSubscriptionScope::List => {
            (event.kind == BridgeEventKind::ThreadStatusChanged).then(|| compact_list_event(event))
        }
    }
}

fn compact_list_event(mut event: BridgeEventEnvelope<Value>) -> BridgeEventEnvelope<Value> {
    event.payload = match event.kind {
        BridgeEventKind::ThreadStatusChanged => event.payload,
        _ => serde_json::json!({}),
    };
    event
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use shared_contracts::{
        BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadClientKind, ThreadSnapshotDto,
    };

    use super::{
        EventSubscriptionQuery, EventSubscriptionScope, compact_list_event, replay_events_for_scope,
    };

    #[test]
    fn defaults_to_list_scope() {
        let query = EventSubscriptionQuery {
            scope: None,
            thread_id: None,
            after_event_id: None,
        };
        assert_eq!(query.into_scope(), EventSubscriptionScope::List);
    }

    #[test]
    fn preserves_status_payload_for_list_scope() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-1".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-21T12:00:00Z".to_string(),
            payload: json!({"status":"running"}),
            annotations: None,
        };

        let compacted = compact_list_event(event);
        assert_eq!(compacted.payload["status"], "running");
    }

    #[test]
    fn drops_non_status_events_for_list_scope() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-2".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T12:00:00Z".to_string(),
            payload: json!({"delta":"hello"}),
            annotations: None,
        };

        assert!(super::filter_event_for_scope(event, &EventSubscriptionScope::List).is_none());
    }

    #[test]
    fn thread_scope_replay_returns_events_after_cursor() {
        let snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: shared_contracts::ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                title: "Replay".to_string(),
                status: shared_contracts::ThreadStatus::Running,
                workspace: "/workspace".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-21T12:00:00Z".to_string(),
                updated_at: "2026-03-21T12:00:02Z".to_string(),
                source: "cli".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "second".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                active_turn_id: None,
            },
            entries: vec![
                shared_contracts::ThreadTimelineEntryDto {
                    event_id: "evt-1".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T12:00:00Z".to_string(),
                    summary: "first".to_string(),
                    payload: json!({"text":"first"}),
                    annotations: None,
                },
                shared_contracts::ThreadTimelineEntryDto {
                    event_id: "evt-2".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T12:00:01Z".to_string(),
                    summary: "second".to_string(),
                    payload: json!({"text":"second"}),
                    annotations: None,
                },
            ],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        let replayed = replay_events_for_scope(
            Some(&snapshot),
            &EventSubscriptionScope::Thread("thread-1".to_string()),
            Some("evt-1"),
        );

        assert_eq!(replayed.len(), 1);
        assert_eq!(replayed[0].event_id, "evt-2");
    }
}
