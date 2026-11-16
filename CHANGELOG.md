# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.23] - 2026-11-15

### Fixed

- `error.ToolNotFound` and `error.PromptNotFound` are now answered with `-32602` (Invalid params), as MCP 2025-11-25 server/tools and server/prompts specify; they were `-32002`, the resource-not-found code (SONNY-6585). `error.ResourceNotFound` stays `-32002`.
- The server no longer answers a notification that fails (JSON-RPC 2.0 section 4.1), including inside a batch and before `initialize`. It used to send an error response with a null id.
- `notifications/cancelled` now reaches the running `tools/call` handler: the `CancelToken` passed to `callTool` is registered under the request's integer id, so `cancel.isCancelled()` becomes true. If the handler then returns `error.Cancelled`, no response is sent (MCP cancellation). A handler that returns `error.Cancelled` for any other reason still gets an error response.
- The error `message` and a string `id` are JSON-escaped in error and success responses. A quote, backslash or control character in either produced invalid JSON; invalid UTF-8 is replaced with U+FFFD.
- A request whose `id` is present but is not a string or an integer (`null`, a boolean, an object, `1.5`) is answered with `-32600` (Invalid Request) and a null id. It was handled as a notification, and an unparseable number became id `0`.

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

[Unreleased]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.23...HEAD
[0.1.23]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.22...v0.1.23
[0.1.14]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.13...v0.1.14
[0.1.13]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.12...v0.1.13
[0.1.12]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.0...v0.1.12
[0.1.0]: https://gitlab.com/devnw/zig/mcp/-/releases/v0.1.0
