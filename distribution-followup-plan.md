# Distribution Follow-Up Plan

## Why this follow-up exists

## Current implementation status

Implemented in this follow-up slice:

- macOS shell now attempts to own bridge startup instead of only polling an already-running bridge
- shell surfaces explicit startup, attached, managed, and failed supervision states
- shell can restart a locally managed bridge from the menu bar UI
- shell reports actionable helper-binary discovery failures for `bridge-server`
- macOS Xcode builds now embed `bridge-server` into the desktop app bundle

Still open:

- host-installed Codex runtime discovery and launch UX for end users
- Linux desktop shell/runtime-owner implementation
- distribution artifact validation for fresh end-user installs

The current implementation is developer-oriented:

- `codex app-server` is started manually
- the Rust bridge is started manually
- the macOS shell acts as a companion UI/supervisor, not the owner of the full local runtime

That was acceptable for local-first development and validation, but it is not the right end-state for a product that should be shareable from GitHub as "download desktop app + mobile app and use it".

## Product direction

- Desktop app owns the local runtime
- Mobile app remains a paired companion
- Initial distributable desktop targets: macOS and Linux
- Users should not need to run `cargo`, `codex app-server`, or other manual terminal commands

## End-state goals

### User experience

1. User downloads the desktop app.
2. User launches the desktop app.
3. The desktop app starts and supervises the required local runtime automatically.
4. User opens the mobile app.
5. User pairs mobile with desktop.
6. Threads, approvals, git actions, and settings work without manual CLI setup.

### Runtime ownership

The desktop app should own:

- launching the Codex runtime
- launching the bridge runtime
- health monitoring and restart behavior
- user-facing status/errors for startup failures
- duplicate-instance and port-conflict handling
- clean shutdown and restart behavior

## Scope change from current architecture

### Current architecture

- `codex app-server` is an external prerequisite
- `bridge-server` is an external prerequisite
- desktop shell connects to an already-running local stack

### Target architecture

- desktop app launches and supervises the local stack itself
- desktop app becomes the primary local orchestrator for runtime lifecycle
- mobile app depends on the desktop-owned bridge, not on a manually prepared developer machine

## Major workstreams

### 1. Desktop runtime supervisor

Build a real runtime manager inside the desktop app that can:

- locate required binaries/assets
- start `codex app-server`
- start the bridge with the correct configuration
- stream logs/status into the desktop UI
- detect crash/exit conditions
- retry or recover when safe
- surface actionable errors when startup fails

### 2. Packaging and binary strategy

Define how the product is shipped so end users do not need Rust or a source checkout.

Decisions needed:

- whether the bridge is bundled as a prebuilt binary
- how the desktop app discovers and launches a host-installed `codex app-server`
- where runtime assets live inside distributable app packages
- how updates/version compatibility are handled

Current decision:

- `bridge-server` is bundled into the desktop app
- `codex app-server` is not bundled into the desktop app
- the desktop app launches a host-installed `codex` binary and should surface a clear first-run error when it is missing

### 3. Cross-platform desktop strategy

macOS and Linux are now in scope, so the desktop layer needs a real platform plan.

Options to evaluate:

- keep SwiftUI for macOS and build a separate Linux desktop shell
- replace the current shell with a cross-platform desktop shell
- keep a shared runtime supervisor core and thin platform-specific shells

This is a product-level architecture decision and should be made deliberately before large implementation work.

### 4. Install and first-run flow

The desktop app should provide a truthful first-run experience:

- dependency checks
- clear missing-runtime errors
- one-click runtime startup
- pairing readiness only when the stack is actually healthy
- user-facing recovery guidance when startup fails

### 5. Validation and distribution closure

Add validation for the real shipped experience:

- fresh desktop install
- desktop-launched runtime only
- no manual terminal setup
- mobile pairing against the desktop-owned stack
- macOS and Linux packaging/build verification

## Suggested milestones

### Milestone A: Runtime ownership on macOS

- macOS app starts Codex runtime and bridge automatically
- desktop UI shows startup, healthy, degraded, and failed states
- mobile pairing works without manual terminal commands

### Milestone B: Packaging and installability

- distributable macOS build includes or correctly discovers required runtime pieces
- documented install/start flow matches real user experience
- first-run validation proves no developer-only steps are required

### Milestone C: Linux desktop strategy

- choose Linux shell architecture
- implement Linux desktop launcher/supervisor
- validate paired mobile flow against Linux-owned runtime

### Milestone D: End-user release readiness

- macOS and Linux distribution artifacts
- stable runtime restart/recovery behavior
- final user testing for download → launch → pair → use flow

## Non-goals for this follow-up

- standalone mobile operation without a paired desktop
- hosted/cloud backend as the primary runtime model
- requiring users to build Rust code manually from source

## Key risks

- locating a compatible host-installed Codex runtime may be more complex than bundling the bridge
- Linux desktop support may require a different UI technology than the current macOS shell
- process supervision from a packaged desktop app is substantially more complex than current developer-mode startup
- distribution/security rules may differ by platform for embedded helpers and child processes

## Acceptance criteria

This follow-up should only be considered complete when all of the following are true:

1. A user can launch the desktop app without starting terminal commands manually.
2. The desktop app starts and supervises the local runtime itself.
3. The mobile app can pair and operate against the desktop-owned runtime.
4. macOS and Linux distribution strategy is implemented or concretely closed.
5. Validation covers the real end-user flow, not only developer-mode local runs.

## Recommended next decision

Before implementation, choose the desktop-platform architecture for macOS + Linux:

- platform-specific shells with shared runtime core
- or a single cross-platform desktop shell

That decision will strongly affect how the next mission should be decomposed.
