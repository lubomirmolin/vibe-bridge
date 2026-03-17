# Codex Mobile Companion: Discovery and Architecture

## Goal

Build a dedicated mobile companion for Codex that lets a phone connect to a Mac, watch live agent output, handle approvals, steer running turns, and browse thread history without using VNC or screen streaming.

The target shape is:

- Flutter app on iPhone
- Mac bridge process/app
- Codex runtime stays on the Mac
- Tailscale used from the start for private remote access
- QR pairing from the start
- `Codex.app` treated as an optional secondary desktop viewer, not the primary integration surface

## Executive Summary

The right architecture is not "remote control Codex.app". The right architecture is "mobile client for Codex app-server, with a Mac bridge in front of it".

Why:

- `Codex.app` appears to be an Electron desktop client built on top of the same `codex app-server` runtime exposed by the CLI.
- The local Codex runtime already exposes thread lifecycle, turn lifecycle, live deltas, command execution streaming, and control methods.
- Codex persists thread/session data under `~/.codex`, which means the desktop app and our bridge can share the same underlying conversation history.
- There is a known desktop limitation: the desktop app does not appear to live-reload external thread writes reliably, so desktop refresh should be treated as a best-effort compatibility feature, not a core dependency.

This means the mobile product should speak to our own Mac bridge, and that bridge should speak to Codex locally.

## Discovery: What Is Installed Locally

### Codex.app bundle facts

Local app inspected:

- `/Applications/Codex.app`
- Bundle identifier: `com.openai.codex`
- Display name: `Codex`
- URL scheme: `codex://`
- Version found locally: `26.313.41514`
- Bundle type: Electron app

Evidence came from:

- `/Applications/Codex.app/Contents/Info.plist`
- `/Applications/Codex.app/Contents/Resources/app.asar`

The app bundle contains:

- `app.asar`
- `codex` binary
- bundled `rg`
- JS bundles for `bootstrap`, `main`, `preload`, and `worker`
- embedded `better-sqlite3`

This is consistent with an Electron desktop shell around a local Codex runtime and disk-backed state.

### Local runtime facts

The local CLI exposes:

- `codex app-server`
- `codex app-server generate-json-schema`

The generated schema shows that Codex already has a structured JSON-RPC protocol for app clients.

Key client request methods discovered:

- `thread/start`
- `thread/list`
- `thread/read`
- `thread/resume`
- `thread/fork`
- `thread/archive`
- `turn/start`
- `turn/steer`
- `turn/interrupt`
- `command/exec`
- `command/exec/write`
- `command/exec/resize`
- `command/exec/terminate`

Key server notifications discovered:

- `thread/started`
- `thread/status/changed`
- `thread/tokenUsage/updated`
- `turn/started`
- `turn/completed`
- `turn/plan/updated`
- `item/agentMessage/delta`
- `item/commandExecution/outputDelta`
- `item/commandExecution/terminalInteraction`
- `item/plan/delta`
- `item/fileChange/outputDelta`
- `thread/realtime/itemAdded`

This is already enough to build a full remote client without scraping the desktop UI.

### Local persisted state facts

Codex persists data locally under `~/.codex`.

Observed files and directories:

- `~/.codex/session_index.jsonl`
- `~/.codex/sessions/.../rollout-*.jsonl`
- `~/.codex/history.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/logs_1.sqlite`

Observed SQLite tables include:

- `threads`
- `logs`
- `jobs`
- `agent_jobs`
- `agent_job_items`

Observed `threads` table columns include:

- `id`
- `rollout_path`
- `created_at`
- `updated_at`
- `source`
- `model_provider`
- `cwd`
- `title`
- `sandbox_policy`
- `approval_mode`
- `git_sha`
- `git_branch`
- `git_origin_url`

Observed source kinds in the local `threads` table:

- `vscode`
- `cli`
- `exec`
- review/subagent variants

This confirms that Codex has a durable thread/session model outside the desktop UI.

### Evidence that Codex.app itself uses app-server concepts

Bundle and binary strings revealed:

- `app-server manager hooks`
- `app-server connection state`
- `in-process app-server`
- `app-server websocket listening on ws://`
- `thread/start`
- `turn/start`
- `thread/read`
- `thread/list`
- `item/agentMessage/delta`
- `command/exec/outputDelta`

Inference:

- `Codex.app` is very likely consuming the same `app-server` protocol family rather than using a completely separate private engine.
- We should not depend on reverse engineering the Electron UI.
- We should integrate at the runtime/protocol level.

## Discovery: Desktop App Limitation

The strongest external confirmation came from `remodex`, which describes itself as a local-first Mac bridge + iOS app for Codex.

