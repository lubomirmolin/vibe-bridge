use super::super::super::*;

pub(crate) fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    crate::server::timeline_events::summarize_live_payload(kind, payload)
}

pub(crate) fn timeline_annotations_for_event(
    event_id: &str,
    kind: BridgeEventKind,
    payload: &Value,
) -> Option<ThreadTimelineAnnotationsDto> {
    crate::server::timeline_events::timeline_annotations_for_event(event_id, kind, payload)
}

pub(super) fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}
