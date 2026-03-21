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
    accepted,
    totalDurationMs: performance.now() - startedAt,
    listEvents: listCollector.events,
    threadEvents: threadCollector.events,
  };
}

function aggregateThreadEvents(events) {
  const byEventId = new Map();

  for (const event of events) {
    const existing = byEventId.get(event.event_id);
    byEventId.set(
      event.event_id,
      {
        eventId: event.event_id,
        kind: event.kind,
        occurredAt: event.occurred_at,
        payload: aggregateLivePayload(existing?.payload, event.kind, event.payload ?? {}),
      },
    );
  }

  return byEventId;
}

function findLastAssistantMessage(entries) {
  return [...entries]
    .reverse()
    .find((entry) => entry.kind === 'message_delta' && entry.payload?.role === 'assistant');
}

function compareHistoryAgainstSnapshot(snapshot, historyPage) {
  const expectedEntries = snapshot.entries.slice(-historyPage.entries.length);
  const expectedIds = expectedEntries.map((entry) => entry.event_id);
  const actualIds = historyPage.entries.map((entry) => entry.event_id);
  assert(
    JSON.stringify(actualIds) === JSON.stringify(expectedIds),
    'history page does not match snapshot suffix',
    { expectedIds, actualIds },
  );
}

function compareLiveAggregateAgainstSnapshot(liveAggregate, snapshot) {
  const snapshotEntriesById = new Map(snapshot.entries.map((entry) => [entry.event_id, entry]));

  for (const [eventId, aggregated] of liveAggregate.entries()) {
    const snapshotEntry = snapshotEntriesById.get(eventId);
    assert(snapshotEntry, 'snapshot missing live event entry', { eventId, aggregated });
    assert(snapshotEntry.kind === aggregated.kind, 'snapshot event kind mismatch', {
      eventId,
      expected: aggregated.kind,
      actual: snapshotEntry.kind,
    });

    const expectedPayload = aggregated.payload;
    const actualPayload = normalizeSnapshotPayload(snapshotEntry.kind, snapshotEntry.payload ?? {});
    assert(
      JSON.stringify(actualPayload) === JSON.stringify(expectedPayload),
      'snapshot payload does not match live aggregate',
      { eventId, expectedPayload, actualPayload },
    );
  }
}

async function main() {
  const bootstrap = await timedJson(`${baseUrl}/bootstrap`);
  assert(bootstrap.ok, 'bootstrap failed', bootstrap.body);
  assert(bootstrap.body?.contract_version, 'bootstrap missing contract version', bootstrap.body);

  const threadList = await timedJson(`${baseUrl}/threads`);
  assert(threadList.ok, 'threads request failed', threadList.body);
  assert(Array.isArray(threadList.body), 'threads response is not a list', threadList.body);

  const bootstrapThreads = Array.isArray(bootstrap.body?.threads) ? bootstrap.body.threads : [];
  assert(
    bootstrapThreads.length === threadList.body.length,
    'bootstrap thread count differs from /threads',
    {
      bootstrapCount: bootstrapThreads.length,
      threadCount: threadList.body.length,
    },
  );

  const threadIdsFromBootstrap = bootstrapThreads.map((thread) => thread.thread_id);
  const threadIdsFromList = threadList.body.map((thread) => thread.thread_id);
  assert(
    JSON.stringify(threadIdsFromBootstrap) === JSON.stringify(threadIdsFromList),
    'bootstrap and /threads differ',
    { threadIdsFromBootstrap, threadIdsFromList },
  );

  const existingThreadId = existingThreadIdArg ?? threadList.body[0]?.thread_id;
  assert(existingThreadId, 'no thread id available to compare against real data');

  const existingSnapshot = await timedJson(`${baseUrl}/threads/${existingThreadId}/snapshot`);
  assert(existingSnapshot.ok, 'existing thread snapshot failed', existingSnapshot.body);
  const existingHistory = await timedJson(`${baseUrl}/threads/${existingThreadId}/history?limit=30`);
  assert(existingHistory.ok, 'existing thread history failed', existingHistory.body);
  compareHistoryAgainstSnapshot(existingSnapshot.body, existingHistory.body);

  const prompt = `Reply with exactly ${token} and nothing else.`;
  const liveTurn = await collectLiveTurn(existingThreadId, prompt, token);
  const finalSnapshot = await timedJson(`${baseUrl}/threads/${existingThreadId}/snapshot`);
  assert(finalSnapshot.ok, 'final snapshot failed', finalSnapshot.body);
  const finalHistory = await timedJson(`${baseUrl}/threads/${existingThreadId}/history?limit=50`);
  assert(finalHistory.ok, 'final history failed', finalHistory.body);
  compareHistoryAgainstSnapshot(finalSnapshot.body, finalHistory.body);

  const liveAggregate = aggregateThreadEvents(liveTurn.threadEvents);
  compareLiveAggregateAgainstSnapshot(liveAggregate, finalSnapshot.body);

  const lastAssistantMessage = findLastAssistantMessage(finalSnapshot.body.entries);
  assert(lastAssistantMessage, 'final snapshot missing assistant message', finalSnapshot.body);
  assert(
    lastAssistantMessage.payload?.text?.includes(token),
    'assistant message does not contain expected token',
    lastAssistantMessage,
  );

  const listNonStatusEvents = liveTurn.listEvents.filter(
    (event) => event.kind !== 'thread_status_changed',
  );
  assert(listNonStatusEvents.length === 0, 'list scope leaked non-status events', listNonStatusEvents);

  const listEventsForCreatedThread = liveTurn.listEvents.filter(
    (event) => event.thread_id === existingThreadId,
  );
  assert(listEventsForCreatedThread.length > 0, 'list scope did not receive thread status', {
    existingThreadId,
    listEvents: liveTurn.listEvents,
  });

  const summaryAfterTurn = await timedJson(`${baseUrl}/threads`);
  assert(summaryAfterTurn.ok, 'summary fetch after turn failed', summaryAfterTurn.body);
  const existingSummary = summaryAfterTurn.body.find((thread) => thread.thread_id === existingThreadId);
  assert(existingSummary, 'thread missing from /threads after live turn', {
    existingThreadId,
    threads: summaryAfterTurn.body,
  });
  assert(
    existingSummary.status === finalSnapshot.body.thread.status,
    'summary status differs from final snapshot status',
    {
      summaryStatus: existingSummary.status,
      snapshotStatus: finalSnapshot.body.thread.status,
    },
  );

  console.log(
    JSON.stringify(
      {
        ok: true,
        baseUrl,
        existingThreadId,
        verifyToken: token,
        bootstrapThreadCount: bootstrapThreads.length,
        existingThread: {
          beforeEntries: existingSnapshot.body.entries.length,
          historyEntries: existingHistory.body.entries.length,
          snapshotMs: existingSnapshot.durationMs,
          historyMs: existingHistory.durationMs,
        },
        liveTurn: {
          acceptedMs: liveTurn.accepted.durationMs,
          totalDurationMs: liveTurn.totalDurationMs,
          listEventCount: liveTurn.listEvents.length,
          threadEventCount: liveTurn.threadEvents.length,
        },
        finalSnapshot: {
          status: finalSnapshot.body.thread.status,
          entries: finalSnapshot.body.entries.length,
          lastAssistantPreview: lastAssistantMessage.payload.text.slice(0, 120),
        },
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(
    JSON.stringify(
      {
        ok: false,
        message: error.message,
        details: error.details ?? null,
      },
      null,
      2,
    ),
  );
  process.exit(1);
});
