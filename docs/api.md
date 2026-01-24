# MCP Zig Library API Documentation

A comprehensive Model Context Protocol (MCP) implementation in Zig, supporting the 2025-11-25 specification.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Server API](#server-api)
- [Transport Layer](#transport-layer)
- [JSON-RPC](#json-rpc)
- [Logging](#logging)
- [TLS Support](#tls-support)
- [Zero-Copy Parsing](#zero-copy-parsing)
- [Request Pipelining](#request-pipelining)
- [Metrics](#metrics)
- [CLI Tools](#cli-tools)

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .mcp = .{
        .path = "../mcp",
    },
},
```

In your `build.zig`:

```zig
const mcp = b.dependency("mcp", .{});
exe.root_module.addImport("mcp", mcp.module("mcp"));
```

## Quick Start

### Creating an MCP Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create handler
    const handler = mcp.Handler{
        .listTools = myListTools,
        .callTool = myCallTool,
        // ... other handlers
    };

    // Create server
    var server = try mcp.Server.init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
    }, handler);
    defer server.deinit();

    // Start serving via stdio
    try server.serveStdio();
}
```

## Server API

### Server Configuration

```zig
pub const ServerOptions = struct {
    /// Server name
    name: []const u8,
    /// Server version
    version: []const u8,
    /// HTTP bind address (for HTTP transport)
    http_bind: []const u8 = "127.0.0.1",
    /// HTTP port (0 for auto-assign)
    http_port: u16 = 0,
    /// Enable request logging
    enable_logging: bool = true,
    /// Maximum concurrent connections
    max_connections: u32 = 100,
};
```

### Handler Interface

```zig
pub const Handler = struct {
    /// Context pointer passed to all handlers
    context: ?*anyopaque = null,

    /// List available tools
    listTools: ?*const fn (?*anyopaque, ?[]const u8) anyerror![]const u8 = null,

    /// Call a tool
    callTool: ?*const fn (
        ?*anyopaque,
        name: []const u8,
        arguments: []const u8,
        cancel: *const CancelToken,
    ) anyerror![]const u8 = null,

    /// List resources
    listResources: ?*const fn (?*anyopaque, ?[]const u8) anyerror![]const u8 = null,

    /// Read a resource
    readResource: ?*const fn (?*anyopaque, uri: []const u8) anyerror![]const u8 = null,

    /// List resource templates
    listResourceTemplates: ?*const fn (?*anyopaque) anyerror![]const u8 = null,

    /// Subscribe to resource updates
    subscribeResource: ?*const fn (?*anyopaque, uri: []const u8) anyerror!void = null,

    /// Unsubscribe from resource updates
    unsubscribeResource: ?*const fn (?*anyopaque, uri: []const u8) anyerror!void = null,

    /// List prompts
    listPrompts: ?*const fn (?*anyopaque, ?[]const u8) anyerror![]const u8 = null,

    /// Get a prompt
    getPrompt: ?*const fn (
        ?*anyopaque,
        name: []const u8,
        arguments: ?[]const u8,
    ) anyerror![]const u8 = null,

    /// Complete text
    complete: ?*const fn (?*anyopaque, text: []const u8) anyerror![]const u8 = null,

    /// Set log level
    setLogLevel: ?*const fn (?*anyopaque, level: []const u8) anyerror!void = null,
};
```

### Server Methods

```zig
/// Initialize server
pub fn init(allocator: Allocator, options: ServerOptions, handler: Handler) !Server

/// Deinitialize server
pub fn deinit(self: *Server) void

/// Serve via stdio transport
pub fn serveStdio(self: *Server) !void

/// Serve via HTTP transport (returns actual port)
pub fn serveHttp(self: *Server) !u16

/// Send notification to client
pub fn notify(self: *Server, method: []const u8, params: []const u8) !void

/// Get server capabilities
pub fn getCapabilities(self: *Server) Capabilities
```

## Transport Layer

### Stdio Transport

```zig
const transport = try mcp.StdioTransport.init(allocator);
defer transport.deinit();

// Read message
const msg = try transport.read();
defer allocator.free(msg);

// Write message
try transport.write(response);
```

### HTTP Transport

```zig
const http = try mcp.HttpTransport.init(allocator, .{
    .bind_address = "0.0.0.0",
    .port = 8080,
});
defer http.deinit();

// Start server
const port = try http.start();
```

### WebSocket Transport

```zig
const ws = try mcp.WebSocketTransport.init(allocator, stream);
defer ws.deinit();

// Read frame
const frame = try ws.readFrame();

// Write text
try ws.writeText("message");
```

## JSON-RPC

### Request Structure

```zig
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId = null,
    method: []const u8,
    params: ?json.Value = null,
};
```

### Response Structure

```zig
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId = null,
    result: ?json.Value = null,
    @"error": ?Error = null,
};
```

### Error Codes

```zig
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    // MCP-specific
    request_cancelled = -32800,
    content_too_large = -32801,
};
```

## Logging

### Logger Configuration

```zig
const log = @import("log");

// Initialize global logger
log.initGlobal(allocator, "my-app", .{
    .level = .info,
    .format = .text,  // or .json, .compact
    .color = true,
    .timestamps = true,
});

// Log messages
log.info("Server started on port {d}", .{port});
log.debug("Processing request {s}", .{request_id});
log.err("Connection failed: {}", .{err});
```

### Log Levels

```zig
pub const Level = enum(u8) {
    trace = 0,  // Extremely detailed
    debug = 1,  // Debug information
    info = 2,   // Informational
    warn = 3,   // Warning conditions
    err = 4,    // Error conditions
    fatal = 5,  // Fatal errors
};
```

### Structured Logging

```zig
logger.logWithFields(.info, "Request handled", .{}, &.{
    log.str("method", "tools/call"),
    log.int("duration_ms", 42),
    log.boolean("success", true),
});
```

## TLS Support

### Server TLS Configuration

```zig
const tls = @import("tls");

const config = tls.TlsServerConfig{
    .cert_file = "/path/to/cert.pem",
    .key_file = "/path/to/key.pem",
    .min_version = .tls_1_2,
    .client_auth = .none,
};

var listener = try tls.TlsListener.init(allocator, address, config);
defer listener.deinit();

const conn = try listener.accept();
```

### Client TLS Configuration

```zig
const config = tls.TlsClientConfig{
    .ca_file = "/path/to/ca.pem",
    .server_name = "example.com",
    .insecure_skip_verify = false,  // Only for testing!
};

var stream = try tls.TlsStream.initClient(allocator, tcp_stream, config);
defer stream.deinit();
```

## Zero-Copy Parsing

### ZeroCopyValue

```zig
const zero_copy = @import("zero_copy");

// Parse JSON document
var doc = try json.parse(allocator, data, .{}, &err_info);
defer doc.deinit();

// Wrap for zero-copy access
const value = zero_copy.ZeroCopyValue.wrap(doc.root);

// Access without allocations
if (value.get("method")) |method| {
    if (method.asString()) |s| {
        // s is a slice into original buffer
    }
}

// Path-based access
if (value.getPath(&.{ "params", "name" })) |name| {
    // ...
}
```

### Value Accessors

```zig
// String access
pub fn asString(self: ZeroCopyValue) ?[]const u8

// Numeric access
pub fn asInt(self: ZeroCopyValue, comptime T: type) ?T
pub fn asFloat(self: ZeroCopyValue, comptime T: type) ?T

// Boolean access
pub fn asBool(self: ZeroCopyValue) ?bool

// Array iteration
pub fn arrayIterator(self: ZeroCopyValue) ?ArrayIterator

// Object iteration
pub fn objectIterator(self: ZeroCopyValue) ?ObjectIterator
```

## Request Pipelining

### Pipeline Usage

```zig
const pipelining = @import("pipelining");

var pipeline = pipelining.Pipeline.init(allocator);
defer pipeline.deinit();

// Queue requests
const id1 = try pipeline.queueRequest(.POST, "/mcp", headers, body);
const id2 = try pipeline.queueRequest(.POST, "/mcp", headers, body);

// Send requests
while (pipeline.getNextToSend()) |req| {
    try pipeline.serializeRequest(req, writer);
    pipeline.markSent(req.id);
}

// Handle responses
try pipeline.completeRequest(id1, 200, resp_headers, resp_body);
```

### Pipeline Statistics

```zig
const stats = pipeline.getStats();
std.debug.print("Total: {d}, Pending: {d}, Success: {d}\n", .{
    stats.total_requests,
    stats.pending_requests,
    stats.successful_requests,
});
```

## Metrics

### Counter

```zig
const metrics = @import("metrics");

const requests = metrics.Counter.init("mcp_requests_total", "Total MCP requests");
requests.inc();
requests.add(5);
```

### Gauge

```zig
const connections = metrics.Gauge.init("mcp_connections", "Active connections");
connections.set(42);
connections.inc();
connections.dec();
```

### Histogram

```zig
const latency = metrics.Histogram.init(
    "mcp_request_duration_seconds",
    "Request latency",
    &.{ 0.001, 0.01, 0.1, 1.0 },
);
latency.observe(0.042);
```

### Prometheus Export

```zig
var collector = metrics.MetricsCollector.init(allocator);
defer collector.deinit();

try collector.register(&requests.metric);
try collector.register(&connections.metric);

const output = try collector.export(.prometheus);
```

## CLI Tools

### mcp-server

MCP server runner with configurable transports.

```bash
# Stdio transport (default)
mcp-server --stdio --name my-server

# HTTP transport
mcp-server --http --port 8080 --host 0.0.0.0

# With verbose logging
mcp-server --verbose
```

### mcp-inspect

Protocol message inspector for debugging.

```bash
# Read from stdin
cat messages.jsonl | mcp-inspect

# Read from file with filtering
mcp-inspect --file log.jsonl --filter request

# Compact output
mcp-inspect --format compact
```

### mcp-client

Interactive test client for MCP servers.

```bash
# Interactive mode
mcp-client

# Single command
mcp-client init
mcp-client tools
mcp-client call echo '{"message":"hello"}'

# HTTP transport
mcp-client --http http://localhost:8080/mcp
```

## Error Handling

All functions that can fail return error unions. Common error types:

```zig
pub const Error = error{
    OutOfMemory,
    InvalidJson,
    InvalidRequest,
    MethodNotFound,
    InternalError,
    TransportError,
    ConnectionClosed,
    Timeout,
    TlsError,
};
```

Example error handling:

```zig
server.handleRequest(request) catch |err| {
    switch (err) {
        error.InvalidRequest => {
            // Handle invalid request
        },
        error.Timeout => {
            // Handle timeout
        },
        else => {
            log.err("Unexpected error: {}", .{err});
        },
    }
};
```

## Thread Safety

- `Server` is thread-safe for concurrent request handling
- `Pipeline` uses internal mutex for thread-safe operations
- `Logger` is thread-safe for concurrent logging
- `MetricsCollector` is thread-safe for concurrent metric updates

## Memory Management

The library uses Zig's allocator pattern throughout:

```zig
// Use arena for request-scoped allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

// Process request with arena allocator
const result = try processRequest(arena.allocator(), request);
```

## Performance Considerations

1. **Zero-copy parsing**: Use `ZeroCopyValue` to avoid string allocations
2. **Arena allocators**: Use for request-scoped memory
3. **Connection pooling**: Reuse HTTP connections with keep-alive
4. **Request pipelining**: Send multiple requests without waiting

## Version Compatibility

- MCP Protocol: 2025-11-25
- Zig: 0.15.x
- TLS: 1.2 and 1.3
