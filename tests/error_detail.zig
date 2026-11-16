//! Handler-supplied JSON-RPC error message and data (SONNY-6585).
//!
//! A handler that fails calls `mcp.setErrorDetail` before returning its
//! error so the response carries a useful `message` (for example
//! "Unknown tool: X", MCP 2025-11-25 server/tools) and `data` (for example
//! `{"uri": ...}`, MCP 2025-11-25 server/resources). The library owns and
//! frees the detail. Every test drives a real JSON-RPC round trip through
//! `Server.processMessage` under `std.testing.allocator`, so a detail the
//! library does not free fails the test as a leak.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

const DetailHandler = struct {
    allocator: std.mem.Allocator,

    fn handler(self: *DetailHandler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *DetailHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        const self = self_(ctx);
        // Sets a detail and then succeeds: the detail must not leak and must
        // not be attached to a later, unrelated error.
        try mcp.setErrorDetail(self.allocator, "stale detail", "{\"stale\":true}");
        return self.allocator.dupe(u8, "{\"tools\":[]}");
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "plain_fail")) return error.ToolNotFound;
        if (std.mem.eql(u8, name, "bad_data")) {
            mcp.setErrorDetail(self.allocator, "has bad data", "{not json") catch |e| {
                if (e == error.InvalidErrorData) return error.ToolNotFound;
                return e;
            };
            return error.TestSetErrorDetailAcceptedInvalidJson;
        }
        if (std.mem.eql(u8, name, "tricky")) {
            try mcp.setErrorDetail(self.allocator, "quote \" backslash \\ newline \n tab \t ctl \x01 bad \xff end é", null);
            return error.InvalidParams;
        }
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown tool: {s}", .{name});
        defer self.allocator.free(msg);
        try mcp.setErrorDetail(self.allocator, msg, null);
        return error.ToolNotFound;
    }

    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resources\":[]}");
    }

    fn readResource(ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
        const self = self_(ctx);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.allocator);
        try data.appendSlice(self.allocator, "{\"uri\":");
        const quoted = try json.stringify(self.allocator, .{ .str = uri });
        defer self.allocator.free(quoted);
        try data.appendSlice(self.allocator, quoted);
        try data.append(self.allocator, '}');
        try mcp.setErrorDetail(self.allocator, "Resource not found", data.items);
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

    fn getPrompt(ctx: ?*anyopaque, name: []const u8, _: ?[]const u8) anyerror![]const u8 {
        const self = self_(ctx);
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown prompt: {s}", .{name});
        defer self.allocator.free(msg);
        try mcp.setErrorDetail(self.allocator, msg, null);
        return error.PromptNotFound;
    }

    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"completion\":{\"values\":[]}}");
    }

    fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

const Fixture = struct {
    handler: DetailHandler,
    server: mcp.Server,

    fn init(self: *Fixture, allocator: std.mem.Allocator, worker_threads: u16) !void {
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "detail-test",
            .version = "1.0.0",
            .worker_threads = worker_threads,
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

const ErrorView = struct {
    code: i64,
    message: []const u8,
    data: ?json.Value,
};

fn errorOf(doc: *const json.Document) !ErrorView {
    const e = field(doc.root, "error") orelse return error.TestExpectedError;
    const code = field(e, "code").?;
    const message = field(e, "message").?;
    try std.testing.expect(message == .str);
    return .{
        .code = try std.fmt.parseInt(i64, code.num.lexeme, 10),
        .message = message.str,
        .data = field(e, "data"),
    };
}

test "SONNY-6585: handler message reaches the wire for an unknown tool" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"invalid_tool_name"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqual(@as(i64, -32602), e.code);
    try std.testing.expectEqualStrings("Unknown tool: invalid_tool_name", e.message);
    try std.testing.expect(e.data == null);
}

test "SONNY-6585: handler data reaches the wire for a missing resource" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"file:///nonexistent.txt"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqual(@as(i64, -32002), e.code);
    try std.testing.expectEqualStrings("Resource not found", e.message);
    const uri = field(e.data.?, "uri").?;
    try std.testing.expectEqualStrings("file:///nonexistent.txt", uri.str);
}

test "SONNY-6585: handler message for an unknown prompt" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"p\"q"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqual(@as(i64, -32602), e.code);
    try std.testing.expectEqualStrings("Unknown prompt: p\"q", e.message);
}

test "SONNY-6585: error message is JSON-escaped" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"tricky"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqual(@as(i64, -32602), e.code);
    try std.testing.expectEqualStrings("quote \" backslash \\ newline \n tab \t ctl \x01 bad \u{FFFD} end é", e.message);
}

test "SONNY-6585: setErrorDetail rejects data that is not one JSON value" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"bad_data"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqual(@as(i64, -32602), e.code);
    // The rejected detail was not stored, so the default message is used.
    try std.testing.expectEqualStrings("ToolNotFound", e.message);
    try std.testing.expect(e.data == null);
}

test "SONNY-6585: detail set by a successful handler is freed and not reused" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const ok = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":9,"method":"tools/list"}
    )).?;
    defer a.free(ok);
    var ok_doc = try parseResponse(ok);
    defer ok_doc.deinit();
    try std.testing.expect(field(ok_doc.root, "result") != null);

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"plain_fail"}}
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    const e = try errorOf(&doc);
    try std.testing.expectEqualStrings("ToolNotFound", e.message);
    try std.testing.expect(e.data == null);
}

test "SONNY-6585: detail set for a notification is freed, nothing is sent" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const resp = try f.server.processMessage(
        \\{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"file:///gone"}}
    );
    try std.testing.expect(resp == null);
}

test "SONNY-6585: parallel batch items each carry their own detail" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 4);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"t1"}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"t2"}},{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"t3"}},{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"t4"}},{"jsonrpc":"2.0","id":5,"method":"tools/list"},{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"plain_fail"}}]
    )).?;
    defer a.free(resp);
    var doc = try parseResponse(resp);
    defer doc.deinit();
    try std.testing.expect(doc.root == .arr);
    try std.testing.expectEqual(@as(usize, 6), doc.root.arr.len);
    for (doc.root.arr) |item| {
        const id = try std.fmt.parseInt(u8, field(item, "id").?.num.lexeme, 10);
        if (id == 5) {
            try std.testing.expect(field(item, "result") != null);
            continue;
        }
        const e = field(item, "error").?;
        const message = field(e, "message").?.str;
        if (id == 6) {
            try std.testing.expectEqualStrings("ToolNotFound", message);
            try std.testing.expect(field(e, "data") == null);
            continue;
        }
        var expected_buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "Unknown tool: t{d}", .{id});
        try std.testing.expectEqualStrings(expected, message);
    }
}
