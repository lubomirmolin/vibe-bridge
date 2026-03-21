#!/usr/bin/env node

const [, , threadIdArg, baseUrlArg] = process.argv;

if (!threadIdArg) {
  console.error('usage: node scripts/rewrite_codex_smoke.mjs <thread-id> [base-url]');
  process.exit(1);
}

const threadId = threadIdArg;
const baseUrl = baseUrlArg ?? 'http://127.0.0.1:3216';

async function timedJson(url, init) {
  const startedAt = performance.now();
  const response = await fetch(url, init);
  const durationMs = performance.now() - startedAt;
  const text = await response.text();
  let body = null;

  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }

  return {
    ok: response.ok,
    status: response.status,
    durationMs,
    body,
  };
}

async function measureLiveTurn() {
  const wsBase = new URL(baseUrl);
  wsBase.protocol = wsBase.protocol === 'https:' ? 'wss:' : 'ws:';
  wsBase.pathname = `${wsBase.pathname.replace(/\/$/, '')}/events`;
  wsBase.search = new URLSearchParams({
    scope: 'thread',
    thread_id: threadId,
  }).toString();

  const startedAt = performance.now();
  let acceptedMs = null;
  let runningMs = null;
  let assistantMs = null;

  return await new Promise((resolve, reject) => {
    let finished = false;
    const socket = new WebSocket(wsBase);

    const timeout = setTimeout(() => finish(new Error('timed out waiting for live turn')), 20000);

    function finish(result) {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timeout);
      try {
        socket.close();
      } catch {}

      if (result instanceof Error) {
        reject(result);
        return;
      }

      resolve(result);
    }

    socket.addEventListener('error', () => {
      finish(new Error('websocket error while measuring live turn'));
    });

    socket.addEventListener('message', (message) => {
      const data = JSON.parse(message.data.toString());
      if (data.event === 'subscribed') {
        return;
      }

      const elapsedMs = performance.now() - startedAt;
      if (
        data.kind === 'thread_status_changed' &&
        data.payload?.status === 'running' &&
        runningMs == null
      ) {
        runningMs = elapsedMs;
      }

      if (
        data.kind === 'message_delta' &&
        data.payload?.role === 'assistant' &&
        typeof data.payload?.delta === 'string' &&
        data.payload.delta.length > 0 &&
        assistantMs == null
      ) {
        assistantMs = elapsedMs;
      }

      if (
        data.kind === 'thread_status_changed' &&
        data.payload?.status === 'idle' &&
        acceptedMs != null
      ) {
        finish({
          acceptedMs,
          runningMs,
          assistantMs,
        });
      }
    });

    socket.addEventListener('open', async () => {
      try {
        const response = await timedJson(`${baseUrl}/threads/${threadId}/turns`, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            prompt: 'Reply with exactly OK.',
          }),
        });

        if (!response.ok) {
          finish(
            new Error(`turn request failed with ${response.status}: ${JSON.stringify(response.body)}`),
          );
          return;
        }

        acceptedMs = response.durationMs;
      } catch (error) {
        finish(error instanceof Error ? error : new Error(String(error)));
      }
    });
  });
}

const threads = await timedJson(`${baseUrl}/threads`);
const snapshotCold = await timedJson(`${baseUrl}/threads/${threadId}/snapshot`);
const snapshotWarm = await timedJson(`${baseUrl}/threads/${threadId}/snapshot`);
const historyWarm = await timedJson(`${baseUrl}/threads/${threadId}/history?limit=30`);
const liveTurn = await measureLiveTurn();

console.log(
  JSON.stringify(
    {
      baseUrl,
      threadId,
      threads: {
        durationMs: threads.durationMs,
        count: Array.isArray(threads.body) ? threads.body.length : null,
      },
      snapshotCold: {
        durationMs: snapshotCold.durationMs,
        entries: Array.isArray(snapshotCold.body?.entries) ? snapshotCold.body.entries.length : null,
      },
      snapshotWarm: {
        durationMs: snapshotWarm.durationMs,
        entries: Array.isArray(snapshotWarm.body?.entries) ? snapshotWarm.body.entries.length : null,
      },
      historyWarm: {
        durationMs: historyWarm.durationMs,
        entries: Array.isArray(historyWarm.body?.entries) ? historyWarm.body.entries.length : null,
        hasMoreBefore: historyWarm.body?.has_more_before ?? null,
      },
      liveTurn,
    },
    null,
    2,
  ),
);
