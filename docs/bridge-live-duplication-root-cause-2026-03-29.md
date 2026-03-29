# Bridge Live Duplication Root Cause

Date: March 29, 2026

## Summary

The repeated assistant text is a bridge-side bug, not a Flutter rendering bug.

The primary root cause is that the bridge normalizer treats all `item/*/delta` payloads as pure suffix deltas and blindly appends them onto the cached item text. That assumption is not always valid for the live shapes the bridge is handling.

In practice, the bridge can already have partial assistant text cached from an earlier item snapshot, then receive a later delta payload that is cumulative or overlaps the cached prefix. The bridge currently appends that full string again and manufactures duplicated output such as:

- `"I'm"` + `"I'm checking"` -> `"I'mI'm checking"`
- `"I’m checking"` + `"I’m checking where"` -> `"I’m checkingI’m checking where"`

This exactly matches the repeated-word pattern seen on device.

## Concrete Root Cause In Our Bridge

Relevant file:

- [crates/bridge-core/src/thread_api/notifications.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs)

Problematic logic:

- `normalize_item_payload(...)` caches full item state by `event_id`
- `normalize_delta(...)` looks up that cached item state
- `apply_delta_to_item_payload(...)` always does string concatenation for text deltas

The critical code path is:

- [notifications.rs#L193](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs#L193)
- [notifications.rs#L219](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs#L219)
- [notifications.rs#L642](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs#L642)

At [notifications.rs#L648](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs#L648), text merging is:

```rust
let next_text = format!(
    "{}{}",
    object.get("text").and_then(Value::as_str).unwrap_or_default(),
    delta
);
```

That is only correct if `delta` is guaranteed to be a pure suffix. The bridge currently has no guard for:

- cumulative deltas
- overlapping deltas
- mixed `itemAdded` plus later delta updates for the same item

## Proof

I added a focused bridge regression in:

- [crates/bridge-core/src/thread_api/tests/notifications.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/tests/notifications.rs)

Test name:

- `codex_notification_normalizer_duplicates_text_when_item_added_already_contains_prefix`

What it simulates:

1. `turn/started`
2. `thread/realtime/itemAdded` for `agentMessage` with text `"I'm"`
3. `item/agentMessage/delta` with delta `"I'm checking"`

Current bridge result:

- `"I'mI'm checking"`

Targeted verification run:

```bash
cargo test --manifest-path Cargo.toml -p bridge-core codex_notification_normalizer_duplicates_text_when_item_added_already_contains_prefix -- --nocapture
```

Result:

- `ok`

That proves the bridge can generate duplicated assistant text entirely on its own, before Flutter sees the stream.

## Why Flutter Was Not The Root Cause

The Flutter live probe showed duplicated assistant text already present in:

- raw bridge websocket events
- bridge timeline snapshot

not just in rendered Flutter state.

That means Flutter was faithfully rendering already-corrupted bridge payloads in those runs.

## Separate Bridge Bug: Stuck Running

There is also a second bridge issue behind the long-lived `running` state.

Relevant file:

- [crates/bridge-core/src/server/state.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs)

Relevant logic:

- bridge marks the thread running at [state.rs#L1473](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs#L1473)
- transient active-turn state is only cleared for non-running status events at [state.rs#L2283](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs#L2283)
- `turn/completed` itself is normalized to `None` in [notifications.rs#L126](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/notifications.rs#L126)
- desktop IPC live updates are suppressed while the bridge believes it owns an active turn at [state.rs#L2292](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs#L2292) and [state.rs#L1290](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs#L1290)

Implication:

- if a turn finishes but the bridge does not receive a terminal `thread/status/changed` promptly, the bridge can remain `running` and suppress other completion information

This is likely related to the "keeps streaming / keeps running too long" symptom, but it is distinct from the duplicated-text root cause.

## What Litter Does Differently

Reference repo inspected:

- `/tmp/litter`

Key files:

- [/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift)
- [/tmp/litter/apps/android/app/src/main/java/com/litter/android/state/ServerManager.kt](/tmp/litter/apps/android/app/src/main/java/com/litter/android/state/ServerManager.kt)

### Important observation

Litter does not appear to solve this with generic deduplication of assistant text.

Instead, for normal turn streaming, it chooses a single source of truth for assistant/user messages:

- assistant text is handled from `item/agentMessage/delta`
- user text is inserted locally when sending
- `item/started` and `item/completed` explicitly ignore `agentMessage` and `userMessage`

iOS comment:

- [ServerManager.swift#L4066](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift#L4066)
- [ServerManager.swift#L4086](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift#L4086)

Android equivalent:

- [ServerManager.kt#L3566](/tmp/litter/apps/android/app/src/main/java/com/litter/android/state/ServerManager.kt#L3566)

The important principle is:

- they avoid mixing snapshot-style assistant/user item materialization with delta-style assistant streaming for the same semantic message

That is exactly where our bridge currently gets into trouble.

### How they merge

For assistant deltas, Litter simply appends onto the current streaming assistant message:

- iOS: [ServerManager.swift#L2486](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift#L2486)
- Android: [ServerManager.kt#L5975](/tmp/litter/apps/android/app/src/main/java/com/litter/android/state/ServerManager.kt#L5975)

That means Litter is also assuming the direct Codex server contract is pure incremental delta for assistant messages.

So the useful lesson from Litter is not "dedupe everything later". The useful lesson is:

- do not materialize the same assistant/user message from multiple upstream shapes unless you have explicit overlap-aware merge semantics

### What they do dedupe or key

For non-message live items, Litter tracks a stable live item index keyed by item id:

- iOS `liveItemMessageIndices` usage:
  - [ServerManager.swift#L4655](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift#L4655)
  - [ServerManager.swift#L4666](/tmp/litter/apps/ios/Sources/Litter/Models/ServerManager.swift#L4666)

That gives them:

- upsert on `item/started`
- replace on `item/completed`
- append output/progress deltas onto the keyed live item

Again, the principle is stable identity plus one canonical creation path.

## Practical Conclusion

The right fix is not a generic UI dedupe hack.

The bridge needs a clear semantic contract for assistant/user live events:

1. Either treat assistant/user messages as delta-only and ignore partial/full snapshot item materialization for those item types.
2. Or keep both shapes, but merge them with overlap-aware logic rather than blind string append.

Litter strongly suggests option 1 for live assistant/user streams:

- user bubble created locally
- assistant bubble created from delta stream only
- item lifecycle used for tools/commands/other structured items, not for assistant/user message construction

## Likely Fix Direction

Most likely bridge fix direction:

1. For `agentMessage` and `userMessage`, do not let `thread/realtime/itemAdded` or `item/completed` seed text that will later also be extended by `item/*/delta`.
2. If the bridge must support mixed upstream shapes, change text merge from `previous + delta` to overlap-aware merge:
   - pure suffix append if `delta` is a suffix-only continuation
   - replace if `delta` already contains the cached prefix
   - no-op if `delta` matches the current text
3. Clear bridge-owned active turn state on a stronger completion signal than only non-running `thread/status/changed`.

## Open Questions For Follow-Up

- Does Codex always send pure suffix assistant deltas on the direct server path, and our bridge breaks only because it mixes in `itemAdded` snapshots?
- Or can Codex itself emit cumulative `item/agentMessage/delta` payloads in some situations?
- Should the bridge ignore `agentMessage`/`userMessage` item snapshots entirely during an active turn?
- Should `turn/completed` clear `active_turn_ids` even if no terminal thread-status notification arrives?
