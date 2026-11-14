//! HTTP MCP Server Example
//!
//! This example demonstrates how to create an MCP server that:
//! - Uses HTTP transport with Server-Sent Events (SSE)
//! - Supports session management
//! - Can be accessed by web-based MCP clients
//!
//! To run this example:
//!   zig build run-example-http-server
//!
//! The server will start on http://127.0.0.1:8080/mcp
//!
//! To test with curl:
//!   # Initialize a session
//!   curl -X POST http://localhost:8080/mcp \
//!     -H "Content-Type: application/json" \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
//!
//!   # Use the Mcp-Session-Id header from the response for subsequent requests
//!   curl -X POST http://localhost:8080/mcp \
//!     -H "Content-Type: application/json" \
//!     -H "Mcp-Session-Id: <session-id>" \
//!     -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

const std = @import("std");
const mcp = @import("mcp");

/// The server frees every slice a handler callback returns, using the
/// allocator the server was built with (see "Result Ownership" on
/// `mcp.Handler`). Callbacks therefore return copies made with that same
/// allocator, never string literals. `main` sets this before serving.
var result_allocator: std.mem.Allocator = undefined;

/// Returns a server-owned copy of `text`.
fn owned(text: []const u8) ![]const u8 {
    return result_allocator.dupe(u8, text);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    result_allocator = allocator;

    const handler = createHandler();

    // Initialize the MCP server with HTTP configuration
    var server = try mcp.Server.init(allocator, .{
        .name = "http-example-server",
        .version = "1.0.0",
        .instructions = "HTTP-based MCP server with calculator and greeting tools.",

        // HTTP transport configuration
        .http_bind = "127.0.0.1", // Address to bind to (use "0.0.0.0" for all interfaces)
        .http_port = 8080, // Port number (0 = auto-assign)
        .http_path = "/mcp", // Base path for MCP endpoint

        // CORS configuration for web clients
        // null = only allow localhost; specify origins for production
        .http_allowed_origins = null,

        // Worker threads for parallel request handling
        .worker_threads = 4,

        // SSE (Server-Sent Events) configuration
        .sse_retry_ms = 3000, // Retry hint for clients on disconnect

        // Performance options
        .connection_pool_size = 10, // HTTP connection pool size
        .connection_pool_timeout_ms = 30000, // Pool timeout
    }, handler);
    defer server.deinit();

    // Start the HTTP server
    // serveHttp() returns immediately after starting the server thread
    // and returns the actual port number (useful when port is set to 0)
    const port = try server.serveHttp();

    std.debug.print("HTTP MCP Server started!\n", .{});
    std.debug.print("Listening on: http://127.0.0.1:{d}/mcp\n", .{port});
    std.debug.print("\nEndpoints:\n", .{});
    std.debug.print("  POST /mcp         - JSON-RPC requests\n", .{});
    std.debug.print("  GET  /mcp         - SSE event stream\n", .{});
    std.debug.print("  DELETE /mcp       - Close session\n", .{});
    std.debug.print("  GET  /health      - Health check\n", .{});
    std.debug.print("\nPress Ctrl+C to stop\n", .{});

    // Keep the main thread alive
    // In a real application, you might want to handle signals properly
    while (true) {
        std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
}

// ============================================================================
// Handler Implementation with Multiple Tools
// ============================================================================

fn createHandler() mcp.Handler {
    return .{
        .ctx = null,
        .listTools = listTools,
        .callTool = callTool,
        .listResources = listResources,
        .readResource = readResource,
        .listResourceTemplates = listResourceTemplates,
        .subscribeResource = subscribeResource,
        .unsubscribeResource = unsubscribeResource,
        .listPrompts = listPrompts,
        .getPrompt = getPrompt,
        .complete = complete,
        .setLogLevel = setLogLevel,
    };
}

fn listTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    // Multiple tools demonstrating different capabilities
    return owned(
        \\{"tools":[
        \\  {
        \\    "name": "calculator",
        \\    "description": "Performs basic arithmetic operations",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "operation": {
        \\          "type": "string",
        \\          "enum": ["add", "subtract", "multiply", "divide"],
        \\          "description": "The operation to perform"
        \\        },
        \\        "a": { "type": "number", "description": "First operand" },
        \\        "b": { "type": "number", "description": "Second operand" }
        \\      },
        \\      "required": ["operation", "a", "b"]
        \\    }
        \\  },
        \\  {
        \\    "name": "greeting",
        \\    "description": "Generates a personalized greeting",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "name": { "type": "string", "description": "Name to greet" },
        \\        "style": {
        \\          "type": "string",
        \\          "enum": ["formal", "casual", "enthusiastic"],
        \\          "default": "casual"
        \\        }
        \\      },
        \\      "required": ["name"]
        \\    }
        \\  },
        \\  {
        \\    "name": "timestamp",
        \\    "description": "Returns the current server timestamp",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {}
        \\    }
        \\  }
        \\]}
    );
}

fn callTool(
    _: ?*anyopaque,
    name: []const u8,
    _: []const u8,
    cancel: *const mcp.CancelToken,
) anyerror![]const u8 {
    if (cancel.isCancelled()) {
        return error.Cancelled;
    }

    // Route to appropriate tool handler
    if (std.mem.eql(u8, name, "calculator")) {
        // In a real implementation, parse args_json and compute result
        return owned(
            \\{"content":[{"type":"text","text":"Calculator result: 42"}]}
        );
    }

    if (std.mem.eql(u8, name, "greeting")) {
        return owned(
            \\{"content":[{"type":"text","text":"Hello! Nice to meet you!"}]}
        );
    }

    if (std.mem.eql(u8, name, "timestamp")) {
        return owned(
            \\{"content":[{"type":"text","text":"Current timestamp: 2025-01-24T12:00:00Z"}]}
        );
    }

    return error.ToolNotFound;
}

// Stub implementations for other callbacks
fn listResources(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned("{\"resources\":[]}");
}

fn readResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return error.ResourceNotFound;
}

fn listResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    return owned("{\"resourceTemplates\":[]}");
}

fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn listPrompts(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned("{\"prompts\":[]}");
}

fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.PromptNotFound;
}

fn complete(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return owned("{\"completion\":{\"values\":[]}}");
}

fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
