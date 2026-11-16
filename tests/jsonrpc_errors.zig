//! JSON-RPC error semantics tests (SONNY-6585).
//!
//! Every test drives a real JSON-RPC message through `Server.processMessage`
//! (the library's dispatcher) and checks the bytes that would go on the wire:
//!
//! - MCP 2025-11-25 server/tools "Error Handling" and server/prompts "Error
//!   Handling": an unknown tool and an invalid prompt name are `-32602`
//!   (Invalid params). Resource not found stays `-32002` (server/resources).
//! - JSON-RPC 2.0 section 4.1: "The Server MUST NOT reply to a Notification,
//!   including those that are within a batch request", even when it fails.
//! - MCP basic/utilities/cancellation: the receiver of
//!   `notifications/cancelled` SHOULD NOT send a response for the cancelled
//!   request.
//! - MCP basic "Requests": the id MUST be a string or integer, never null.
//! - Every response must be valid JSON whatever bytes a string id holds.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

inline fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const ErrHandler = struct {
    allocator: std.mem.Allocator,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn handler(self: *ErrHandler) mcp.Handler {
        return .{
            .ctx = @ptrCast(self),
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

    fn self_(ctx: ?*anyopaque) *ErrHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"tools\":[]}");
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "known")) {
            return self.allocator.dupe(u8, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}");
        }
        if (std.mem.eql(u8, name, "wait_cancel")) {
            // Runs until the peer cancels this request. The deadline keeps a
            // broken cancellation path from hanging the test run.
            self.started.store(true, .release);
            var waited_ms: u32 = 0;
            while (!cancel.isCancelled()) : (waited_ms += 1) {
                if (waited_ms >= 5000) return error.Timeout;
                testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
            return error.Cancelled;
        }
        if (std.mem.eql(u8, name, "self_cancel")) {
            // Cancelled for a reason other than notifications/cancelled (for
            // example a server-side timeout): the client still awaits a reply.
            return error.Cancelled;
        }
        return error.ToolNotFound;
    }

    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resources\":[]}");
    }

    fn readResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return error.ResourceNotFound;
    }

    fn listResourceTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resourceTemplates\":[]}");
    }

    fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"prompts\":[]}");
    }

    fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
        return error.PromptNotFound;
    }

    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"completion\":{\"values\":[]}}");
    }

    fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

const Fixture = struct {
    handler: ErrHandler,
    server: mcp.Server,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "errors-test",
            .version = "1.0.0",
        }, self.handler.handler());
        errdefer self.server.deinit();

        const init_resp = try self.server.processMessage(
            \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        );
        if (init_resp) |r| allocator.free(r);
        const notif = try self.server.processMessage(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
        try std.testing.expect(notif == null);
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
    }
};

/// Parses `response` as a single JSON-RPC response object, failing the test
/// if it is not valid JSON.
fn parseResponse(response: []const u8) !json.Document {
    var err = json.ParseError.init();
    return json.parse(std.testing.allocator, response, .{}, &err) catch |e| {
        std.debug.print("response is not valid JSON ({s}): {s}\n", .{ @errorName(e), response });
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

fn expectErrorCode(response: []const u8, expected: i64) !void {
    var doc = try parseResponse(response);
    defer doc.deinit();
    const err_obj = field(doc.root, "error") orelse {
        std.debug.print("expected an error response, got: {s}\n", .{response});
        return error.TestExpectedError;
    };
    const code = field(err_obj, "code") orelse return error.TestExpectedCode;
    try std.testing.expect(code == .num);
    try std.testing.expectEqual(expected, try std.fmt.parseInt(i64, code.num.lexeme, 10));
}

fn expectNullId(response: []const u8) !void {
    var doc = try parseResponse(response);
    defer doc.deinit();
    const id = field(doc.root, "id") orelse return error.TestExpectedId;
    try std.testing.expect(id == .null);
}

// ----------------------------------------------------------------------------
// Error codes (MCP 2025-11-25)
// ----------------------------------------------------------------------------

test "SONNY-6585: unknown tool is -32602 Invalid params" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"invalid_tool_name","arguments":{}}}
    )).?;
    defer a.free(resp);
    try expectErrorCode(resp, -32602);
}

test "SONNY-6585: invalid prompt name is -32602 Invalid params" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"nope"}}
    )).?;
    defer a.free(resp);
    try expectErrorCode(resp, -32602);
}

test "SONNY-6585: resource not found stays -32002" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"file:///nonexistent.txt"}}
    )).?;
    defer a.free(resp);
    try expectErrorCode(resp, -32002);
}

// ----------------------------------------------------------------------------
// Notifications are never answered (JSON-RPC 2.0 section 4.1)
// ----------------------------------------------------------------------------

test "SONNY-6585: failing notification gets no response" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const cases = [_][]const u8{
        // Handler error.
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"invalid_tool_name"}}
        ,
        // Library-side Invalid params (missing name).
        \\{"jsonrpc":"2.0","method":"tools/call","params":{}}
        ,
        // Method not found.
        \\{"jsonrpc":"2.0","method":"no/such/method"}
        ,
        \\{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"file:///x"}}
        ,
    };
    for (cases) |msg| {
        const resp = try f.server.processMessage(msg);
        if (resp) |r| {
            defer a.free(r);
            std.debug.print("notification {s} was answered: {s}\n", .{ msg, r });
            return error.TestNotificationAnswered;
        }
    }
}

