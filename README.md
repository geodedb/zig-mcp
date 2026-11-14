# mcp - MCP Server Library for Zig

A Zig 0.15.2 implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) spec revision 2025-03-26.

## Status

| Aspect | Info |
|--------|------|
| API Stability | Beta |
| Zig Version | 0.15.2+ |
| Platforms | Linux, macOS, Windows |

## Features

- **JSON-RPC 2.0** - Single and batch message support, string/integer IDs
- **Transports** - stdio (newline-delimited) and Streamable HTTP with SSE
- **Authentication** - Bearer, Basic, and OAuth2.1 with embedded endpoints
- **Parallel Handling** - Worker thread pool with cancellation support
- **Deterministic Testing** - Barrier tool for proving parallelism without timing

## Protocol Version

```text
2025-03-26
```

## Requirements

- Zig 0.15.2+
- Local `../json` dependency (RFC 8259 JSON parser)

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .mcp = .{
        .path = "../mcp", // or URL to tarball
    },
},
```

In `build.zig`:

```zig
const mcp_dep = b.dependency("mcp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

## Quick Start

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try mcp.Server.init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
        .worker_threads = 4,
    }, MyHandler.create());
    defer server.deinit();

    // stdio transport
    try server.serveStdio();

    // or HTTP transport
    // const port = try server.serveHttp();
}
```

## Public API

```zig
pub const ProtocolVersion = "2025-03-26";

pub const AuthMode = enum { none, bearer, basic, oauth2 };

pub const ServerOptions = struct {
    name: []const u8,
    version: []const u8,
    instructions: ?[]const u8 = null,
    worker_threads: u16 = 0,
    max_message_bytes: usize = 8 * 1024 * 1024,
    max_batch_items: u32 = 256,
    max_inflight: u32 = 1024,
    http_bind: []const u8 = "127.0.0.1",
    http_port: u16 = 0,
    http_path: []const u8 = "/mcp",
    http_allow_origin: ?[]const u8 = null,
    auth_mode: AuthMode = .none,
    bearer_token: ?[]const u8 = null,
    basic_user: ?[]const u8 = null,
    basic_pass: ?[]const u8 = null,
};

pub const CancelToken = struct {
    pub fn isCancelled(self: *const CancelToken) bool;
};

