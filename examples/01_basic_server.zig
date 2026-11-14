//! Basic MCP Server Example
//!
//! This example demonstrates how to create a minimal MCP server that:
//! - Initializes with server name and version
//! - Registers a simple "echo" tool
//! - Handles tool calls and returns responses
//! - Uses stdio transport for communication
//!
//! To run this example:
//!   zig build run-example-basic-server
//!
//! To test manually, send JSON-RPC messages to stdin:
//!   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
//!   {"jsonrpc":"2.0","method":"notifications/initialized"}
//!   {"jsonrpc":"2.0","id":2,"method":"tools/list"}
//!   {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello, MCP!"}}}

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
    // Step 1: Create an allocator
    // The DebugAllocator is suitable for most use cases.
    // For production servers handling many requests, consider using
    // ArenaAllocator for per-request allocations.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    result_allocator = allocator;

    // Step 2: Create the handler that defines server behavior
    // The handler contains callbacks for all MCP operations:
    // - listTools/callTool: Tool discovery and execution
    // - listResources/readResource: Resource access
    // - listPrompts/getPrompt: Prompt templates
    // - complete: Autocompletion support
    // - setLogLevel: Logging configuration
    const handler = createEchoHandler();

    // Step 3: Initialize the MCP server with configuration options
    var server = try mcp.Server.init(allocator, .{
        // Server identification - shown to clients during initialization
        .name = "echo-server",
        .version = "1.0.0",

        // Optional: Add instructions for the client/LLM
        .instructions = "This server provides a simple echo tool for testing.",

        // Worker threads for parallel request handling (0 = single-threaded)
        .worker_threads = 0,

        // Message size limits for safety
        .max_message_bytes = 1024 * 1024, // 1MB max message
        .max_batch_items = 100, // Max items in a batch request
    }, handler);
    defer server.deinit();

    // Step 4: Start serving requests over stdio
    // This blocks until the client closes the connection or an error occurs.
    // For stdio transport, messages are newline-delimited JSON-RPC.
    std.debug.print("Echo server started. Waiting for requests on stdin...\n", .{});
    try server.serveStdio();
}

// ============================================================================
// Handler Implementation
// ============================================================================

/// Creates a handler with our echo tool implementation
fn createEchoHandler() mcp.Handler {
    return .{
        // Context pointer - can be used to pass custom state to handlers
        // Set to null when no state is needed
        .ctx = null,

        // Tool-related callbacks
        .listTools = listTools,
        .callTool = callTool,

        // Resource-related callbacks (returning empty lists for this example)
        .listResources = listResources,
        .readResource = readResource,
        .listResourceTemplates = listResourceTemplates,
        .subscribeResource = subscribeResource,
        .unsubscribeResource = unsubscribeResource,

        // Prompt-related callbacks (returning empty lists for this example)
        .listPrompts = listPrompts,
        .getPrompt = getPrompt,

        // Other MCP features
        .complete = complete,
        .setLogLevel = setLogLevel,
    };
}

/// Returns the list of available tools
/// This is called when a client sends "tools/list"
fn listTools(_: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    // The cursor parameter is used for pagination. For small tool lists,
    // we can ignore it and return all tools at once.
    _ = cursor;

    // Return tools as a JSON object with a "tools" array.
    // Each tool has:
    // - name: Unique identifier for the tool
    // - description: Human-readable description for the LLM
    // - inputSchema: JSON Schema describing the expected arguments
    return owned(
        \\{"tools":[
        \\  {
        \\    "name": "echo",
        \\    "description": "Echoes back the provided message. Use this to test the server connection.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "message": {
        \\          "type": "string",
        \\          "description": "The message to echo back"
        \\        }
        \\      },
        \\      "required": ["message"]
        \\    }
        \\  }
        \\]}
    );
}

/// Executes a tool call
/// This is called when a client sends "tools/call"
fn callTool(
    _: ?*anyopaque,
    name: []const u8,
    args_json: []const u8,
    cancel: *const mcp.CancelToken,
) anyerror![]const u8 {
    // Check if the operation was cancelled (useful for long-running operations)
    if (cancel.isCancelled()) {
        return error.Cancelled;
    }

    // Route to the appropriate tool handler
    if (std.mem.eql(u8, name, "echo")) {
        return handleEcho(args_json);
    }

    // Return error for unknown tools
    return error.ToolNotFound;
}

/// Handles the "echo" tool
fn handleEcho(args_json: []const u8) ![]const u8 {
    // In a real implementation, you would parse args_json to extract
    // the "message" field. For this simple example, we just echo
    // a confirmation message.
    //
    // The response format must be a JSON object with a "content" array.
    // Each content item has a "type" field (text, image, resource, etc.)
    _ = args_json;

    return owned(
        \\{"content":[{"type":"text","text":"Echo: Message received!"}]}
    );
}

// ============================================================================
// Stub implementations for other handler callbacks
// ============================================================================

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
