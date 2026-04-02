# Bridge Fix Validation

This document captures the validation flow for the Codex duplication bug and the related turn-lifecycle fixes:

- raw Codex `item/*` text deltas must stay incremental instead of being re-expanded into duplicated text
- bridge-owned turns must not finalize before the authoritative live stream has actually finished
- terminal live status must clear stale `active_turn_id`
- the Flutter controller must replace malformed live text with the canonical snapshot/timeline instead of accumulating duplicates

Run the checks in this order.

## 1. Targeted Bridge Tests

From the repo root:

```bash
cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion

cargo test --manifest-path Cargo.toml -p bridge-core terminal_live_thread_status_clears_active_turn_id -- --nocapture
cargo test --manifest-path Cargo.toml -p bridge-core watchdog_does_not_finalize_while_turn_stream_is_active -- --nocapture
cargo test --manifest-path Cargo.toml -p bridge-core delta_notifications_publish_raw_text_deltas_and_skip_hidden_messages -- --nocapture
cargo test --manifest-path Cargo.toml -p bridge-core live_delta_compactor_preserves_raw_codex_message_deltas -- --nocapture
cargo test --manifest-path Cargo.toml -p bridge-core whitespace_only_message_deltas_still_publish -- --nocapture
cargo build --manifest-path Cargo.toml -p bridge-core --bin bridge-server
```

Expected result:

- all targeted Rust tests pass
- `bridge-server` builds successfully

## 2. Targeted Flutter Controller Tests

From `apps/mobile`:

```bash
cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile

flutter test test/features/threads/reconnect_retry_scheduling_test.dart --plain-name "thread-detail accepts newer completed detail when the live completion event is missed"
flutter test test/features/threads/reconnect_retry_scheduling_test.dart --plain-name "thread-detail snapshot refresh fetches enough history to replace older malformed live assistant text"
flutter test test/features/threads/reconnect_retry_scheduling_test.dart --plain-name "thread-detail keeps pending snapshot refresh after completed status even if trailing live deltas arrive"
flutter test test/features/threads/reconnect_retry_scheduling_test.dart --plain-name "thread-detail ignores exact duplicate live assistant frames"
```

Expected result:

- all four Flutter tests pass
- the snapshot refresh tests replace malformed live text with canonical timeline text
- the duplicate-frame test keeps a single assistant item

## 3. Direct Bridge Two-Turn Repro

Start the local bridge on `127.0.0.1:3310` from the repo root:

```bash
cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion
target/debug/bridge-server --host 127.0.0.1 --port 3310
```

In a second terminal, run the exact two-turn bridge repro:

```bash
node <<'EOF'
const fetch = global.fetch;
const base = 'http://127.0.0.1:3310';
const workspace = '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion';
const prompt1 =
  'Inspect only apps/mobile/lib/app_startup_page.dart and ' +
  'apps/mobile/android/app/src/main/res/drawable/launch_background.xml. ' +
  'Reply in exactly 2 short sentences about how splash handoff works. ' +
  'Do not edit files, do not use apply_patch, and do not ask for approval.';
const prompt2 =
  'Inspect only packages/codex_ui/lib/src/widgets/animated_bridge_background.dart. ' +
  'Reply in exactly 2 short sentences about whether that bridge artwork is reusable for Android splash work. ' +
  'Do not edit files, do not use apply_patch, and do not ask for approval.';
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function post(path, body) {
  const res = await fetch(base + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path} ${res.status} ${text}`);
  return JSON.parse(text);
}

async function get(path) {
  const res = await fetch(base + path);
  const text = await res.text();
  if (!res.ok) throw new Error(`${path} ${res.status} ${text}`);
  return JSON.parse(text);
}

function normalize(text) {
  return String(text ?? '').replace(/\s+/g, ' ').trim();
}

function messageText(payload) {
  if (typeof payload?.text === 'string' && payload.text.trim()) return payload.text;
  if (typeof payload?.delta === 'string' && payload.delta.trim()) return payload.delta;
  return '';
}

function isUserPayload(payload) {
  return payload?.role === 'user' || payload?.type === 'userMessage';
}

async function waitForNonRunning(threadId, maxPolls) {
  let last = null;
  for (let i = 0; i < maxPolls; i += 1) {
    last = await get(`/threads/${encodeURIComponent(threadId)}/snapshot`);
    if (last.thread.status !== 'running') return last;
    await sleep(500);
  }
  return last;
}

