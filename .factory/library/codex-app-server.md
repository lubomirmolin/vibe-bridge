# Codex app-server integration notes

Factual upstream protocol notes discovered while wiring bridge-core to real local Codex data.

**What belongs here:** upstream `codex app-server` invocation/protocol details the bridge depends on.

---

- Bridge-core talks to upstream `codex app-server` over line-delimited JSON-RPC on stdio when loading real thread data.
- `CodexRpcClient::start` defaults to `codex app-server` and appends `--listen stdio://` when no `--listen` argument is already present.
- The startup handshake sends `initialize` with `clientInfo = { name: "bridge-core", version: CONTRACT_VERSION }` before any thread requests.
- Thread preload currently caps at 50 threads per startup sync.
- Thread discovery first calls `thread/list` with an optional `cursor`; the response shape used by bridge-core is `{ data: CodexThread[], nextCursor?: string }`.
- For each listed thread, bridge-core attempts `thread/read` with `{ threadId, includeTurns: true }`; if that richer read fails, it falls back to the summary returned by `thread/list`.
- Upstream thread fields currently consumed by bridge-core include `id`, optional `name`, optional `summary`, `updatedAt`, `createdAt`, `status.type`, `cwd`, optional `gitInfo.branch`, optional `gitInfo.originUrl`, and `turns[].items[].type`.
- Upstream status normalization currently maps `active -> active`, `systemError -> error`, and any other status kind to idle.
- Upstream item-type normalization currently maps `plan -> plan_delta`, `commandExecution -> command_output_delta`, `fileChange -> file_change_delta`, and any other item type to `agent_message_delta`.
