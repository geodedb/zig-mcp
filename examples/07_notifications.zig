//! Server Notifications Example
//!
//! This example demonstrates how to send notifications from server to client:
//! - Tool list changed notifications
//! - Resource list changed notifications
//! - Resource update notifications
//! - Prompt list changed notifications
//! - Log messages
//!
//! Notifications are server-initiated messages that don't expect a response.
//! They're used to inform clients about state changes.
//!
//! To run this example:
//!   zig build run-example-notifications

const std = @import("std");
const mcp = @import("mcp");

/// Server state that tracks dynamic content
const DynamicState = struct {
    allocator: std.mem.Allocator,
    server: ?*mcp.Server = null,

    // Dynamic tool list
    tools: std.ArrayList(Tool),

    // Dynamic resource list
    resources: std.ArrayList(Resource),

    const Tool = struct {
        name: []const u8,
        description: []const u8,
    };

    const Resource = struct {
        uri: []const u8,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) DynamicState {
        return .{
            .allocator = allocator,
            .tools = std.ArrayList(Tool).init(allocator),
            .resources = std.ArrayList(Resource).init(allocator),
        };
    }

    pub fn deinit(self: *DynamicState) void {
        self.tools.deinit();
        self.resources.deinit();
    }

    /// Add a tool and notify clients
    pub fn addTool(self: *DynamicState, name: []const u8, description: []const u8) !void {
        try self.tools.append(.{ .name = name, .description = description });

        // Notify clients that tool list has changed
        if (self.server) |server| {
            server.notifyToolListChanged() catch |err| {
                std.debug.print("Failed to send tool notification: {}\n", .{err});
            };
        }
    }

    /// Add a resource and notify clients
    pub fn addResource(self: *DynamicState, uri: []const u8, name: []const u8) !void {
        try self.resources.append(.{ .uri = uri, .name = name });

        // Notify clients that resource list has changed
        if (self.server) |server| {
            server.notifyResourceListChanged() catch |err| {
                std.debug.print("Failed to send resource notification: {}\n", .{err});
            };
        }
    }

    /// Update a resource and notify subscribers
    pub fn updateResource(self: *DynamicState, uri: []const u8) void {
        if (self.server) |server| {
            server.notifyResourceUpdated(uri) catch |err| {
                std.debug.print("Failed to send resource update notification: {}\n", .{err});
            };
        }
    }

    /// Emit a log message to clients
    pub fn emitLog(self: *DynamicState, level: []const u8, message: []const u8) void {
        if (self.server) |server| {
            server.emitLog(level, "dynamic-state", message) catch |err| {
                std.debug.print("Failed to emit log: {}\n", .{err});
            };
        }
    }
};

// Global state (in a real app, you'd manage this differently)
var global_state: ?*DynamicState = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = DynamicState.init(allocator);
    defer state.deinit();

    global_state = &state;
    defer global_state = null;

    // Create handler
    const handler = mcp.Handler{
        .ctx = @ptrCast(&state),
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
        .name = "notifications-example",
        .version = "1.0.0",
        .instructions =
        \\This server demonstrates dynamic notifications.
        \\Use the 'add-tool', 'add-resource', and 'update-resource' tools
        \\to trigger notifications.
        ,
        .http_port = 8080,
    }, handler);
    defer server.deinit();

    // Store server reference so state can send notifications
    state.server = &server;

    // Add some initial content
    try state.addTool("add-tool", "Dynamically add a new tool");
    try state.addTool("add-resource", "Dynamically add a new resource");
    try state.addTool("update-resource", "Trigger a resource update notification");
    try state.addTool("log", "Emit a log message to clients");

    try state.addResource("data://counter", "Dynamic Counter");

    const port = try server.serveHttp();

    std.debug.print("\n=== Notifications Example Server ===\n\n", .{});
    std.debug.print("Server running on http://localhost:{d}/mcp\n\n", .{port});
    std.debug.print("This server demonstrates notifications:\n", .{});
    std.debug.print("- Call 'add-tool' to dynamically add tools\n", .{});
    std.debug.print("- Call 'add-resource' to dynamically add resources\n", .{});
    std.debug.print("- Call 'update-resource' to notify about changes\n", .{});
    std.debug.print("- Call 'log' to emit log messages\n", .{});
    std.debug.print("\nClients connected via SSE will receive notifications.\n", .{});
    std.debug.print("\nPress Ctrl+C to stop\n", .{});

    while (true) {
        std.Thread.sleep(std.time.ns_per_s);
    }
}

