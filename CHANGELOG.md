# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.26] - 2026-11-15

### Security

- **The HTTP transport sent every server message to every SSE stream**, so one client could receive another client's notifications, log messages and server-to-client requests (SONNY-6644). Each Streamable HTTP client now has its own session, and messages go only to that client. `Last-Event-ID` replay drew on a buffer shared by all clients and now replays only the session's own events. Tasks were readable, listable and cancellable by any client and now belong to the session that created them (`Task.owner`).

### Fixed

- Streamable HTTP sessions (MCP 2025-11-25 basic/transports). `initialize` without `Mcp-Session-Id` creates a session with a stable random id; previously every response minted a new one. Requests other than `initialize` need the id (`400` without, `404` for an unknown, deleted or expired session). Initialization state, capabilities, request ids, cancellations and server-to-client requests are per session, so clients no longer collide on request ids or cancel each other's requests.
- Server-to-client requests (`requestRoots`, `requestSampling`, `requestElicitation`) work over HTTP. They returned `error.NoSession` because only stdio created a `Session`. Messages sent while handling a POST go on that POST's SSE stream before the response; others go on the session's `GET` stream.
- The `GET` SSE stream was closed as soon as it was registered, so later writes went to a closed and possibly reused descriptor. It now stays open until the client disconnects, the session ends or the server stops, and a new `GET` replaces the old stream.
- HTTP connections were handled one at a time on the accept thread, so a request waiting for its client blocked everyone. Each connection now runs on its own thread (`http_max_connections`, default 64, then `503`), and `stop()` wakes and waits for them.
- The request body was a single 8 KiB read with `Content-Length` ignored. The server now reads the full declared body, up to `max_message_bytes` (`413`) with headers up to 16 KiB (`431`), within `http_request_timeout_ms` (default 30 s, `408`).
- `DELETE` closes the session's stream and fails its pending server-to-client requests. Sessions idle for `http_session_idle_timeout_ms` (default 30 minutes) with no open connection expire.
- Tasks were never freed, and `updateTaskStatus` leaked the result it replaced.
- `createTask` and `getTask` returned a pointer into the task hashmap after releasing its lock, so a later insert could leave the caller with a dangling pointer and a concurrent update raced its reads. They now return owned copies.
- A `SessionRef` released after `Server.deinit` used freed memory. `deinit` now waits for outstanding references (up to `Server.session_ref_wait_ms`, 10 s) and panics with a clear message if one is still held.
- The HTTP acceptance tests returned early (passed) on any connection, write or read error, and read only the first chunk of each response. They now fail on errors and read the whole response, which exposed a T5 failure the early return had hidden.

### Added

- `Server.retainCurrentSession() ?SessionRef`, `SessionRef.id()`/`release()`, and `Server.enterSession(ref) SessionScope` (`scope.exit()`), to reach a client later from any thread.
- `ServerOptions.http_session_idle_timeout_ms`, `http_max_connections`, `http_request_timeout_ms`.

### Changed

- **Breaking:** `Server.createTask` returns `!Task` and `Server.getTask` returns `!?Task`, owned copies the caller frees with `task.deinit(server.allocator)`; they returned `*Task` and `?*Task`.
- **Breaking for HTTP clients:** requests other than `initialize` without `Mcp-Session-Id` get `400` (Streamable HTTP "Session Management"). Session-scoped server messages (`emitLog`, `notifyProgress`, `notifyResourceUpdated`, `Session.notify`/`request`) sent with no session context, or over stdio with no stdout, fail with `error.NoSession` instead of being broadcast or silently dropped.

## [0.1.25] - 2026-11-15

### Fixed

- Duplicate request ids inside one batch were rejected depending on timing: on the worker pool either item could win, and sequentially both ran (SONNY-6644). The batch is now scanned in order before dispatch: the first request with an id runs, and every later request reusing it is answered with `-32600` ("Duplicate request id") and never dispatched. Integer and string ids are distinct; notifications and client responses are not counted.
- An allocation failure part-way through a sequential batch leaked the responses already built.

