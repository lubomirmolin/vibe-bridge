#!/usr/bin/env node

const [, , existingThreadIdArg, baseUrlArg] = process.argv;

const baseUrl = baseUrlArg ?? 'http://127.0.0.1:3216';
const token = `VERIFY_${Date.now()}`;

function fail(message, details) {
  const error = new Error(message);
  error.details = details;
  throw error;
}

function assert(condition, message, details) {
  if (!condition) {
    fail(message, details);
  }
}

async function timedJson(url, init) {
  const startedAt = performance.now();
  const response = await fetch(url, init);
  const durationMs = performance.now() - startedAt;
  const text = await response.text();

  let body = null;
  try {
    body = text.length === 0 ? null : JSON.parse(text);
  } catch {
    body = text;
  }

  return {
    ok: response.ok,
    status: response.status,
    durationMs,
    headers: response.headers,
    body,
  };
}

function wsUrlFor(scope, threadId) {
  const url = new URL(baseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.pathname = `${url.pathname.replace(/\/$/, '')}/events`;
  const params = new URLSearchParams({ scope });
  if (threadId) {
    params.set('thread_id', threadId);
  }
  url.search = params.toString();
  return url.toString();
}

function mergeIncrementalText(existing, incomingDelta, replace) {
  if (replace || !existing) {
    return incomingDelta;
  }
  return `${existing}${incomingDelta}`;
}

function aggregateLivePayload(existingPayload, kind, incomingPayload) {
  switch (kind) {
    case 'message_delta':
      return {
        id: incomingPayload.id ?? existingPayload?.id ?? '',
        type: 'message',
        role: incomingPayload.role ?? existingPayload?.role ?? 'assistant',
        text: mergeIncrementalText(
          existingPayload?.text ?? '',
          incomingPayload.delta ?? incomingPayload.text ?? '',
          Boolean(incomingPayload.replace),
        ),
      };
    case 'plan_delta':
      return {
        id: incomingPayload.id ?? existingPayload?.id ?? '',
        type: 'plan',
        text: mergeIncrementalText(
          existingPayload?.text ?? '',
          incomingPayload.delta ?? incomingPayload.text ?? '',
          Boolean(incomingPayload.replace),
        ),
      };
    case 'command_delta':
      return {
        id: incomingPayload.id ?? existingPayload?.id ?? '',
        type: 'command',
        command: incomingPayload.command ?? existingPayload?.command ?? '',
        cmd: incomingPayload.cmd ?? existingPayload?.cmd ?? null,
        workdir: incomingPayload.workdir ?? incomingPayload.cwd ?? existingPayload?.workdir ?? null,
        output: mergeIncrementalText(
          existingPayload?.output ?? '',
          incomingPayload.delta ?? incomingPayload.output ?? '',
          Boolean(incomingPayload.replace),
        ),
      };
    case 'file_change':
      return {
        id: incomingPayload.id ?? existingPayload?.id ?? '',
        type: 'file_change',
        path: incomingPayload.path ?? incomingPayload.file ?? existingPayload?.path ?? '',
        diff: mergeIncrementalText(
          existingPayload?.diff ?? '',
          incomingPayload.delta ?? incomingPayload.output ?? '',
          Boolean(incomingPayload.replace),
        ),
      };
    case 'thread_status_changed':
      return {
        status: incomingPayload.status,
        reason: incomingPayload.reason ?? existingPayload?.reason ?? null,
      };
    default:
      return incomingPayload;
  }
}

function normalizeSnapshotPayload(kind, payload) {
  switch (kind) {
    case 'message_delta':
      return {
        id: payload.id ?? '',
        type: payload.type ?? 'message',
        role: payload.role ?? 'assistant',
        text: payload.text ?? '',
      };
    case 'plan_delta':
      return {
        id: payload.id ?? '',
        type: payload.type ?? 'plan',
        text: payload.text ?? '',
      };
    case 'command_delta':
      return {
        id: payload.id ?? '',
        type: payload.type ?? 'command',
        command: payload.command ?? '',
        cmd: payload.cmd ?? null,
        workdir: payload.workdir ?? null,
        output: payload.output ?? '',
      };
    case 'file_change':
      return {
        id: payload.id ?? '',
        type: payload.type ?? 'file_change',
        path: payload.path ?? '',
        diff: payload.diff ?? payload.output ?? '',
      };
    case 'thread_status_changed':
      return {
        status: payload.status,
        reason: payload.reason ?? null,
      };
    default:
      return payload;
  }
}

function makeSocketCollector(scope, threadId) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrlFor(scope, threadId));
    const events = [];
    let subscribed = false;

    socket.addEventListener('open', () => {});
    socket.addEventListener('error', () => {
      reject(new Error(`${scope} websocket error`));
    });
    socket.addEventListener('message', (message) => {
      const data = JSON.parse(message.data.toString());
      if (data.event === 'subscribed') {
        subscribed = true;
        resolve({
          socket,
          events,
          waitForAck: Promise.resolve(),
          isSubscribed: () => subscribed,
        });
        return;
      }

      events.push(data);
    });
  });
}

async function collectLiveTurn(threadId, prompt, expectedToken) {
  const listCollector = await makeSocketCollector('list');
  const threadCollector = await makeSocketCollector('thread', threadId);
  const accepted = await timedJson(`${baseUrl}/threads/${threadId}/turns`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ prompt }),
  });

  assert(accepted.ok, 'turn request failed', accepted.body);

  const startedAt = performance.now();
  await (async () => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const snapshot = await timedJson(`${baseUrl}/threads/${threadId}/snapshot`);
      if (!snapshot.ok) {
        await new Promise((resolve) => setTimeout(resolve, 250));
        continue;
      }

      const assistantMessage = findLastAssistantMessage(snapshot.body.entries ?? []);
      const isFinished = snapshot.body.thread?.status !== 'running';
      const hasExpectedAssistantText = assistantMessage?.payload?.text?.includes(expectedToken);
      if (isFinished && hasExpectedAssistantText) {
        return;
      }

      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    fail('timed out waiting for live turn completion');
  })().finally(() => {
    try {
      listCollector.socket.close();
    } catch {}
    try {
      threadCollector.socket.close();
    } catch {}
  });

  return {
    durationMs: performance.now() - startedAt,
    listEvents: listCollector.events,
    threadEvents: threadCollector.events,
  };
}

function findLastAssistantMessage(entries) {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.kind !== 'message_delta') {
      continue;
    }

    const normalizedPayload = normalizeSnapshotPayload(entry.kind, entry.payload ?? {});
    if (normalizedPayload.role === 'assistant') {
      return { ...entry, payload: normalizedPayload };
    }
  }

  return null;
}

async function main() {
  const threads = await timedJson(`${baseUrl}/threads`);
  assert(threads.ok, 'threads request failed', threads.body);

  const threadId =
    existingThreadIdArg ??
    threads.body?.[0]?.thread_id ??
    fail('no thread id provided and no threads available');

  const snapshot = await timedJson(`${baseUrl}/threads/${threadId}/snapshot`);
  assert(snapshot.ok, 'snapshot request failed', snapshot.body);

  const liveTurn = await collectLiveTurn(
    threadId,
    `Reply with exactly ${token}.`,
    token,
  );

  console.log(
    JSON.stringify(
      {
        baseUrl,
        threadId,
        liveTurn,
      },
      null,
      2,
    ),
  );
}

await main();