pub const Session = struct {
    pub fn notify(self: *Session, method: []const u8, params_json: ?[]const u8) anyerror!void;
    pub fn request(self: *Session, method: []const u8, params_json: ?[]const u8, timeout_ms: u32) anyerror![]const u8;
};

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    listTools: *const fn(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    callTool: *const fn(ctx: ?*anyopaque, name: []const u8, args_json: []const u8, cancel: *const CancelToken) anyerror![]const u8,
    listResources: *const fn(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    readResource: *const fn(ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8,
    listResourceTemplates: *const fn(ctx: ?*anyopaque) anyerror![]const u8,
    subscribeResource: *const fn(ctx: ?*anyopaque, uri: []const u8) anyerror!void,
    listPrompts: *const fn(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    getPrompt: *const fn(ctx: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8,
    complete: *const fn(ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8,
    setLogLevel: *const fn(ctx: ?*anyopaque, level: []const u8) anyerror!void,
};

pub const Server = struct {
    pub fn init(a: std.mem.Allocator, opt: ServerOptions, h: Handler) anyerror!Server;
    pub fn deinit(self: *Server) void;
    pub fn serveStdio(self: *Server) anyerror!void;
    pub fn serveHttp(self: *Server) anyerror!u16;
    pub fn stop(self: *Server) void;
};
```

### Handler result ownership

Every `Handler` callback that returns `[]const u8` (`listTools`, `callTool`,
`listResources`, `readResource`, `listResourceTemplates`, `listPrompts`,
`getPrompt`, `complete`) hands the slice to the server, which frees it with
the allocator passed to `Server.init` after the response is built (also for
notifications and when building the response fails). Return bytes allocated
with that allocator, never a string literal or a slice the handler keeps:
`return allocator.dupe(u8, "{\"tools\":[]}");`. A callback that returns an
error hands nothing over. Versions 0.1.12 to 0.1.21 freed only `callTool`
results (and leaked the others); see CHANGELOG.md.

## Testing

```bash
# Run all tests
zig build test

# Run acceptance tests only
zig build test-accept
```

### Acceptance Tests

| Test | Description |
|------|-------------|
| T1 | stdio init+initialized+ping => correct responses |
| T2 | stdio batch of 2 pings => ordered batch response |
| T3 | stdio batch of 2 barrier calls => proves parallelism |
| T4 | HTTP bearer: 401 without auth, 200 with token + session ID |
| T5 | HTTP oauth2: well-known endpoint returns metadata |

## MCP Methods Supported

### Lifecycle

- `initialize` / `notifications/initialized`
- `ping`
- `notifications/cancelled`
- `notifications/progress`

### Tools

- `tools/list` (with cursor pagination)
- `tools/call`

### Resources

- `resources/list`
- `resources/read`

### Tasks

- `tasks/get`
- `tasks/list` (cursor + limit pagination; returns `nextCursor` when more results are available)
- `tasks/cancel`
- `tasks/result`
- `resources/templates/list`
- `resources/subscribe`

### Prompts

- `prompts/list`
- `prompts/get`

### Logging

- `logging/setLevel`
- `notifications/message`

### Completion

- `completion/complete` (ref/prompt + ref/resource, ≤100 results)

## Authentication

### Bearer Token

```zig
.auth_mode = .bearer,
.bearer_token = "my-secret-token",
```

### Basic Auth

```zig
.auth_mode = .basic,
.basic_user = "admin",
.basic_pass = "password",
```

### OAuth2.1

```zig
.auth_mode = .oauth2,
```

Provides endpoints:

- `/.well-known/oauth-authorization-server`
- `/mcp/authorize`
- `/mcp/token`
- `/mcp/register`

## Observability

Optional OpenTelemetry instrumentation for MCP request/response paths.
Off by default — when `-Dwith_otel=false` (the default), the otel
dependency is never fetched and the produced artifacts contain zero
otel/observability symbols (verified by `verify-consumer-noop.sh` from
the otel toolchain).

### Build flag

```bash
zig build -Dwith_otel=true                # compile with otel
zig build test -Dwith_otel=true           # run smoke test
zig build                                 # default = disabled, zero overhead
```

### Spans emitted

Both client (outgoing) and server (incoming) JSON-RPC paths produce
spans with otel `rpc.*` semantic conventions:

- `rpc.system = "mcp"`
- `rpc.method = "<json-rpc method>"` (e.g. `"tools/call"`,
  `"resources/list"`)
- span kind: `.client` for outbound `Session.request`, `.server` for
  inbound `Server.processJsonValue`
- on JSON-RPC errors, `rpc.jsonrpc.error_code` is attached and span
  status is set to `error`

### Bootstrap

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var otel = try mcp.observability_init.Otel.init(allocator, "my-service");
    defer otel.deinit();
    otel.installGlobals();
    // ... your MCP server / client ...
}
```

`OTEL_*` env vars (e.g. `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_TRACES_SAMPLER`) are honoured by the bootstrap helper. Telemetry
is non-fatal: a failing exporter never breaks MCP traffic.

For full integration details see the otel rollout recipe at
`devnw/zig/otel/docs/integration/RECIPE.md`.

## License

Apache-2.0 License - see [LICENSE](LICENSE) for details.

## Rationale

- Single-file design minimizes module complexity for MCP server use case
- Handler callbacks return JSON strings for zero-copy response embedding
- Barrier tool uses atomics for deterministic parallelism proof without timing
- OAuth2.1 metadata endpoint enables client autodiscovery
- SSE connections tracked per session for server→client messaging
- Thread pool workers check shutdown flag at 1ms intervals for responsive stop
- Batch processing preserves response order via sequential ArrayList append