## [0.1.24] - 2026-11-15

### Fixed

- A client's response to a server-to-client request was answered with `-32600` "Missing method" and never delivered, so `requestRoots`, `requestSampling`, `requestSamplingFull` and `requestElicitation` always timed out (SONNY-6643). `processMessage` now treats a message with no `method` and a `result` or an `error` as a response (MCP 2025-11-25 basic "Responses"): it resolves the pending request and is never answered. Responses to unknown or already answered ids, with a string id, or with both or neither of `result` and `error` are dropped silently. A response that races the timeout is returned instead of leaked.
- `Session.notify`, `Session.request` and the server's notifications (`notifyProgress`, `emitLog`, `notifyResourceUpdated`) inserted caller strings and JSON raw. The method, progress token, log level, logger, message and uri are now JSON-escaped, and `params_json` must be exactly one JSON value; it is sent minified, otherwise `error.InvalidParamsJson` is returned and nothing is sent.
- A second request reusing the id of a request still in flight replaced the first one's registration, so the first could no longer be cancelled. Every request with an id is now tracked while it runs, and a duplicate is answered with `-32600` ("Duplicate request id") without affecting the first.

### Changed

- `Session.request` returns `error.ClientError` when the client answers with a JSON-RPC error, and the result JSON (minified, allocated with the server allocator, owned by the caller) on success.
- Pre-commit hygiene in `GAPS.md`, `SECURITY.md`, `SUPPORT.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md` and the GitLab issue/MR templates (markdownlint, trailing whitespace, end of file): blank lines around headings and lists, `text` on bare code fences, angle-bracketed contact emails, and the `GAPS.md` phase lists numbered from 1 per phase. `pre-commit run --all-files` is now clean.

## [0.1.23] - 2026-11-15

### Fixed

- `error.ToolNotFound` and `error.PromptNotFound` are now answered with `-32602` (Invalid params), as MCP 2025-11-25 server/tools and server/prompts specify; they were `-32002`, the resource-not-found code (SONNY-6585). `error.ResourceNotFound` stays `-32002`.
- The server no longer answers a notification that fails (JSON-RPC 2.0 section 4.1), including inside a batch and before `initialize`. It used to send an error response with a null id.
- `notifications/cancelled` now reaches the running `tools/call` handler: the `CancelToken` passed to `callTool` is registered under the request id, string or integer (`"7"` and `7` are different ids), so `cancel.isCancelled()` becomes true. If the handler then returns `error.Cancelled`, no response is sent (MCP cancellation). A handler that returns `error.Cancelled` for any other reason still gets an error response.
- The error `message` and a string `id` are JSON-escaped in error and success responses. A quote, backslash or control character in either produced invalid JSON; invalid UTF-8 is replaced with U+FFFD.
- A request whose `id` is present but is not a string or an integer (`null`, a boolean, an object, `1.5`) is answered with `-32600` (Invalid Request) and a null id. It was handled as a notification, and an unparseable number became id `0`.
- **Removed the built-in "barrier" test tool from the dispatcher.** `tools/call` with `name: "barrier"` was answered by the library itself: it shadowed a handler tool of that name, and any client could make it wait forever with a large `count` (blocking a stdio server). The parallelism acceptance test now defines its own barrier tool; `DemoHandler`'s tool is renamed `echo`.
- A successful handler result is validated and re-serialised without insignificant whitespace, so a pretty-printed result no longer puts raw newlines into a newline-delimited stdio message. A result that is not exactly one JSON value is answered with `-32603` ("Invalid handler result") instead of a malformed response.
- `client_protocol_version` pointed into the parsed `initialize` message, which is freed when the request completes; it is now a server-owned copy. The `experimental` client capabilities JSON leaked on every `initialize` and is now freed.
- `requestElicitation` (message, and the url in url mode) and `requestSamplingFull` (`systemPrompt`, `stopSequences`, `toolChoice`, `includeContext`) escape every control character, not only `\n`, `\r` and `\t`; the url was not escaped at all.
- `Session.request` did not compile (`waitTimeout` was passed an `Io.Duration` instead of an `Io.Clock.Duration`), so any program that called `requestSampling`, `requestSamplingFull`, `requestRoots` or `requestElicitation` failed to build.
- The CI `fuzz` job ran `zig build test --fuzz`, which found no fuzz tests (and, once one exists, the Zig 0.16.0 std test runner does not compile in fuzz mode), so it failed on every run behind `allow_failure`. It now runs the mutation fuzzer over a new `dispatch` target (real `processMessage` round trips: valid single-line JSON, notifications unanswered, no leaks) and the `jsonrpc` target, and fails on a violation. The same property runs over a corpus in `zig build test` (`tests/fuzz_dispatch.zig`). `zig build fuzz` with an unknown `--target` now exits non-zero.