Its README states that:

- the bridge spawns `codex app-server`
- threads are persisted under `~/.codex/sessions`
- the desktop app reads those thread files
- the desktop app does not live-reload when an external app-server writes new data
- a deep-link route bounce is used as a workaround

Reference:

- <https://github.com/Emanuele-web04/remodex>
- <https://raw.githubusercontent.com/Emanuele-web04/remodex/main/README.md>

This aligns with the local findings.

### Practical implication

Our system should treat `Codex.app` support as:

- optional thread visibility on desktop
- optional route refresh integration
- optional "open current thread on Mac" action

It should not treat `Codex.app` as the system we remote-control.

## Discovery: Tailscale Suitability

Using Tailscale from the start is a good fit.

Why:

- It avoids building our own NAT traversal system.
- It gives private device-to-device connectivity without publishing a public endpoint.
- The bridge can stay bound to localhost and be proxied safely.
- We can still keep the product self-hosted and local-first.

Current Tailscale docs state:

- peers may connect directly, through a peer relay, or through DERP relay
- all three modes are still end-to-end encrypted WireGuard connections
- direct is best, relay is fallback
- `tailscale serve` can expose a local web service privately to the tailnet

References:

- <https://tailscale.com/kb/1411/device-connectivity>
- <https://tailscale.com/docs/reference/connection-types>
- <https://tailscale.com/docs/features/tailscale-serve>

### Practical implication

For this product, Tailscale should be treated as:

- transport/private network layer
- not application auth
- not pairing

We still need our own:

- pairing
- device trust
- session auth
- authorization model

## Recommended Product Architecture

### High-level topology

```text
+-------------------+          tailnet/WSS           +----------------------+
| Flutter iPhone App| <----------------------------> | Mac Bridge App/Daemon|
+-------------------+                                 +----------------------+
                                                              |
                                                              | local JSON-RPC
                                                              v
                                                     +----------------------+
                                                     | codex app-server     |
                                                     +----------------------+
                                                              |
                                                              | shared session state
                                                              v
                                                     +----------------------+
                                                     | ~/.codex             |
                                                     | sessions/sqlite/jsonl|
                                                     +----------------------+
                                                              |
                                                              | optional desktop view
                                                              v
                                                     +----------------------+
                                                     | Codex.app            |
                                                     +----------------------+
```

### Core rule

The Flutter app never talks to `codex app-server` directly.

It always talks to our bridge.

Reasons:

- we need pairing and device identity
- we need access control
- we need a product-specific API surface
- we may want policy enforcement that differs from raw Codex capabilities
- we do not want to expose local Codex credentials or internal APIs directly

## Bridge Responsibilities

The Mac bridge is the core of the product.

It should do all of the following:

- spawn or attach to local `codex app-server`
- keep the app-server connection alive
- translate product API calls into Codex JSON-RPC
- maintain paired-device trust state
- expose a narrow app API to the phone
- stream live deltas to the phone
- gate approvals and dangerous actions
- optionally trigger desktop app refresh/open-thread behavior
- maintain app-level settings and audit logs

### Bridge deployment shape

Preferred form:

- macOS menu bar app or background app with login item

Needed behavior:

- survives terminal closure
- can show pairing QR
- can display connection status
- can expose "paired devices", "active sessions", and "open in Codex.app"

### Bridge API layers

1. Internal Codex adapter

- raw JSON-RPC to `codex app-server`
- maps app-server requests/responses/notifications

2. Product service layer

- thread service
- turn service
- approval service
- terminal stream service
- git service if we choose to expose git controls
- pairing/auth service

3. External mobile API

- minimal mobile-oriented WebSocket + REST surface
- stable schema independent from upstream Codex protocol churn

## Pairing and Security Model

### Pairing flow

Use QR pairing from the start.

Recommended QR payload:

- bridge device ID
- bridge public identity key
- bridge local tailnet URL
- short-lived pairing token
- issued-at and expiry
- optional bridge display name

Recommended flow:

1. User opens bridge app on Mac.
2. Bridge shows a QR code.
3. Flutter app scans QR.
4. Phone connects to bridge over Tailscale URL.
5. Phone and bridge perform authenticated handshake.
6. Bridge stores trusted phone identity.
7. Phone stores trusted bridge identity.

### Security posture

Tailscale secures the network path.
Pairing secures the product relationship.

Recommended product-level protections:

- Ed25519 long-term identity per bridge
- long-term identity per phone
- ephemeral session keys per connection
- encrypted application channel after handshake
- replay protection
- device approval list on the bridge
- revocation/reset pairing support

### Authorization modes

