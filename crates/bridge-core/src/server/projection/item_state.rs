use std::collections::HashMap;

use serde_json::Value;
use shared_contracts::{
    BridgeEventEnvelope, BridgeEventKind, ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto,
};

use crate::incremental_text::merge_incremental_text;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProjectionItemPhase {
    Delta,
    Final,
    Repair,
}

#[derive(Debug, Clone)]
pub(crate) struct ThreadItemProjectionState {
    pub(crate) kind: BridgeEventKind,
    pub(crate) occurred_at: String,
    pub(crate) annotations: Option<ThreadTimelineAnnotationsDto>,
    pub(crate) live_buffer: Option<Value>,
    pub(crate) final_item: Option<Value>,
    pub(crate) repair_snapshot: Option<Value>,
    pub(crate) is_active: bool,
}

impl ThreadItemProjectionState {
    #[allow(dead_code)]
    pub(crate) fn seed_from_entry(entry: &ThreadTimelineEntryDto) -> Self {
        Self {
            kind: entry.kind,
            occurred_at: entry.occurred_at.clone(),
            annotations: entry.annotations.clone(),
            live_buffer: None,
            final_item: None,
            repair_snapshot: Some(entry.payload.clone()),
            is_active: false,
        }
    }

    pub(crate) fn apply_event(
        existing: Option<&Self>,
        event: &BridgeEventEnvelope<Value>,
        phase: ProjectionItemPhase,
    ) -> Self {
        let mut next = existing.cloned().unwrap_or(Self {
            kind: event.kind,
            occurred_at: event.occurred_at.clone(),
            annotations: event.annotations.clone(),
            live_buffer: None,
            final_item: None,
            repair_snapshot: None,
            is_active: false,
        });
        next.kind = event.kind;
        next.occurred_at = event.occurred_at.clone();
        next.annotations = event.annotations.clone().or(next.annotations);

        match phase {
            ProjectionItemPhase::Delta => {
                next.live_buffer = Some(merge_live_payload(
                    next.live_buffer
                        .as_ref()
                        .or(next.final_item.as_ref())
                        .or(next.repair_snapshot.as_ref()),
                    event.kind,
                    &event.payload,
                ));
                next.is_active = true;
            }
            ProjectionItemPhase::Final => {
                next.final_item = Some(merge_live_payload(
                    next.final_item
                        .as_ref()
                        .or(next.live_buffer.as_ref())
                        .or(next.repair_snapshot.as_ref()),
                    event.kind,
                    &event.payload,
                ));
                next.is_active = false;
            }
            ProjectionItemPhase::Repair => {
                next.repair_snapshot = Some(merge_repair_payload(
                    next.repair_snapshot.as_ref(),
                    event.kind,
                    next.primary_payload(),
                    &event.payload,
                ));
            }
        }

        next
    }

    pub(crate) fn materialize_entry(&self, event_id: &str) -> ThreadTimelineEntryDto {
        let payload = self.materialized_payload();
        ThreadTimelineEntryDto {
            event_id: event_id.to_string(),
            kind: self.kind,
            occurred_at: self.occurred_at.clone(),
            summary: summarize_payload(self.kind, &payload),
            payload,
            annotations: self.annotations.clone(),
        }
    }

    fn materialized_payload(&self) -> Value {
        let Some(primary) = self.primary_payload() else {
            return Value::Null;
        };
        let Some(repair) = self.repair_snapshot.as_ref() else {
            return primary.clone();
        };
        if std::ptr::eq(primary, repair) {
            return repair.clone();
        }
        merge_primary_with_repair(self.kind, primary, repair)
    }

    fn primary_payload(&self) -> Option<&Value> {
        self.final_item
            .as_ref()
            .or(self.live_buffer.as_ref())
            .or(self.repair_snapshot.as_ref())
    }
}

pub(crate) fn is_incremental_item_kind(kind: BridgeEventKind) -> bool {
    matches!(
        kind,
        BridgeEventKind::MessageDelta
            | BridgeEventKind::PlanDelta
            | BridgeEventKind::CommandDelta
            | BridgeEventKind::FileChange
    )
}

pub(crate) fn infer_item_phase(event: &BridgeEventEnvelope<Value>) -> ProjectionItemPhase {
    if event
        .payload
        .get("delta")
        .and_then(Value::as_str)
        .is_some_and(|delta| !delta.is_empty())
        || event.payload.get("replace").is_some()
    {
        ProjectionItemPhase::Delta
    } else {
        ProjectionItemPhase::Final
    }
}

pub(crate) fn materialize_entries(
    items: &HashMap<String, ThreadItemProjectionState>,
) -> Vec<ThreadTimelineEntryDto> {
    let mut entries = items
        .iter()
        .map(|(event_id, state)| state.materialize_entry(event_id))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        left.occurred_at
            .cmp(&right.occurred_at)
            .then_with(|| left.event_id.cmp(&right.event_id))
    });
    entries
}