### Added

- `setErrorDetail(allocator, message, data_json)`: a handler sets the JSON-RPC error `message` and `data` for the error it returns, for example `"Unknown tool: X"` or `{"uri": ...}`. The server frees the detail. `data_json` must be one JSON value, otherwise `error.InvalidErrorData`.
- `CancelToken.isCancelledByPeer()`: true when the client cancelled the request, as opposed to a server-side timeout.

## [0.1.22] - 2026-11-14

### Fixed

- The server now frees the result of every handler callback, not only `tools/call` (SONNY-6531). `resources/read`, `resources/list`, `resources/templates/list`, `tools/list`, `prompts/list`, `prompts/get` and `completion/complete` results were dispatched as not owned, so every heap-allocated response leaked for the life of a long-running server. Results are freed with `Server.allocator` after the response is built, for notifications, and when building the response fails (that last path also leaked `tools/call` results).
- `prompts/get` with `arguments` and every `completion/complete` request leaked the JSON the server serialized to pass to the handler; it is now freed after the call.
- The examples (01, 02, 03, 05, 07) returned string literals from `callTool`, which the server has freed since v0.1.12 (an invalid free on the first `tools/call`); every example callback now returns a copy made with the server's allocator.

### Changed

- **BREAKING for handler authors:** every `Handler` callback that returns `[]const u8` (`listTools`, `callTool`, `listResources`, `readResource`, `listResourceTemplates`, `listPrompts`, `getPrompt`, `complete`) transfers ownership of the slice to the server, which frees it with the allocator passed to `Server.init`. Returning a string literal, a slice the handler keeps, or bytes from another allocator is now an invalid free. Migrate by returning `allocator.dupe(u8, text)` for fixed text. A callback that returns an error hands nothing over. The contract is documented on `Handler` ("Result Ownership"), in README.md and docs/api.md. `DemoHandler` and `cmd/mcp-server` follow it.

## [0.1.21] - 2026-10-12

### Changed

- CI: scope the gitleaks exceptions for the public OpenSSL release signers and add a regression script that keeps negative controls blocked (SONNY-4910); cancel obsolete branch pipelines (SONNY-4907).

## [0.1.20] - 2026-10-12

### Changed

- Bump otel to v0.1.28 (verified TLS dependency closure).

## [0.1.19] - 2026-10-12

### Changed

- Bump otel to v0.1.27.

## [0.1.18] - 2026-10-12

### Changed

- Update dependencies: json v0.1.20, thread_pool v0.2.9, otel v0.1.26, and the lazy fips v0.1.3 backend.
- `DemoHandler` carries its allocator per instance through `Handler.ctx` instead of a package-level global.

## [0.1.17] - 2026-09-19

### Changed

- Bump otel to v0.1.24 (GAP-0838 diamond sync).

## [0.1.16] - 2026-09-19

### Changed

