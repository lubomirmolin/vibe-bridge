use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::{BridgeApplication, thread_api::CodexNotificationStream};

pub(crate) fn reconcile_upstream_loop(app: Arc<BridgeApplication>) {
    const ACTIVE_POLL_INTERVAL: Duration = Duration::from_millis(750);
    const IDLE_POLL_INTERVAL: Duration = Duration::from_millis(1500);

    loop {
        if app.subscriber_count() == 0 {
            thread::sleep(IDLE_POLL_INTERVAL);
            continue;
        }

        match app.reconcile_upstream_activity() {
            Ok(events) => {
                for event in events {
                    app.publish_stream_event(event);
                }
            }
            Err(error) => {
                eprintln!("failed to reconcile upstream thread activity: {error}");
            }
        }

        thread::sleep(ACTIVE_POLL_INTERVAL);
    }
}

pub(crate) fn forward_upstream_notifications_loop(
    app: Arc<BridgeApplication>,
    command: String,
    args: Vec<String>,
    endpoint: Option<String>,
) {
    const RESTART_DELAY: Duration = Duration::from_secs(1);

    loop {
        match CodexNotificationStream::start(&command, &args, endpoint.as_deref()) {
            Ok(mut notifications) => loop {
                match notifications.next_event() {
                    Ok(Some(event)) => app.apply_live_upstream_event(event),
                    Ok(None) => {
                        eprintln!("codex notification stream closed; restarting");
                        break;
                    }
                    Err(error) => {
                        eprintln!("failed to read codex notification stream: {error}");
                        break;
                    }
                }
            },
            Err(error) => {
                eprintln!("failed to connect codex notification stream: {error}");
            }
        }

        thread::sleep(RESTART_DELAY);
    }
}
