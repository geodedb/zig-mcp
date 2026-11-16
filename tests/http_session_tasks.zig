//! Streamable HTTP sessions: tasks belong to the client that created them
//! (SONNY-6644). MCP 2025-11-25 tasks: a task is created for a request and
//! polled with tasks/get, tasks/list, tasks/result and tasks/cancel. Over
//! HTTP with several clients, one client must not see, read, list or
//! cancel another client's task. Real server, two raw-socket clients.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");
const http = @import("http_test_client.zig");

const TaskHandler = struct {
    allocator: std.mem.Allocator,
    server: *mcp.Server = undefined,

    fn handler(self: *TaskHandler) mcp.Handler {
        var demo = mcp.DemoHandler.init(self.allocator);
        var h = demo.handler();
        h.ctx = @ptrCast(self);
        h.callTool = callTool;
        h.listTools = listTools;
        h.listResources = listResources;
        h.listResourceTemplates = listResourceTemplates;
        h.listPrompts = listPrompts;
        h.complete = complete;
        return h;
    }

    fn self_(ctx: ?*anyopaque) *TaskHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "start_task")) {
            const task = try self.server.createTask("tools/call", null);
            self.server.updateTaskStatus(task.id, .completed, "{\"secret\":\"of-a\"}");
            return std.fmt.allocPrint(self.allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{task.id});
        }
        return error.ToolNotFound;
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"tools\":[]}");
    }
    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resources\":[]}");
    }
    fn listResourceTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resourceTemplates\":[]}");
    }
    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"prompts\":[]}");
    }
    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"completion\":{\"values\":[]}}");
    }
};

fn parse(bytes: []const u8) !json.Document {
    var err = json.ParseError.init();
    return json.parse(std.testing.allocator, bytes, .{}, &err) catch |e| {
        std.debug.print("not valid JSON ({s}): {s}\n", .{ @errorName(e), bytes });
        return e;
    };
}

fn field(v: json.Value, key: []const u8) ?json.Value {
    if (v != .obj) return null;
    for (v.obj) |m| {
        if (std.mem.eql(u8, m.k, key)) return m.v;
    }
    return null;
}

fn connect(a: std.mem.Allocator, port: u16) ![]u8 {
    const r = try http.post(a, port, null,
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    );
    defer a.free(r.body);
    const sid = r.session_id orelse return error.TestNoSessionId;
    var n = try http.post(a, port, sid,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    n.deinit(a);
    return sid;
}

fn call(a: std.mem.Allocator, port: u16, sid: []const u8, comptime fmt: []const u8, args: anytype) !json.Document {
    const body = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(body);
    var r = try http.post(a, port, sid, body);
    defer r.deinit(a);
    return parse(r.body);
}

test "one client cannot get, list, read or cancel another client's task" {
    const a = std.testing.allocator;
    var h: TaskHandler = .{ .allocator = a };
    var server = try mcp.Server.init(a, .{
        .name = "http-tasks",
        .version = "1",
        .http_port = 0,
        .tasks_enabled = true,
    }, h.handler());
    h.server = &server;
    defer server.deinit();
    const port = try server.serveHttp();
    defer server.stop();

    const sid_a = try connect(a, port);
    defer a.free(sid_a);
    const sid_b = try connect(a, port);
    defer a.free(sid_b);

    var started = try call(a, port, sid_a,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"start_task"}}}}
    , .{});
    defer started.deinit();
    const task_id = field(field(field(started.root, "result").?, "content").?.arr[0], "text").?.str;

    // A sees its own task.
    var own = try call(a, port, sid_a,
        \\{{"jsonrpc":"2.0","id":2,"method":"tasks/get","params":{{"taskId":"{s}"}}}}
    , .{task_id});
    defer own.deinit();
    try std.testing.expect(field(own.root, "result") != null);

    // B does not.
    inline for (.{ "tasks/get", "tasks/result", "tasks/cancel" }) |method| {
        var other = try call(a, port, sid_b,
            \\{{"jsonrpc":"2.0","id":3,"method":"
        ++ method ++
            \\","params":{{"taskId":"{s}"}}}}
        , .{task_id});
        defer other.deinit();
        if (field(other.root, "result") != null) {
            std.debug.print("{s} exposed another client's task\n", .{method});
            return error.TestCrossSessionLeak;
        }
    }
    var list_b = try call(a, port, sid_b,
        \\{{"jsonrpc":"2.0","id":4,"method":"tasks/list"}}
    , .{});
    defer list_b.deinit();
    try std.testing.expectEqual(@as(usize, 0), field(field(list_b.root, "result").?, "tasks").?.arr.len);

    // B's cancel attempt did not touch A's task.
    var still = try call(a, port, sid_a,
        \\{{"jsonrpc":"2.0","id":5,"method":"tasks/get","params":{{"taskId":"{s}"}}}}
    , .{task_id});
    defer still.deinit();
    try std.testing.expectEqualStrings("completed", field(field(still.root, "result").?, "status").?.str);
}
