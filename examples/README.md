# MCP Library Examples

This directory contains practical examples demonstrating how to use the MCP (Model Context Protocol) library for Zig.

## Examples Overview

| Example | Description |
|---------|-------------|
| [01_basic_server.zig](01_basic_server.zig) | Minimal MCP server with a simple echo tool |
| [02_http_server.zig](02_http_server.zig) | HTTP transport with SSE support |
| [03_tool_registration.zig](03_tool_registration.zig) | Advanced tool registration with state and cancellation |
| [04_resources_and_prompts.zig](04_resources_and_prompts.zig) | Resources, templates, and prompt handling |
| [05_authentication.zig](05_authentication.zig) | Bearer, Basic, and OAuth 2.1 authentication |
| [06_client_example.zig](06_client_example.zig) | Building MCP client requests |
| [07_notifications.zig](07_notifications.zig) | Server-to-client notifications |

> **Handler result ownership:** the server frees every slice a handler callback returns (`listTools`, `callTool`, `listResources`, `readResource`, `listResourceTemplates`, `listPrompts`, `getPrompt`, `complete`) with the allocator passed to `Server.init`. Callbacks MUST return bytes allocated with that allocator (e.g. `allocator.dupe(u8, ...)`); returning a static string literal is an invalid free. The examples return fixed text through a small `owned()` helper that copies it with the server's allocator.

## Building the Examples

Add the examples to your `build.zig`:

```zig
// In your build.zig, add example build targets
const example_names = [_][]const u8{
    "01_basic_server",
    "02_http_server",
    "03_tool_registration",
    "04_resources_and_prompts",
    "05_authentication",
    "06_client_example",
    "07_notifications",
};

for (example_names) |name| {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
            },
        }),
    });
    b.installArtifact(example);
}
```

Then build with:

```bash
zig build
```

## Running Examples

### 01. Basic Server (stdio)

The simplest MCP server using stdio transport:

```bash
./zig-out/bin/01_basic_server
```

Test with JSON-RPC messages:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./zig-out/bin/01_basic_server
```

### 02. HTTP Server

HTTP server with SSE support:

```bash
./zig-out/bin/02_http_server
```

Test with curl:

```bash
# Initialize
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'

# List tools (use Mcp-Session-Id from previous response)
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### 03. Tool Registration

Server with stateful tools and cancellation support:

```bash
./zig-out/bin/03_tool_registration
```

Demonstrates:

- Using context to pass state to handlers
- Counter tool that persists across calls
- Key-value storage tool
- Long-running task with cancellation

### 04. Resources and Prompts

Server demonstrating resources and prompts:

```bash
./zig-out/bin/04_resources_and_prompts
```

Demonstrates:

- Static and dynamic resources
- Resource templates with URI patterns
- Resource subscriptions
- Prompt templates with arguments

### 05. Authentication

Test different authentication modes:

```bash
# Bearer token auth
./zig-out/bin/05_authentication bearer

# Basic auth
./zig-out/bin/05_authentication basic

# OAuth 2.1
./zig-out/bin/05_authentication oauth
```

### 06. Client Example

Shows how to build MCP client requests:

```bash
./zig-out/bin/06_client_example
```

Outputs example JSON-RPC messages for all MCP methods.

### 07. Notifications

Server demonstrating notifications:

```bash
./zig-out/bin/07_notifications
```

Test notifications by calling tools that trigger them.

## Key Concepts

### Handler Structure

All MCP servers implement a `Handler` struct with these callbacks:

```zig
const handler = mcp.Handler{
    .ctx = null,                          // Optional context pointer
    .listTools = listTools,               // tools/list
    .callTool = callTool,                 // tools/call
    .listResources = listResources,       // resources/list
    .readResource = readResource,         // resources/read
    .listResourceTemplates = listResourceTemplates,
    .subscribeResource = subscribeResource,
    .unsubscribeResource = unsubscribeResource,
    .listPrompts = listPrompts,           // prompts/list
    .getPrompt = getPrompt,               // prompts/get
    .complete = complete,                 // completion/complete
    .setLogLevel = setLogLevel,           // logging/setLevel
};
```

### Server Options

Common server configuration options:

```zig
var server = try mcp.Server.init(allocator, .{
    // Identity
    .name = "my-server",
    .version = "1.0.0",
    .instructions = "Server description for LLMs",

    // Transport
    .http_port = 8080,           // 0 = auto-assign
    .http_bind = "127.0.0.1",
    .http_path = "/mcp",

    // Authentication
    .auth_mode = .bearer,        // .none, .bearer, .basic, .oauth2
    .bearer_token = "secret",

    // Performance
    .worker_threads = 4,         // 0 = single-threaded
    .max_message_bytes = 1024 * 1024,
}, handler);
```

### Response Formats

Tools must return content in this format:

```json
{"content":[{"type":"text","text":"Result text"}]}
```

Resources return:

```json
{"contents":[{"uri":"...","mimeType":"...","text":"..."}]}
```

Prompts return:

```json
{"messages":[{"role":"user","content":{"type":"text","text":"..."}}]}
```

## Protocol Reference

- [MCP Specification](https://modelcontextprotocol.io/)
- Protocol Version: `2025-11-25`

## License

Apache-2.0 - See [LICENSE](../LICENSE) for details.
