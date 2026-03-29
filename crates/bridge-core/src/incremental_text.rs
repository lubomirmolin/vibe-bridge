use std::collections::HashMap;

pub(crate) fn merge_incremental_text(existing: &str, incoming: &str, replace: bool) -> String {
    if replace || existing.is_empty() {
        return incoming.to_string();
    }
    if incoming.is_empty() {
        return existing.to_string();
    }
    if incoming == existing || existing.starts_with(incoming) {
        return existing.to_string();
    }
    if incoming.starts_with(existing) {
        return incoming.to_string();
    }

    let overlap = longest_suffix_prefix_overlap(existing, incoming);
    if overlap < 2 {
        format!("{existing}{incoming}")
    } else {
        format!("{existing}{}", &incoming[overlap..])
    }
}

pub(crate) fn compact_incremental_full_text(
    cache: &mut HashMap<String, String>,
    event_id: &str,
    current_value: &str,
) -> (String, bool) {
    match cache.get(event_id) {
        None => {
            cache.insert(event_id.to_string(), current_value.to_string());
            (current_value.to_string(), true)
        }
        Some(previous_value) if current_value == previous_value => (String::new(), false),
        Some(previous_value) if current_value.starts_with(previous_value) => {
            let delta = current_value[previous_value.len()..].to_string();
            cache.insert(event_id.to_string(), current_value.to_string());
            (delta, false)
        }
        Some(previous_value) if previous_value.starts_with(current_value) => (String::new(), false),
        Some(_) => {
            cache.insert(event_id.to_string(), current_value.to_string());
            (current_value.to_string(), true)
        }
    }
}

fn longest_suffix_prefix_overlap(existing: &str, incoming: &str) -> usize {
    let max_overlap = existing.len().min(incoming.len());
    for overlap in (1..=max_overlap).rev() {
        let existing_start = existing.len() - overlap;
        if !existing.is_char_boundary(existing_start) || !incoming.is_char_boundary(overlap) {
            continue;
        }
        if existing[existing_start..] == incoming[..overlap] {
            return overlap;
        }
    }

    0
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{compact_incremental_full_text, merge_incremental_text};

    #[test]
    fn merge_incremental_text_handles_cumulative_and_overlapping_chunks() {
        assert_eq!(
            merge_incremental_text("I'm", "I'm checking", false),
            "I'm checking"
        );
        assert_eq!(
            merge_incremental_text("Hello, wor", "world", false),
            "Hello, world"
        );
        assert_eq!(merge_incremental_text("Hel", "lo", false), "Hello");
        assert_eq!(merge_incremental_text("Hello", "Hello", false), "Hello");
        assert_eq!(merge_incremental_text("Hello", "Hel", false), "Hello");
    }

    #[test]
    fn compact_incremental_full_text_ignores_exact_and_shorter_repeats() {
        let mut cache = HashMap::new();

        assert_eq!(
            compact_incremental_full_text(&mut cache, "evt-1", "Hello"),
            ("Hello".to_string(), true)
        );
        assert_eq!(
            compact_incremental_full_text(&mut cache, "evt-1", "Hello"),
            (String::new(), false)
        );
        assert_eq!(
            compact_incremental_full_text(&mut cache, "evt-1", "Hello world"),
            (" world".to_string(), false)
        );
        assert_eq!(
            compact_incremental_full_text(&mut cache, "evt-1", "Hello"),
            (String::new(), false)
        );
    }
}