fn merge_primary_with_repair(kind: BridgeEventKind, primary: &Value, repair: &Value) -> Value {
    let protected_keys = protected_text_keys(kind);
    match (primary, repair) {
        (Value::Object(primary_object), Value::Object(repair_object)) => {
            let mut merged = repair_object.clone();
            for (key, value) in primary_object {
                if protected_keys.contains(&key.as_str()) && value_is_non_empty_text(value) {
                    merged.insert(key.clone(), value.clone());
                    continue;
                }
                merged.insert(key.clone(), value.clone());
            }
            Value::Object(merged)
        }
        _ => primary.clone(),
    }
}

fn merge_repair_payload(
    existing_repair: Option<&Value>,
    kind: BridgeEventKind,
    primary: Option<&Value>,
    incoming: &Value,
) -> Value {
    let base = existing_repair.unwrap_or(incoming);
    let merged = match (base, incoming) {
        (Value::Object(base_object), Value::Object(incoming_object)) => {
            let mut next = base_object.clone();
            for (key, value) in incoming_object {
                next.insert(key.clone(), value.clone());
            }
            Value::Object(next)
        }
        _ => incoming.clone(),
    };

    match primary {
        Some(primary) => merge_primary_with_repair(kind, primary, &merged),
        None => merged,
    }
}

fn protected_text_keys(kind: BridgeEventKind) -> &'static [&'static str] {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => &["text"],
        BridgeEventKind::CommandDelta => &["output", "aggregatedOutput"],
        BridgeEventKind::FileChange => &["resolved_unified_diff", "output"],
        _ => &[],
    }
}

fn value_is_non_empty_text(value: &Value) -> bool {
    value.as_str().is_some_and(|text| !text.trim().is_empty())
}

fn summarize_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::UserInputRequested => payload
            .get("title")
            .or_else(|| payload.get("detail"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::CommandDelta => payload
            .get("output")
            .or_else(|| payload.get("aggregatedOutput"))
            .or_else(|| payload.get("command"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::FileChange => payload
            .get("resolved_unified_diff")
            .or_else(|| payload.get("output"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| {
                payload
                    .get("path")
                    .or_else(|| payload.get("file"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
            })
            .to_string(),
        BridgeEventKind::ThreadStatusChanged => payload
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::ApprovalRequested => payload
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::SecurityAudit => payload
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}

fn merge_live_payload(existing: Option<&Value>, kind: BridgeEventKind, incoming: &Value) -> Value {
    match kind {
        BridgeEventKind::MessageDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_text = existing
                .and_then(|payload| payload.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_text = merge_incremental_text(
                existing_text,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );
            let mut payload = serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "message",
                "role": incoming.get("role").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("role")).and_then(Value::as_str)).unwrap_or("assistant"),
                "text": next_text,
            });
            if let Some(images) = incoming
                .get("images")
                .cloned()
                .or_else(|| existing.and_then(|payload| payload.get("images")).cloned())
                && let Some(object) = payload.as_object_mut()
            {
                object.insert("images".to_string(), images);
            }
            payload
        }
        BridgeEventKind::PlanDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_text = existing
                .and_then(|payload| payload.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_text = merge_incremental_text(
                existing_text,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            let mut payload = serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "plan",
                "text": next_text,
            });
            if let Some(object) = payload.as_object_mut() {
                if let Some(explanation) = incoming
                    .get("explanation")
                    .or_else(|| existing.and_then(|payload| payload.get("explanation")))
                {
                    object.insert("explanation".to_string(), explanation.clone());
                }
                if let Some(steps) = incoming
                    .get("steps")
                    .or_else(|| existing.and_then(|payload| payload.get("steps")))
                {
                    object.insert("steps".to_string(), steps.clone());
                }
                if let Some(completed_count) = incoming
                    .get("completed_count")
                    .or_else(|| existing.and_then(|payload| payload.get("completed_count")))
                {
                    object.insert("completed_count".to_string(), completed_count.clone());
                }
                if let Some(total_count) = incoming
                    .get("total_count")
                    .or_else(|| existing.and_then(|payload| payload.get("total_count")))
                {
                    object.insert("total_count".to_string(), total_count.clone());
                }
            }

            payload
        }
        BridgeEventKind::CommandDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_output = existing
                .and_then(|payload| payload.get("output"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_output = merge_incremental_text(
                existing_output,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "command",
                "command": incoming.get("command").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("command")).and_then(Value::as_str)).unwrap_or_default(),
                "cmd": incoming.get("cmd").cloned().or_else(|| existing.and_then(|payload| payload.get("cmd")).cloned()),
                "workdir": incoming.get("workdir").cloned().or_else(|| incoming.get("cwd").cloned()).or_else(|| existing.and_then(|payload| payload.get("workdir")).cloned()),
                "output": next_output,
                "aggregatedOutput": next_output,
            })
        }
        BridgeEventKind::FileChange => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_diff = existing
                .and_then(|payload| payload.get("resolved_unified_diff"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_diff = merge_incremental_text(
                existing_diff,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("resolved_unified_diff"))
                    .or_else(|| incoming.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "file_change",
                "path": incoming.get("path").and_then(Value::as_str).or_else(|| incoming.get("file").and_then(Value::as_str)).or_else(|| existing.and_then(|payload| payload.get("path")).and_then(Value::as_str)).unwrap_or_default(),
                "resolved_unified_diff": next_diff,
            })
        }
        _ => incoming.clone(),
    }
}