Support these modes from the start:

- Read-only
- Control with approvals
- Full control

Suggested behavior:

- Read-only: can view threads, streams, plans, terminal output
- Control with approvals: can start/steer/interupt turns, but dangerous operations still require confirmation
- Full control: phone can answer approval prompts directly

## Product-Level API Surface

The phone-facing API should be product-shaped, not Codex-shaped.

Recommended endpoints/messages:

### Session and device

- `POST /pair/complete`
- `GET /device/me`
- `GET /device/status`
- `POST /device/unpair`

### Threads

- `GET /threads`
- `GET /threads/:id`
- `GET /threads/:id/timeline`
- `POST /threads/:id/open-on-mac`

### Turns

- `POST /threads/:id/turns/start`
- `POST /threads/:id/turns/steer`
- `POST /threads/:id/turns/interrupt`

### Live stream

- `WS /stream`
- subscribe to thread IDs
- receive normalized events:
  - thread status
  - message delta
  - plan delta
  - command output delta
  - approval requested
  - item completed

### Approvals

- `GET /approvals`
- `POST /approvals/:id/approve`
- `POST /approvals/:id/reject`

### Optional later surface

- git status
- branch switch
- push/pull
- reopen thread in desktop app

## Flutter App Structure

This should be a proper Flutter app from the start, not a wrapped website.

### Why Flutter is a good fit here

- excellent for long-lived socket sessions
- good control over terminal-like streaming UI
- native camera access for QR pairing
- strong offline caching options
- clean split between transport, state, and UI
- easier to ship polished mobile UX than a website/PWA in this specific use case

### Recommended package choices

- `flutter_riverpod` for state management
- `go_router` for navigation
- `freezed` + `json_serializable` for DTOs
- `web_socket_channel` or a custom socket client
- `mobile_scanner` for QR pairing
- `flutter_secure_storage` for keys/tokens
- `drift` or `isar` for local cache, with `drift` preferred if we want structured querying

### Recommended folder structure

```text
lib/
  app/
    app.dart
    router.dart
    theme/
  core/
    config/
    logging/
    errors/
    utils/
    security/
  data/
    api/
      bridge_client.dart
      socket_client.dart
    dto/
    mappers/
    local/
      app_database.dart
      secure_store.dart
  domain/
    models/
    services/
    repositories/
  features/
    pairing/
      application/
      data/
      presentation/
    devices/
      presentation/
    threads/
      application/
      presentation/
    thread_detail/
      application/
      presentation/
    composer/
      presentation/
    approvals/
      application/
      presentation/
    terminal/
      presentation/
    settings/
      presentation/
  shared/
    widgets/
    formatting/
    icons/
```

### Recommended primary screens

1. Pairing

- QR scanner
- bridge trust confirmation
- saved device list

2. Thread list

- recent threads
- status badges
- project/workspace subtitle
- search and filters

3. Thread detail

- live assistant output
- user prompts
- plan updates
- command output cards
- file/diff summaries

4. Composer

- send new prompt
- steer running turn
- attach image later if needed

5. Approvals

- pending approvals queue
- command/file-change context
- approve/reject

6. Settings

- paired bridge info
- access mode
- reconnect behavior
- notifications
- desktop integration toggles

### UI principles

This app should feel like a real coding tool, not a generic chat app.

Good UI characteristics:

- dense but legible thread list
- excellent monospaced rendering for terminal output
- clear distinction between agent text, plan, shell output, and approvals
- fast reconnect state handling
- obvious active-turn state
- explicit workspace/repo context

## Mac Bridge Project Structure

Recommended bridge stack:

- Swift for the macOS app shell
- Rust or Node.js for the bridge core

Pragmatic recommendation:

- If speed of delivery matters most, use Node.js or TypeScript for the bridge core.
- If we want a more durable native product and tighter macOS integration, use Swift shell + Rust core or Swift + embedded helper.

Given the goal "do it right from the start", the most balanced option is:

- macOS app shell in Swift/SwiftUI
- bridge/runtime adapter in Rust

Why:

- stronger long-lived process behavior
- easier typed protocol handling
- better future portability
- easier to build a stable background daemon/service

That said, TypeScript remains a valid pragmatic choice if we want to optimize for iteration speed.

### Recommended bridge structure

```text
mac-bridge/
  App/
    MenuBarApp/
    PairingUI/
    DeviceManagementUI/
  Core/
    codex_adapter/
    stream_router/
    policy_engine/
    session_store/
    pairing/
    desktop_integration/
    tailscale_integration/
  API/
    websocket_server/
    http_server/
    dto/
  Persistence/
    sqlite/
    keychain/
    logs/
```

