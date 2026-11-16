//! Dispatcher wire-safety tests (SONNY-6585 follow-up).
//!
//! Each test drives real JSON-RPC messages through `Server.processMessage`
//! under `std.testing.allocator`:
//!
//! - A tool named "barrier" belongs to the handler. The library must not
//!   intercept it (it used to run a built-in test barrier that any client
//!   could call, and that blocked forever on a large `count`).
//! - `client_protocol_version` must stay valid after the message that set
//!   it has been freed.
//! - `notifications/cancelled` with a string `requestId` cancels the
//!   request with that string id (MCP RequestId is a string or an integer).
//! - A handler result containing newlines must not break newline-delimited
//!   stdio framing; a result that is not one JSON value is an Internal
//!   error, not a malformed response.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

inline fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const WireHandler = struct {
    allocator: std.mem.Allocator,
    barrier_calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn handler(self: *WireHandler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *WireHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        // Pretty-printed, the way a handler that formats JSON for humans
        // would return it.
        return self_(ctx).allocator.dupe(u8,
            \\{
            \\  "tools": [
            \\    {"name": "barrier", "description": "line one\nline two"}
            \\  ]
            \\}
        );
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "barrier")) {
            _ = self.barrier_calls.fetchAdd(1, .acq_rel);
            return self.allocator.dupe(u8, "{\"content\":[{\"type\":\"text\",\"text\":\"user barrier\"}]}");
        }
        if (std.mem.eql(u8, name, "wait_cancel")) {
            self.started.store(true, .release);
            var waited_ms: u32 = 0;
            while (!cancel.isCancelled()) : (waited_ms += 1) {
                if (waited_ms >= 5000) return error.Timeout;
                testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
            return error.Cancelled;
        }
        if (std.mem.eql(u8, name, "not_json")) {
            return self.allocator.dupe(u8, "{\"content\": [\n");
        }
        if (std.mem.eql(u8, name, "two_values")) {
            return self.allocator.dupe(u8, "{} {}");
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
    handler: WireHandler,
    server: mcp.Server,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "wire-test",
            .version = "1.0.0",
        }, self.handler.handler());
        errdefer self.server.deinit();

        const init_resp = try self.server.processMessage(
            \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        );
        if (init_resp) |r| allocator.free(r);
        _ = try self.server.processMessage(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
    }
};

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

fn expectOneLine(response: []const u8) !void {
    if (std.mem.indexOfAny(u8, response, "\r\n") != null) {
        std.debug.print("response breaks newline framing: {s}\n", .{response});
        return error.TestResponseHasNewline;
    }
}

// ----------------------------------------------------------------------------
// The "barrier" tool name belongs to the handler
// ----------------------------------------------------------------------------

test "tools/call barrier reaches the handler, not a built-in" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    // count 1 let the old built-in barrier return at once instead of
    // reaching the handler; any larger count made it wait forever.
    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"barrier","arguments":{"count":1}}}
    )).?;
    defer a.free(resp);

    try std.testing.expectEqual(@as(u32, 1), f.handler.barrier_calls.load(.acquire));
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const result = field(doc.root, "result").?;
    const text = field(field(result, "content").?.arr[0], "text").?.str;
    try std.testing.expectEqualStrings("user barrier", text);
}

// ----------------------------------------------------------------------------
// client_protocol_version outlives the initialize message
// ----------------------------------------------------------------------------

test "client_protocol_version stays valid after the initialize message is freed" {
    const a = std.testing.allocator;
    var h: WireHandler = .{ .allocator = a };
    var server = try mcp.Server.init(a, .{ .name = "t", .version = "1" }, h.handler());
    defer server.deinit();

    for ([_][]const u8{ "2025-06-18", "2025-11-25" }) |version| {
        const msg = try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"{s}","capabilities":{{}},"clientInfo":{{"name":"t","version":"1"}}}}}}
        , .{version});
        const resp = try server.processMessage(msg);
        if (resp) |r| a.free(r);
        // Scribble over and free the request bytes the parsed message
        // could point into.
        @memset(msg, 'X');
        a.free(msg);

        try std.testing.expectEqualStrings(version, server.client_protocol_version.?);
    }
}

// ----------------------------------------------------------------------------
// String request ids can be cancelled
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

test "notifications/cancelled with a string requestId cancels that request" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var result: CallResult = .{};
    const t = try std.Thread.spawn(.{}, runCall, .{
        &f.server,
        \\{"jsonrpc":"2.0","id":"req-\"7\"","method":"tools/call","params":{"name":"wait_cancel"}}
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
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"req-\"7\"","reason":"user"}}
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

test "string and integer request ids are cancelled independently" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var result: CallResult = .{};
    const t = try std.Thread.spawn(.{}, runCall, .{
        &f.server,
        \\{"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"wait_cancel"}}
        ,
        &result,
    });

    var spins: u32 = 0;
    while (!f.handler.started.load(.acquire)) : (spins += 1) {
        if (spins > 5000) break;
        testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    // Integer 7 is a different id from string "7": this must not cancel.
    _ = try f.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}
    );
    testIo().sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try std.testing.expect(result.response == null and result.err == null);

    _ = try f.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"7"}}
    );
    t.join();
    try std.testing.expect(result.err == null);
    if (result.response) |r| {
        defer a.free(r);
        return error.TestCancelledRequestAnswered;
    }
}

// ----------------------------------------------------------------------------
// Handler results cannot break stdio framing
// ----------------------------------------------------------------------------

test "pretty-printed handler result is sent on one line" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    )).?;
    defer a.free(resp);
    try expectOneLine(resp);

    var doc = try parseResponse(resp);
    defer doc.deinit();
    const tool = field(field(doc.root, "result").?, "tools").?.arr[0];
    try std.testing.expectEqualStrings("barrier", field(tool, "name").?.str);
    try std.testing.expectEqualStrings("line one\nline two", field(tool, "description").?.str);
}

test "pretty-printed handler result in a batch is sent on one line" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\[{"jsonrpc":"2.0","id":2,"method":"tools/list"},{"jsonrpc":"2.0","id":3,"method":"ping"}]
    )).?;
    defer a.free(resp);
    try expectOneLine(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.root.arr.len);
}

test "handler result that is not one JSON value is an Internal error" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"not_json"}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"two_values"}}
        ,
    }) |msg| {
        const resp = (try f.server.processMessage(msg)).?;
        defer a.free(resp);
        try expectOneLine(resp);
        var doc = try parseResponse(resp);
        defer doc.deinit();
        try std.testing.expectEqualStrings("4", field(doc.root, "id").?.num.lexeme);
        const e = field(doc.root, "error") orelse return error.TestExpectedError;
        try std.testing.expectEqualStrings("-32603", field(e, "code").?.num.lexeme);
    }
}
