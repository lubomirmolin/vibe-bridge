mod annotations;
mod hidden;
mod normalize;

use serde_json::Value;
use shared_contracts::BridgeEventKind;

pub(crate) use annotations::{summarize_live_payload, timeline_annotations_for_event};
pub(crate) use hidden::payload_contains_hidden_message;
pub(crate) use normalize::normalize_codex_item_payload;
pub(crate) fn should_publish_live_payload(kind: BridgeEventKind, payload: &Value) -> bool {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => {
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(payload) {
                return false;
            }
            payload
                .get("text")
                .or_else(|| payload.get("delta"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("content")
                    .and_then(Value::as_array)
                    .is_some_and(|content| !content.is_empty())
        }
        BridgeEventKind::CommandDelta => {
            payload
                .get("output")
                .or_else(|| payload.get("aggregatedOutput"))
                .or_else(|| payload.get("command"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload.get("arguments").is_some()
        }
        BridgeEventKind::FileChange => {
            payload
                .get("resolved_unified_diff")
                .or_else(|| payload.get("output"))
                .or_else(|| payload.get("change"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("changes")
                    .and_then(Value::as_array)
                    .is_some_and(|changes| !changes.is_empty())
        }
        _ => true,
    }
}
