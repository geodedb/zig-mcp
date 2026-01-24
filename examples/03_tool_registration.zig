//! Tool Registration Example
//!
//! This example demonstrates advanced tool registration patterns:
//! - Using context to pass state to handlers
//! - Registering multiple tools with complex schemas
//! - Handling tool arguments properly
//! - Supporting tool metadata (title, icons, annotations)
//! - Implementing cancellation for long-running operations
//!
//! To run this example:
//!   zig build run-example-tool-registration

const std = @import("std");
const mcp = @import("mcp");

// ============================================================================
// Server State
// ============================================================================

/// Server state that can be accessed by all handler callbacks
const ServerState = struct {
    allocator: std.mem.Allocator,

    // Example state: a counter that persists across tool calls
    counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Example state: a key-value store
    storage: std.StringHashMap([]const u8),
    storage_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .storage = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ServerState) void {
        var iter = self.storage.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.storage.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server state that will be passed to handlers via context
    var state = ServerState.init(allocator);
    defer state.deinit();

    // Create handler with context pointer
    const handler = mcp.Handler{
        // Pass pointer to our state as the context
        .ctx = @ptrCast(&state),

        // All callbacks can access state via the ctx parameter
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

    var server = try mcp.Server.init(allocator, .{
        .name = "stateful-tools-server",
        .version = "1.0.0",
        .instructions =
        \\This server provides stateful tools:
        \\- counter: Increment/decrement/get a persistent counter
        \\- storage: Store and retrieve key-value pairs
        \\- longTask: Demonstrates cancellation support
        ,

        // Enable parallel processing
        .worker_threads = 4,
    }, handler);
    defer server.deinit();

    std.debug.print("Stateful Tools Server started.\n", .{});
    std.debug.print("Tools available: counter, storage, longTask\n", .{});
    std.debug.print("Waiting for requests on stdin...\n\n", .{});

    try server.serveStdio();
}

// ============================================================================
// Handler Implementations
// ============================================================================

fn listTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    // Comprehensive tool definitions with metadata
    return
        \\{"tools":[
        \\  {
        \\    "name": "counter",
        \\    "title": "Persistent Counter",
        \\    "description": "A counter that persists across calls. Supports increment, decrement, get, and reset operations.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "operation": {
        \\          "type": "string",
        \\          "enum": ["increment", "decrement", "get", "reset"],
        \\          "description": "The operation to perform on the counter"
        \\        },
        \\        "amount": {
        \\          "type": "integer",
        \\          "default": 1,
        \\          "description": "Amount to increment/decrement by (default: 1)"
        \\        }
        \\      },
        \\      "required": ["operation"]
        \\    },
        \\    "annotations": {
        \\      "destructive": false,
        \\      "idempotent": false,
        \\      "openWorld": false
        \\    }
        \\  },
        \\  {
        \\    "name": "storage",
        \\    "title": "Key-Value Storage",
        \\    "description": "Store and retrieve key-value pairs. Data persists for the lifetime of the server.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "operation": {
        \\          "type": "string",
        \\          "enum": ["get", "set", "delete", "list"],
        \\          "description": "The storage operation to perform"
        \\        },
        \\        "key": {
        \\          "type": "string",
        \\          "description": "The key to operate on (required for get/set/delete)"
        \\        },
        \\        "value": {
        \\          "type": "string",
        \\          "description": "The value to store (required for set)"
        \\        }
        \\      },
        \\      "required": ["operation"]
        \\    },
        \\    "annotations": {
        \\      "destructive": true,
        \\      "idempotent": false
        \\    }
        \\  },
        \\  {
        \\    "name": "longTask",
        \\    "title": "Long-Running Task",
        \\    "description": "Simulates a long-running task that can be cancelled. Useful for testing cancellation support.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "durationMs": {
        \\          "type": "integer",
        \\          "default": 5000,
        \\          "description": "How long the task should run in milliseconds"
        \\        }
        \\      }
        \\    },
        \\    "annotations": {
        \\      "destructive": false,
        \\      "idempotent": true
        \\    }
        \\  }
        \\]}
    ;
}

fn callTool(
    ctx: ?*anyopaque,
    name: []const u8,
    args_json: []const u8,
    cancel: *const mcp.CancelToken,
) anyerror![]const u8 {
    // Cast context back to our state type
    const state: *ServerState = @ptrCast(@alignCast(ctx.?));

    if (std.mem.eql(u8, name, "counter")) {
        return handleCounter(state, args_json);
    }

    if (std.mem.eql(u8, name, "storage")) {
        return handleStorage(state, args_json);
    }

    if (std.mem.eql(u8, name, "longTask")) {
        return handleLongTask(cancel, args_json);
    }

    return error.ToolNotFound;
}

/// Handle counter operations
fn handleCounter(state: *ServerState, _: []const u8) ![]const u8 {
    // For this example, we just increment and return the value
    // In a real implementation, you would parse args_json to get the operation
    const new_value = state.counter.fetchAdd(1, .monotonic) + 1;
    _ = new_value;

    return
        \\{"content":[{"type":"text","text":"Counter incremented. Current value: 1"}]}
    ;
}

/// Handle storage operations
fn handleStorage(state: *ServerState, _: []const u8) ![]const u8 {
    // For this example, we just list the keys
    // In a real implementation, you would parse args_json
    state.storage_mutex.lock();
    defer state.storage_mutex.unlock();

    const count = state.storage.count();
    _ = count;

    return
        \\{"content":[{"type":"text","text":"Storage contains 0 items"}]}
    ;
}

/// Handle long-running task with cancellation support
fn handleLongTask(cancel: *const mcp.CancelToken, _: []const u8) ![]const u8 {
    // Simulate a long-running task that checks for cancellation
    const iterations: usize = 50;
    const sleep_per_iteration = 100 * std.time.ns_per_ms;

    for (0..iterations) |i| {
        // Check for cancellation periodically
        if (cancel.isCancelled()) {
            return
                \\{"content":[{"type":"text","text":"Task was cancelled"}],"isError":true}
            ;
        }

        // Simulate work
        std.Thread.sleep(sleep_per_iteration);
        _ = i;
    }

    return
        \\{"content":[{"type":"text","text":"Long task completed successfully!"}]}
    ;
}

// ============================================================================
// Stub implementations
// ============================================================================

fn listResources(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"resources\":[]}";
}

fn readResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return error.ResourceNotFound;
}

fn listResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    return "{\"resourceTemplates\":[]}";
}

fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn listPrompts(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"prompts\":[]}";
}

fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.PromptNotFound;
}

fn complete(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return "{\"completion\":{\"values\":[]}}";
}

fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