// ============================================================================
// Handler Implementations
// ============================================================================

fn listTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    // Return current tools (in a real implementation, build dynamically)
    return
        \\{"tools":[
        \\  {
        \\    "name": "add-tool",
        \\    "description": "Add a new tool dynamically (triggers notifications/tools/list_changed)",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "name": { "type": "string" },
        \\        "description": { "type": "string" }
        \\      },
        \\      "required": ["name", "description"]
        \\    }
        \\  },
        \\  {
        \\    "name": "add-resource",
        \\    "description": "Add a new resource dynamically (triggers notifications/resources/list_changed)",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "uri": { "type": "string" },
        \\        "name": { "type": "string" }
        \\      },
        \\      "required": ["uri", "name"]
        \\    }
        \\  },
        \\  {
        \\    "name": "update-resource",
        \\    "description": "Notify about a resource update (triggers notifications/resources/updated)",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "uri": { "type": "string", "description": "URI of the updated resource" }
        \\      },
        \\      "required": ["uri"]
        \\    }
        \\  },
        \\  {
        \\    "name": "log",
        \\    "description": "Emit a log message to clients (triggers notifications/message)",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "properties": {
        \\        "level": { "type": "string", "enum": ["debug", "info", "warning", "error"] },
        \\        "message": { "type": "string" }
        \\      },
        \\      "required": ["level", "message"]
        \\    }
        \\  }
        \\]}
    ;
}

fn callTool(
    ctx: ?*anyopaque,
    name: []const u8,
    _: []const u8,
    _: *const mcp.CancelToken,
) anyerror![]const u8 {
    const state: *DynamicState = @ptrCast(@alignCast(ctx.?));

    if (std.mem.eql(u8, name, "add-tool")) {
        // In a real implementation, parse args and add the tool
        try state.addTool("new-dynamic-tool", "A dynamically added tool");
        return
            \\{"content":[{"type":"text","text":"Tool added! Notification sent to clients."}]}
        ;
    }

    if (std.mem.eql(u8, name, "add-resource")) {
        try state.addResource("data://dynamic", "Dynamic Resource");
        return
            \\{"content":[{"type":"text","text":"Resource added! Notification sent to clients."}]}
        ;
    }

    if (std.mem.eql(u8, name, "update-resource")) {
        state.updateResource("data://counter");
        return
            \\{"content":[{"type":"text","text":"Resource update notification sent!"}]}
        ;
    }

    if (std.mem.eql(u8, name, "log")) {
        state.emitLog("info", "This is a log message from the server");
        return
            \\{"content":[{"type":"text","text":"Log message emitted to clients!"}]}
        ;
    }

    return error.ToolNotFound;
}

fn listResources(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return
        \\{"resources":[
        \\  {"uri": "data://counter", "name": "Dynamic Counter", "mimeType": "application/json"}
        \\]}
    ;
}

fn readResource(_: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
    if (std.mem.eql(u8, uri, "data://counter")) {
        return
            \\{"contents":[{"uri":"data://counter","mimeType":"application/json","text":"{\"count\":42}"}]}
        ;
    }
    return error.ResourceNotFound;
}

fn listResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    return "{\"resourceTemplates\":[]}";
}

fn subscribeResource(_: ?*anyopaque, uri: []const u8) anyerror!void {
    std.debug.print("Client subscribed to: {s}\n", .{uri});
}

fn unsubscribeResource(_: ?*anyopaque, uri: []const u8) anyerror!void {
    std.debug.print("Client unsubscribed from: {s}\n", .{uri});
}

fn listPrompts(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"prompts\":[]}";
}

fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.PromptNotFound;
}

fn complete(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return "{\"completion\":{\"values\":[]}}";
}

fn setLogLevel(_: ?*anyopaque, level: []const u8) anyerror!void {
    std.debug.print("Log level changed to: {s}\n", .{level});
}
