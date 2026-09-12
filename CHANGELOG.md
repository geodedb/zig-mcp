# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.14] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.1.13] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

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

[Unreleased]: https://gitlab.com/devnw/zig/mcp/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/mcp/-/releases/v0.1.0
