# API

Notes about the stable product API between the mobile client and the bridge.

**What belongs here:** bridge-owned endpoint/event contracts, normalization rules, and API invariants.

---

- Product API should stay stable even if upstream `codex app-server` changes.
- Timeline page semantics matter for mobile correctness: the bridge should emit stable mixed-event ordering and before-cursor behavior so initial hydration, reconnect catch-up, and older-history paging all observe the same logical event sequence.
- For the real-data thread-detail parity mission, `GET /threads/:id`, `GET /threads/:id/timeline`, and `GET /policy/access-mode` must stay mutually coherent for the selected thread; visible Flutter controls should not depend on conflicting sources of access-mode truth.
- For the backend-first performance follow-up, sequential `GET /threads/:id` and `GET /threads/:id/timeline` for the same unchanged thread should reuse one fresh per-thread snapshot/sync generation rather than triggering duplicate expensive bridge work.
- The canonical regression thread for this mission is `019d0d0c-07df-7632-81fa-a1636651400a`. When validating fixes, compare both detail metadata and merged timeline output against that thread's live bridge payload and `~/.codex/sessions/...jsonl` source data.
- Planned mobile-facing surfaces:
  - pairing/session endpoints
  - thread list/detail/timeline endpoints
  - open-on-Mac endpoint for best-effort Codex.app compatibility
  - turn start/steer/interrupt endpoints
  - approvals endpoints
  - git control endpoints
  - websocket stream for normalized thread, plan, command, approval, and item events
- Do not leak raw upstream request/notification shapes directly into Flutter state or UI.
- Every mutation surface should preserve repo/thread context and user-facing result feedback.
- Bridge-core currently exposes `WS /stream?thread_id=<id>` and also accepts `thread_ids=<id1,id2>`; when no thread filter is provided it subscribes to all currently listed threads.
- Successful websocket subscriptions send an immediate JSON ack with `contract_version`, `event: "subscribed"`, and the resolved `thread_ids` list before live event frames begin.
- Git status responses are normalized as `GitStatusResponse { contract_version, thread_id, repository, status }`.
- Turn and git mutation endpoints return `MutationResultResponse { contract_version, thread_id, operation, outcome, message, thread_status, repository, status }` so clients can refresh visible thread and repo state from one payload.
- When bridge detail is refreshed from mixed archive/RPC sources, freshness fields (`updated_at`, `last_turn_summary`, status context) should remain coherent with the newest substantive visible timeline event for that same thread.
- Reconnect catch-up for an already-open unchanged thread should not force a second back-to-back expensive sync/archive pass when the preceding request already produced the same fresh snapshot.
- `POST /threads/:id/open-on-mac` returns `OpenOnMacResponse { contract_version, thread_id, attempted_url, message, best_effort }` on success and is intentionally best effort: a successful response only means the bridge asked macOS to open a matching `codex://` deep link, while mobile must remain usable even if Codex.app does not live-refresh immediately.
- Approval records currently expose generic git-action target identifiers in `ApprovalRecordDto.target` (for example `git.branch_switch`, `git.pull`, `git.push`) rather than concrete branch or remote destination values, so mobile clients cannot infer exact branch-switch targets from that field alone.
- `/health` currently advertises the concrete pairing/policy/approval/security surfaces: `POST /pairing/session`, `POST /pairing/finalize`, `POST /pairing/handshake`, `POST /pairing/trust/revoke`, `GET/POST /policy/access-mode`, `GET /approvals`, `POST /approvals/:id/approve`, `POST /approvals/:id/reject`, and `GET /security/events`.
- `PairingSessionResponse` returns `bridge_identity { bridge_id, display_name, api_base_url }`, `pairing_session { session_id, pairing_token, issued_at_epoch_seconds, expires_at_epoch_seconds }`, and a `qr_payload` JSON string that repeats the mobile-scanned fields as `contract_version`, `bridge_id`, `bridge_name`, `bridge_api_base_url`, `session_id`, `pairing_token`, `issued_at_epoch_seconds`, and `expires_at_epoch_seconds`.
- `POST /pairing/finalize` accepts `PairingFinalizeRequest { session_id, pairing_token, phone_id, phone_name, bridge_id }` and returns `PairingFinalizeResponse { contract_version, bridge_identity, trusted_phone, session_token }` on success.
- Any debug/manual pairing entry in Flutter must still funnel into the same `POST /pairing/finalize` contract after trust review; no alternate trust-persistence path should be introduced.
- `POST /pairing/handshake` accepts `PairingHandshakeRequest { phone_id, bridge_id, session_token }` and fails closed with bridge-owned codes such as `bridge_identity_mismatch`, `trust_revoked`, `trusted_phone_mismatch`, and `session_token_mismatch`.
- `POST /policy/access-mode` now requires the same trusted-session credentials (`phone_id`, `bridge_id`, and `session_token`) as other sensitive pairing/security mutations; unauthenticated or untrusted callers are rejected instead of mutating global policy state.
- `GET /security/events` returns `SecurityAuditEventDto { actor, action, target, outcome, reason }`, which is the shared audit record shape later mobile/security surfaces should display directly.