- Bump otel to v0.1.21 (GAP-0838 diamond sync).

## [0.1.15] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

## [0.1.14] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.1.13] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.12] - 2026-08-29

### Fixed
- `tools/call` results are now freed by the server (`Server.allocator`) after the JSON-RPC response is built, fixing a server-lifetime memory leak — every dynamically allocated tool response previously went unfreed. **Breaking behavior change:** `Handler.callTool` implementations MUST return allocator-owned bytes (e.g. via `allocator.dupe`); returning a static/comptime string literal will now be invalid-freed. `tools/list`, `resources/*`, `prompts/*`, and `completion/complete` are unaffected and still treated as possibly-static.

## [0.1.0] - 2026-01-24

Initial open source release of the MCP Server Library for Zig.

### Added
- Merge request template for contributions
- Issue templates for bug reports, features, and questions
- **Core Protocol Support**
  - JSON-RPC 2.0 with single and batch message support
  - String and integer ID support
  - MCP spec revision 2025-03-26 compliance

- **Transports**
  - stdio transport with newline-delimited messages
  - Streamable HTTP transport with Server-Sent Events (SSE)

- **Authentication**
  - Bearer token authentication
  - Basic authentication
  - OAuth2.1 with embedded endpoints
  - OAuth2 well-known endpoint for client autodiscovery
  - Dynamic Client Registration (DCR) support

- **Server Features**
  - Worker thread pool with configurable thread count
  - Request cancellation support via CancelToken
  - Parallel request handling with deterministic testing
  - Barrier tool for proving parallelism without timing dependencies

- **MCP Methods**
  - Lifecycle: `initialize`, `notifications/initialized`, `ping`, `notifications/cancelled`, `notifications/progress`
  - Tools: `tools/list` (with cursor pagination), `tools/call`
  - Resources: `resources/list`, `resources/read`, `resources/templates/list`, `resources/subscribe`
  - Tasks: `tasks/get`, `tasks/list` (cursor + limit pagination), `tasks/cancel`, `tasks/result`
  - Prompts: `prompts/list`, `prompts/get`
  - Logging: `logging/setLevel`, `notifications/message`
  - Completion: `completion/complete` (ref/prompt + ref/resource)

- **Testing**
  - Comprehensive acceptance test suite
  - Deterministic parallelism tests using barrier synchronization

- **CI/CD**
  - GitLab CI integration with devnw/ci-catalog components
  - Advanced SAST and Dependency Scanning
  - GitLab native Secret Detection
  - SBOM generation
  - Coverage support

- **Platform Support**
  - Zig 0.15.2+ compatibility
  - Windows cross-platform compatibility
  - Linux and macOS support

### Fixed
- Server `stop()` method now reliably unblocks `accept()`
- Windows args compatibility in fuzz testing
- PowerShell variable expansion in Windows CI builds
- Zig 0.15 `std.Io.Reader` interface compatibility

### Changed
- Updated CI catalog components to v1.7.1
- Updated json dependency to use GitLab archive URL

### Security
- Gitleaks allowlist configuration for test data
- Apache-2.0 open source licensing

[Unreleased]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.26...HEAD
[0.1.26]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.25...v0.1.26
[0.1.25]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.24...v0.1.25
[0.1.24]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.23...v0.1.24
[0.1.23]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.22...v0.1.23
[0.1.22]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.21...v0.1.22
[0.1.21]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.20...v0.1.21
[0.1.20]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.19...v0.1.20
[0.1.19]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.18...v0.1.19
[0.1.18]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.17...v0.1.18
[0.1.17]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.16...v0.1.17
[0.1.16]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.15...v0.1.16
[0.1.15]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.14...v0.1.15
[0.1.14]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.13...v0.1.14
[0.1.13]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.12...v0.1.13
[0.1.12]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.0...v0.1.12
[0.1.0]: https://gitlab.com/devnw/zig/mcp/-/releases/v0.1.0
