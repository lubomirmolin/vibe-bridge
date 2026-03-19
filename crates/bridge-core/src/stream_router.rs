use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};

use serde_json::Value;
use shared_contracts::BridgeEventEnvelope;

#[derive(Debug, Default)]
pub struct StreamRouter {
    next_subscription_id: AtomicU64,
    subscribers: Mutex<HashMap<u64, Subscriber>>,
}

#[derive(Debug)]
struct Subscriber {
    thread_ids: HashSet<String>,
    sender: Sender<BridgeEventEnvelope<Value>>,
}

#[derive(Debug)]
pub struct StreamSubscription {
    pub id: u64,
    pub receiver: Receiver<BridgeEventEnvelope<Value>>,
}

impl StreamRouter {
    pub fn new() -> Self {
        Self {
            next_subscription_id: AtomicU64::new(1),
            subscribers: Mutex::new(HashMap::new()),
        }
    }

    pub fn subscribe(&self, thread_ids: Vec<String>) -> StreamSubscription {
        let id = self.next_subscription_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = mpsc::channel();

        self.subscribers
            .lock()
            .expect("stream router mutex should not be poisoned")
            .insert(
                id,
                Subscriber {
                    thread_ids: normalize_thread_ids(thread_ids),
                    sender,
                },
            );

        StreamSubscription { id, receiver }
    }

    pub fn update_subscription(&self, id: u64, thread_ids: Vec<String>) -> bool {
        let mut subscribers = self
            .subscribers
            .lock()
            .expect("stream router mutex should not be poisoned");
        let Some(subscriber) = subscribers.get_mut(&id) else {
            return false;
        };

        subscriber.thread_ids = normalize_thread_ids(thread_ids);
        true
    }

    pub fn unsubscribe(&self, id: u64) {
        self.subscribers
            .lock()
            .expect("stream router mutex should not be poisoned")
            .remove(&id);
    }

    pub fn subscriber_count(&self) -> usize {
        self.subscribers
            .lock()
            .expect("stream router mutex should not be poisoned")
            .len()
    }

    pub fn publish(&self, event: BridgeEventEnvelope<Value>) {
        let mut stale_subscribers = Vec::new();

        {
            let subscribers = self
                .subscribers
                .lock()
                .expect("stream router mutex should not be poisoned");

            for (id, subscriber) in subscribers.iter() {
                if !subscriber.thread_ids.contains(&event.thread_id) {
                    continue;
                }

                if subscriber.sender.send(event.clone()).is_err() {
                    stale_subscribers.push(*id);
                }
            }
        }

        if stale_subscribers.is_empty() {
            return;
        }

        let mut subscribers = self
            .subscribers
            .lock()
            .expect("stream router mutex should not be poisoned");
        for id in stale_subscribers {
            subscribers.remove(&id);
        }
    }
}

fn normalize_thread_ids(thread_ids: Vec<String>) -> HashSet<String> {
    thread_ids
        .into_iter()
        .map(|thread_id| thread_id.trim().to_string())
        .filter(|thread_id| !thread_id.is_empty())
        .collect::<HashSet<_>>()
}

#[cfg(test)]
mod tests {
    use super::StreamRouter;
    use serde_json::json;
    use shared_contracts::{BridgeEventEnvelope, BridgeEventKind};
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Duration;

    #[test]
    fn publish_only_reaches_matching_thread_subscribers() {
        let router = StreamRouter::new();
        let thread_123_subscription = router.subscribe(vec!["thread-123".to_string()]);
        let thread_456_subscription = router.subscribe(vec!["thread-456".to_string()]);

        router.publish(BridgeEventEnvelope::new(
            "evt-1",
            "thread-123",
            BridgeEventKind::MessageDelta,
            "2026-03-17T21:55:00Z",
            json!({"delta": "hello"}),
        ));

        let event = thread_123_subscription
            .receiver
            .recv_timeout(Duration::from_millis(50))
            .expect("matching subscription should receive events");
        assert_eq!(event.thread_id, "thread-123");

        let err = thread_456_subscription
            .receiver
            .recv_timeout(Duration::from_millis(50))
            .expect_err("non-matching subscription should not receive events");
        assert!(matches!(err, RecvTimeoutError::Timeout));
    }

    #[test]
    fn update_subscription_retargets_thread_filter() {
        let router = StreamRouter::new();
        let subscription = router.subscribe(vec!["thread-123".to_string()]);

        assert!(router.update_subscription(subscription.id, vec!["thread-456".to_string()]));

        router.publish(BridgeEventEnvelope::new(
            "evt-1",
            "thread-123",
            BridgeEventKind::MessageDelta,
            "2026-03-17T21:55:00Z",
            json!({"delta": "ignored"}),
        ));
        router.publish(BridgeEventEnvelope::new(
            "evt-2",
            "thread-456",
            BridgeEventKind::MessageDelta,
            "2026-03-17T21:56:00Z",
            json!({"delta": "delivered"}),
        ));

        let event = subscription
            .receiver
            .recv_timeout(Duration::from_millis(50))
            .expect("retargeted subscription should receive new thread events");
        assert_eq!(event.thread_id, "thread-456");
    }
}