test "SONNY-6585: notification before initialize gets no response" {
    const a = std.testing.allocator;
    var h: ErrHandler = .{ .allocator = a };
    var server = try mcp.Server.init(a, .{ .name = "t", .version = "1" }, h.handler());
    defer server.deinit();

    const resp = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"tools/list"}
    );
    if (resp) |r| {
        defer a.free(r);
        std.debug.print("notification was answered: {s}\n", .{r});
        return error.TestNotificationAnswered;
    }
}

test "SONNY-6585: batch answers only the requests, not failing notifications" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\[{"jsonrpc":"2.0","method":"tools/call","params":{"name":"invalid_tool_name"}},{"jsonrpc":"2.0","id":9,"method":"ping"},{"jsonrpc":"2.0","method":"no/such/method"}]
    )).?;
    defer a.free(resp);

    var doc = try parseResponse(resp);
    defer doc.deinit();
    try std.testing.expect(doc.root == .arr);
    try std.testing.expectEqual(@as(usize, 1), doc.root.arr.len);
    const id = field(doc.root.arr[0], "id").?;
    try std.testing.expectEqualStrings("9", id.num.lexeme);
}

test "SONNY-6585: batch of only failing notifications returns nothing" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = try f.server.processMessage(
        \\[{"jsonrpc":"2.0","method":"tools/call","params":{"name":"invalid_tool_name"}},{"jsonrpc":"2.0","method":"no/such/method"}]
    );
    if (resp) |r| {
        defer a.free(r);
        std.debug.print("batch of notifications was answered: {s}\n", .{r});
        return error.TestNotificationAnswered;
    }
}

// ----------------------------------------------------------------------------
// Invalid ids are Invalid Request, not silent notifications
// ----------------------------------------------------------------------------

test "SONNY-6585: id that is not a string or integer is Invalid Request with null id" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const cases = [_][]const u8{
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":true,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":{"a":1},"method":"tools/call","params":{"name":"invalid_tool_name"}}
        ,
        \\{"jsonrpc":"2.0","id":1.5,"method":"ping"}
        ,
    };
    for (cases) |msg| {
        const resp = (try f.server.processMessage(msg)) orelse {
            std.debug.print("invalid-id request got no response: {s}\n", .{msg});
            return error.TestExpectedResponse;
        };
        defer a.free(resp);
        try expectErrorCode(resp, -32600);
        try expectNullId(resp);
    }
}

// ----------------------------------------------------------------------------
// Cancellation (MCP basic/utilities/cancellation)
// ----------------------------------------------------------------------------

const CallResult = struct {
    response: ?[]const u8 = null,
    err: ?anyerror = null,
};

fn runCall(server: *mcp.Server, msg: []const u8, out: *CallResult) void {
    out.response = server.processMessage(msg) catch |e| {
        out.err = e;
        return;
    };
}

test "SONNY-6585: request cancelled by notifications/cancelled gets no response" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var result: CallResult = .{};
    const t = try std.Thread.spawn(.{}, runCall, .{
        &f.server,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_cancel"}}
        ,
        &result,
    });

    var spins: u32 = 0;
    while (!f.handler.started.load(.acquire)) : (spins += 1) {
        if (spins > 5000) break;
        testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(f.handler.started.load(.acquire));

    const notif = try f.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"user"}}
    );
    try std.testing.expect(notif == null);

    t.join();
    try std.testing.expect(result.err == null);
    if (result.response) |r| {
        defer a.free(r);
        std.debug.print("cancelled request was answered: {s}\n", .{r});
        return error.TestCancelledRequestAnswered;
    }
}

test "SONNY-6585: error.Cancelled without a peer cancellation is still answered" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"self_cancel"}}
    )) orelse return error.TestExpectedResponse;
    defer a.free(resp);
    try expectErrorCode(resp, -32603);
}

test "SONNY-6585: cancellation for an unknown or completed request is ignored" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const done = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"known"}}
    )).?;
    a.free(done);

    const notif = try f.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11}}
    );
    try std.testing.expect(notif == null);

    // A later request reusing nothing from the cancelled one is answered.
    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"known"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    try std.testing.expect(field(doc.root, "result") != null);
}

// ----------------------------------------------------------------------------
// String ids are JSON-escaped in every response
// ----------------------------------------------------------------------------

test "SONNY-6585: string id with quote and backslash is escaped in an error response" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":"a\"b\\c\u0001","method":"tools/call","params":{"name":"invalid_tool_name"}}
    )).?;
    defer a.free(resp);

    var doc = try parseResponse(resp);
    defer doc.deinit();
    const id = field(doc.root, "id").?;
    try std.testing.expect(id == .str);
    try std.testing.expectEqualStrings("a\"b\\c\x01", id.str);
}

test "SONNY-6585: string id with quote is escaped in a success response" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":"x\"y\n","method":"ping"}
    )).?;
    defer a.free(resp);

    var doc = try parseResponse(resp);
    defer doc.deinit();
    const id = field(doc.root, "id").?;
    try std.testing.expect(id == .str);
    try std.testing.expectEqualStrings("x\"y\n", id.str);
}