### Bridge modules

#### Codex adapter

- spawn/connect `codex app-server`
- track thread and turn state
- normalize upstream notifications
- map product actions to Codex requests

#### Stream router

- multiplex one Codex event stream to one or more mobile clients
- backpressure handling
- reconnect catch-up support

#### Policy engine

- access mode enforcement
- command/file-change approval rules
- read-only restrictions

#### Pairing service

- key management
- QR generation
- trust registry
- revoke/reset pairing

#### Desktop integration

- `codex://` deep-link open
- optional route bounce refresh
- "open thread in Codex.app"

#### Tailscale integration

- detect tailnet address
- prefer localhost binding behind Tailscale Serve if applicable
- expose bridge URL shown in QR

## Tailscale Architecture Decision

### Recommended mode

Use Tailscale from the start.

There are two reasonable ways to do that:

1. Direct tailnet addressing

- Bridge listens on the Mac's Tailscale IP or `localhost` plus a lightweight local forwarder.
- Flutter app connects directly using the tailnet address.

2. Tailscale Serve in front of localhost bridge

- Bridge listens only on `127.0.0.1`
- Tailscale Serve exposes it privately inside the tailnet

Preferred default:

- keep the bridge bound to localhost
- expose it using Tailscale Serve

Why:

- cleaner security boundary
- avoids accidental LAN exposure
- matches Tailscale's own guidance for trusting forwarded identity/capability headers only when backend listens on localhost

Reference:

- <https://tailscale.com/docs/features/tailscale-serve>

### Important caveat

Tailscale does not replace application auth.

Even on a private tailnet, the bridge still needs:

- pairing
- device trust
- permission levels

## Desktop App Integration Strategy

The desktop app should be integrated, but only as a secondary consumer.

### Supported desktop features

- open current thread in `Codex.app`
- optionally refresh route after external updates
- show shared thread history because Codex persists under `~/.codex`

### Unsupported strategy

Do not:

- automate the Electron UI
- scrape the rendered DOM
- control the desktop app window directly as the main product path

That would be brittle and unnecessary.

## What "Done Right From The Start" Means Here

For this project, "done right" means:

- Flutter native app from day one
- product-specific Mac bridge from day one
- QR pairing from day one
- Tailscale from day one
- normalized product API from day one
- `Codex.app` compatibility as a side feature, not the foundation

It does not mean:

- inventing custom NAT traversal
- exposing raw app-server over the public internet
- coupling the phone app to the exact upstream JSON-RPC schema

## Risks and Constraints

### Upstream protocol churn

`codex app-server` is marked experimental.

Implication:

- the bridge must isolate the Flutter app from upstream changes
- do not let the phone app depend directly on raw app-server request/notification shapes

### Desktop live refresh

Current evidence suggests the desktop app does not always live-reload external changes.

Implication:

- desktop refresh must remain optional and loosely coupled

### Long-running mobile connectivity

Phones background and suspend aggressively.

Implication:

- bridge must tolerate reconnects
- phone app must resubscribe cleanly
- event replay/catch-up should be supported

### Security expectations

This app is effectively a remote control for a coding agent on a trusted machine.

Implication:

- permissions must be explicit
- pairing revocation must exist
- audit log should exist
- read-only mode should exist

## Concrete Recommendation

If we are committing to the final shape from the start, the architecture should be:

- Flutter iOS app
- Mac bridge app/daemon
- Tailscale network transport
- QR pairing with bridge and phone identities
- bridge-to-Codex via local `codex app-server`
- optional `Codex.app` open/refresh integration

This is the strongest long-term shape because it is:

- technically aligned with how Codex already works
- local-first
- self-hosted in the meaningful sense
- private by default
- flexible enough to support future Android, iPad, and desktop companion clients

## Sources

Local inspection:

- `/Applications/Codex.app/Contents/Info.plist`
- `/Applications/Codex.app/Contents/Resources/app.asar`
- `/Applications/Codex.app/Contents/Resources/codex`
- `~/.codex/session_index.jsonl`
- `~/.codex/sessions/`
- `~/.codex/state_5.sqlite`
- `~/.codex/logs_1.sqlite`
- `codex --help`
- `codex app-server --help`
- `codex app-server generate-json-schema`

External references:

- Tailscale device connectivity: <https://tailscale.com/kb/1411/device-connectivity>
- Tailscale connection types: <https://tailscale.com/docs/reference/connection-types>
- Tailscale Serve: <https://tailscale.com/docs/features/tailscale-serve>
- Remodex README: <https://raw.githubusercontent.com/Emanuele-web04/remodex/main/README.md>
