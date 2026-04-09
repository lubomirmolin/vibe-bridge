use axum::extract::ws::{Message, WebSocket};
use serde::Deserialize;
use serde_json::Value;
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION};
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
    use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION};

    use super::{EventSubscriptionQuery, EventSubscriptionScope, compact_list_event};

    #[test]
    fn defaults_to_list_scope() {
        let query = EventSubscriptionQuery {
            scope: None,
            thread_id: None,
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
            bridge_seq: None,
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
            bridge_seq: None,
        };

        assert!(super::filter_event_for_scope(event, &EventSubscriptionScope::List).is_none());
    }
}
