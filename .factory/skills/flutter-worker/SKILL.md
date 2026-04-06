---
name: flutter-worker
description: Fix Flutter mobile app transport layer, extract shared utilities, consolidate test helpers, and run static analysis.
---

# Flutter Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for Flutter mobile app fixes including: transport layer improvements (shared `HttpClient`, error differentiation, pagination guards), extracting shared utilities (JSON helpers, URI builders), consolidating integration test helpers into the `support/` directory, and running `flutter analyze` and `flutter test`.

## Required Skills

None.

## Work Procedure

1. Read the mission artifacts and relevant library notes before making changes.
2. Inspect the transport layer in `apps/mobile/lib/foundation/network/`:
   - **Shared HttpClient**: Audit `bridge_transport.dart` and `bridge_transport_io.dart` for ad-hoc `http.Client()` instantiations. Replace them with a single shared `Client` instance that is created once and reused across the transport layer, ensuring proper lifecycle management (close on disconnect).
   - **Error differentiation**: Ensure transport errors map to typed error classes (network unreachable, timeout, HTTP error with status code, WebSocket close reason) instead of raw exceptions. The mobile app must be able to show distinct UI for each category.
   - **Pagination guard**: Inspect timeline/history fetching code for missing `before` cursor validation. Add guards that prevent requesting pages with stale or empty cursors and that cap `limit` to a reasonable maximum (e.g., 100).
3. Extract shared utilities:
   - **JSON helpers**: Look for repeated `jsonDecode` + field-access patterns across the app. Extract a cohesive set of typed JSON accessor helpers (e.g., `getString(json, 'field')`, `getInt(json, 'field')`, `getList(json, 'field')`) into a shared utility file under `apps/mobile/lib/foundation/`.
   - **URI builders**: Look for repeated string-interpolated URL construction. Extract typed URI builder functions for each bridge endpoint (e.g., `threadsUri(base)`, `threadDetailUri(base, id)`, `threadTimelineUri(base, id, before, limit)`) into a shared file.
4. Consolidate integration test helpers:
   - Move any test helper functions that are shared across multiple integration tests into `apps/mobile/integration_test/support/`.
   - Ensure the `support/` directory contains only shared helpers (e.g., `live_codex_turn_wait.dart` is already there).
   - Remove duplicated helper code from individual test files and import from `support/` instead.
5. Run validation:
   - `cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter analyze`
   - `cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter test --concurrency=5`
   - Both commands must exit 0 before marking work complete.
6. Do NOT run integration tests (`flutter drive`). Integration tests are the responsibility of the integration-test-worker.

## Example Handoff

```json
{
  "salientSummary": "Consolidated the Flutter transport layer to use a shared HttpClient, added typed error classes and pagination guards, and extracted JSON helpers and URI builders into shared utility modules.",
  "whatWasImplemented": "Replaced per-call http.Client() with a singleton managed by bridge_transport. Added TransportError hierarchy (NetworkError, TimeoutError, HttpError, WebSocketError). Added cursor and limit validation to timeline pagination. Extracted json_accessor.dart and uri_builders.dart into foundation/. Moved shared test helpers into integration_test/support/.",
  "whatWasLeftUndone": "Live integration tests were not run; that belongs to the integration-test-worker. No changes to UI widgets beyond what was needed for typed error handling.",
  "verification": {
    "commandsRun": [
      {
        "command": "cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter analyze",
        "exitCode": 0,
        "observation": "No analyzer errors or warnings."
      },
      {
        "command": "cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter test --concurrency=5",
        "exitCode": 0,
        "observation": "All unit and widget tests passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Inspected the shared HttpClient lifecycle in bridge_transport_io.dart.",
        "observed": "Client is created once on connect and closed on disconnect. No per-request Client instances remain."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "apps/mobile/test/foundation/network/transport_error_test.dart",
        "cases": [
          {
            "name": "HttpError preserves status code and body",
            "verifies": "Error differentiation carries HTTP status for UI routing."
          },
          {
            "name": "pagination guard rejects empty cursor",
            "verifies": "Pagination guard prevents API calls with stale/empty before cursor."
          }
        ]
      },
      {
        "file": "apps/mobile/test/foundation/json_accessor_test.dart",
        "cases": [
          {
            "name": "getString returns value for present field",
            "verifies": "JSON helper correctly extracts typed values."
          },
          {
            "name": "getString throws typed error for missing field",
            "verifies": "JSON helper produces actionable errors on bad input."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- The transport layer requires bridge API changes that are outside this worker's scope.
- A shared utility extraction would break integration tests that depend on the old code layout (hand off to integration-test-worker).
- `flutter analyze` or `flutter test` failures are caused by environment issues (e.g., missing Flutter SDK, dependency resolution failures) that cannot be resolved by code changes alone.
