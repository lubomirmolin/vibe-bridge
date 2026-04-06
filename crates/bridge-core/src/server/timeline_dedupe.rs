use chrono::DateTime;
use serde_json::Value;
use shared_contracts::ThreadTimelineEntryDto;

const ARCHIVE_DUPLICATE_WINDOW_MILLIS: i64 = 3_000;

#[derive(Debug, Clone)]
struct UserEntryFingerprint {
    event_id: String,
    occurred_at: String,
    occurred_at_millis: Option<i64>,
    normalized_text: String,
    client_message_id: Option<String>,
}

pub(crate) fn dedupe_visible_user_prompt_representations(
    entries: &mut Vec<ThreadTimelineEntryDto>,
) {
    let canonical_user_entries = entries
        .iter()
        .filter(|entry| timeline_entry_is_user_message(entry) && !is_replaceable_user_prompt(entry))
        .map(user_entry_fingerprint)
        .collect::<Vec<_>>();
    if canonical_user_entries.is_empty() {
        return;
    }

    entries.retain(|entry| {
        if !is_replaceable_user_prompt(entry) {
            return true;
        }

        let duplicate = user_entry_fingerprint(entry);
        !canonical_user_entries
            .iter()
            .any(|canonical| user_prompt_entries_match(entry, &duplicate, canonical))
    });
}

fn user_prompt_entries_match(
    duplicate_entry: &ThreadTimelineEntryDto,
    duplicate: &UserEntryFingerprint,
    canonical: &UserEntryFingerprint,
) -> bool {
    has_matching_client_message_id(duplicate, canonical)
        || synthetic_visible_prompt_matches_turn_user_prompt(duplicate_entry, duplicate, canonical)
        || archive_prompt_matches_canonical_prompt(duplicate_entry, duplicate, canonical)
}

fn has_matching_client_message_id(
    duplicate: &UserEntryFingerprint,
    canonical: &UserEntryFingerprint,
) -> bool {
    duplicate
        .client_message_id
        .as_deref()
        .zip(canonical.client_message_id.as_deref())
        .is_some_and(|(left, right)| left == right)
}

fn synthetic_visible_prompt_matches_turn_user_prompt(
    duplicate_entry: &ThreadTimelineEntryDto,
    duplicate: &UserEntryFingerprint,
    canonical: &UserEntryFingerprint,
) -> bool {
    let Some(turn_id) = duplicate_entry
        .event_id
        .strip_suffix("-visible-user-prompt")
    else {
        return false;
    };
    !duplicate.normalized_text.is_empty()
        && duplicate.normalized_text == canonical.normalized_text
        && event_belongs_to_turn(&canonical.event_id, turn_id)
}

fn archive_prompt_matches_canonical_prompt(
    duplicate_entry: &ThreadTimelineEntryDto,
    duplicate: &UserEntryFingerprint,
    canonical: &UserEntryFingerprint,
) -> bool {
    if !is_archive_user_prompt(duplicate_entry) {
        return false;
    }

    !duplicate.normalized_text.is_empty()
        && duplicate.normalized_text == canonical.normalized_text
        && timestamps_are_nearby(duplicate, canonical)
}

fn timestamps_are_nearby(left: &UserEntryFingerprint, right: &UserEntryFingerprint) -> bool {
    match (left.occurred_at_millis, right.occurred_at_millis) {
        (Some(left), Some(right)) => (left - right).abs() <= ARCHIVE_DUPLICATE_WINDOW_MILLIS,
        _ => left.occurred_at == right.occurred_at,
    }
}

fn user_entry_fingerprint(entry: &ThreadTimelineEntryDto) -> UserEntryFingerprint {
    UserEntryFingerprint {
        event_id: entry.event_id.clone(),
        occurred_at: entry.occurred_at.clone(),
        occurred_at_millis: parse_rfc3339_millis(&entry.occurred_at),
        normalized_text: normalize_timeline_text(
            timeline_entry_primary_text(entry).unwrap_or_default(),
        ),
        client_message_id: timeline_entry_client_message_id(entry).map(str::to_string),
    }
}

fn parse_rfc3339_millis(value: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|timestamp| timestamp.timestamp_millis())
}

fn is_replaceable_user_prompt(entry: &ThreadTimelineEntryDto) -> bool {
    is_synthetic_visible_user_prompt(entry) || is_archive_user_prompt(entry)
}

fn is_archive_user_prompt(entry: &ThreadTimelineEntryDto) -> bool {
    entry.event_id.contains("-archive-")
        && entry.payload.get("type").and_then(Value::as_str) == Some("userMessage")
        && timeline_entry_is_user_message(entry)
}

fn is_synthetic_visible_user_prompt(entry: &ThreadTimelineEntryDto) -> bool {
    entry.event_id.ends_with("-visible-user-prompt") && timeline_entry_is_user_message(entry)
}

fn timeline_entry_is_user_message(entry: &ThreadTimelineEntryDto) -> bool {
    entry.payload.get("role").and_then(Value::as_str) == Some("user")
        || entry.payload.get("type").and_then(Value::as_str) == Some("userMessage")
}

fn timeline_entry_client_message_id(entry: &ThreadTimelineEntryDto) -> Option<&str> {
    entry
        .payload
        .get("client_message_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn timeline_entry_primary_text(entry: &ThreadTimelineEntryDto) -> Option<&str> {
    entry
        .payload
        .get("text")
        .and_then(Value::as_str)
        .or_else(|| entry.payload.get("delta").and_then(Value::as_str))
        .or_else(|| {
            entry
                .payload
                .get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .find(|text| !text.trim().is_empty())
        })
}

fn normalize_timeline_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn event_belongs_to_turn(event_id: &str, turn_id: &str) -> bool {
    event_id == turn_id
        || event_id
            .strip_prefix(turn_id)
            .is_some_and(|suffix| suffix.starts_with('-'))
}