(async () => {
  const created = await post('/threads', { provider: 'codex', workspace });
  const threadId = created.thread.thread_id;
  const turn1 = await post(`/threads/${encodeURIComponent(threadId)}/turns`, { prompt: prompt1 });
  const after1 = await waitForNonRunning(threadId, 300);
  const turn2 = await post(`/threads/${encodeURIComponent(threadId)}/turns`, { prompt: prompt2 });
  const after2 = await waitForNonRunning(threadId, 300);
  const history = await get(`/threads/${encodeURIComponent(threadId)}/history`);

  const promptCounts = history.entries.reduce(
    (counts, entry) => {
      if (entry.kind !== 'message_delta' || !isUserPayload(entry.payload)) {
        return counts;
      }
      const text = normalize(messageText(entry.payload));
      if (text === normalize(prompt1)) counts.prompt1 += 1;
      if (text === normalize(prompt2)) counts.prompt2 += 1;
      return counts;
    },
    { prompt1: 0, prompt2: 0 },
  );

  console.log(JSON.stringify({
    threadId,
    turn1: turn1.turn_id,
    turn1Status: after1.thread.status,
    turn2: turn2.turn_id,
    turn2Status: after2.thread.status,
    activeTurnId: after2.thread.active_turn_id,
    historyEntries: history.entries.length,
    prompt1Count: promptCounts.prompt1,
    prompt2Count: promptCounts.prompt2,
    lastHistoryKind: history.entries.at(-1)?.kind ?? null,
    lastHistorySummary: history.entries.at(-1)?.summary ?? null,
  }, null, 2));
})();
EOF
```

Expected result:

- `turn1Status` is not `running`
- `turn2Status` is not `running`
- `activeTurnId` is `null`
- `prompt1Count` is `1`
- `prompt2Count` is `1`
- history ends with a terminal thread status, typically `idle` or `completed`

If it does not settle, inspect:

```bash
curl -sf http://127.0.0.1:3310/threads/<thread_id>/snapshot | jq
curl -sf http://127.0.0.1:3310/threads/<thread_id>/history | jq
ls /Users/lubomirmolin/.codex/sessions/$(date +%Y/%m/%d)/rollout-*<native_thread_id>.jsonl
```

## 4. Host-Side Live Duplicate Probe

This is the fastest live check that compares raw bridge events, bridge timeline output, and Flutter controller state without involving the Samsung UI.

```bash
cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile

flutter test test/features/threads/live_bridge_duplicate_probe_test.dart \
  --dart-define=RUN_LIVE_DUPLICATE_PROBE=true \
  --dart-define=LIVE_DUPLICATE_PROBE_BRIDGE_BASE_URL=http://127.0.0.1:3310 \
  --dart-define=LIVE_DUPLICATE_PROBE_ATTEMPTS=5
```

Optional:

- add `--dart-define=LIVE_DUPLICATE_PROBE_PROMPT='how are we doing the thread title?'` to pin the prompt under investigation

Expected result:

- the test exits cleanly
- logs end with `LIVE_DUPLICATE_PROBE_SUMMARY ... result=clean`
- there are no `LIVE_DUPLICATE_PROBE detected duplicate symptoms` failures

## 5. Samsung End-to-End Validation

Use the local bridge on `3310` and run the mobile live test on the Samsung:

```bash
adb -s R3CY90LAMTP reverse tcp:3310 tcp:3310

cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile

flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/live_codex_duplicate_text_test.dart \
  -d R3CY90LAMTP \
  --dart-define=LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL=http://127.0.0.1:3310 \
  --dart-define=LIVE_CODEX_THREAD_CREATION_WORKSPACE=/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion
```

Optional:

- add `--dart-define=LIVE_CODEX_THREAD_CREATION_PROMPT_ONE='...'`
- add `--dart-define=LIVE_CODEX_THREAD_CREATION_PROMPT_TWO='...'`

Expected result:

- turn 1 completes
- turn 2 completes
- there is no stuck `running` snapshot after either turn
- controller assistant text matches the canonical bridge timeline after the second turn
- logs include `LIVE_CODEX_DUPLICATE_TEXT_RESULT`

## 6. Pass Criteria

Treat the fix as validated only if all of the following are true:

- targeted Rust tests pass
- targeted Flutter controller tests pass
- direct bridge two-turn repro settles correctly
- host-side live duplicate probe is clean
- device E2E passes on the live bridge

Triage guidance:

- if the direct bridge repro already duplicates prompts or leaves `activeTurnId`, keep debugging the bridge
- if the bridge repro is clean but the host-side probe or Samsung E2E still duplicates text, keep debugging the Flutter/controller path
