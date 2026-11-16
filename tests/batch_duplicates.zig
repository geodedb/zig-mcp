//! Duplicate request ids inside one batch (SONNY-6644).
//!
//! JSON-RPC 2.0 lets a server process batch items concurrently, so the
//! in-flight duplicate check alone made "which duplicate is rejected"
//! depend on timing. The rule is now deterministic: within a batch the
//! first request with an id (in batch order) runs, and every later request
//! reusing that id is answered with -32600 and never dispatched. Integer
//! and string ids are distinct; notifications and client responses carry
//! no request id and are not counted. Every test drives a real batch
//! through `Server.processMessage`, sequentially and on the worker pool.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

const CountingHandler = struct {
    allocator: std.mem.Allocator,
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn handler(self: *CountingHandler) mcp.Handler {
        return .{
            .ctx = @ptrCast(self),
            .listTools = listTools,
            .callTool = callTool,
            .listResources = listResources,
            .readResource = readResource,
            .listResourceTemplates = listResourceTemplates,
            .subscribeResource = noopUri,
            .unsubscribeResource = noopUri,
            .listPrompts = listPrompts,
            .getPrompt = getPrompt,
            .complete = complete,
            .setLogLevel = noopUri,
        };
    }

    fn self_(ctx: ?*anyopaque) *CountingHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        _ = self.calls.fetchAdd(1, .acq_rel);
        return std.fmt.allocPrint(self.allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{name});
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"tools\":[]}");
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
    fn noopUri(_: ?*anyopaque, _: []const u8) anyerror!void {}
    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"prompts\":[]}");
    }
    fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
        return error.PromptNotFound;
    }
    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"completion\":{\"values\":[]}}");
    }
};

const Fixture = struct {
    handler: CountingHandler,
    server: mcp.Server,

    fn init(self: *Fixture, allocator: std.mem.Allocator, worker_threads: u16) !void {
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "batch-dup",
            .version = "1",
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

/// What a batch item's response must be: a result whose text names the
/// tool that ran, or a -32600 error.
const Expect = union(enum) { ran: []const u8, duplicate };

fn idText(v: json.Value) []const u8 {
    return switch (v) {
        .num => |n| n.lexeme,
        .str => |s| s,
        else => "?",
    };
}

fn expectBatch(response: []const u8, expected_ids: []const []const u8, expected: []const Expect) !void {
    var doc = try parse(response);
    defer doc.deinit();
    try std.testing.expect(doc.root == .arr);
    try std.testing.expectEqual(expected.len, doc.root.arr.len);
    for (doc.root.arr, expected, expected_ids) |item, want, want_id| {
        try std.testing.expectEqualStrings(want_id, idText(field(item, "id").?));
        switch (want) {
            .ran => |tool| {
                const result = field(item, "result") orelse {
                    std.debug.print("expected {s} to run, got: {s}\n", .{ tool, response });
                    return error.TestExpectedResult;
                };
                const text = field(field(result, "content").?.arr[0], "text").?.str;
                try std.testing.expectEqualStrings(tool, text);
            },
            .duplicate => {
                const e = field(item, "error") orelse {
                    std.debug.print("expected a duplicate rejection, got: {s}\n", .{response});
                    return error.TestExpectedDuplicateRejected;
                };
                try std.testing.expectEqualStrings("-32600", field(e, "code").?.num.lexeme);
            },
        }
    }
}

const batch_int =
    \\[{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"first"}},
    \\ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"second"}},
    \\ {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"other"}},
    \\ {"jsonrpc":"2.0","id":7,"method":"ping"}]
;

fn runIntBatch(worker_threads: u16) !void {
    const a = std.testing.allocator;
    // Repeat so a timing-dependent outcome on the pool would show up.
    for (0..50) |_| {
        var f: Fixture = undefined;
        try f.init(a, worker_threads);
        defer f.deinit();
        const resp = (try f.server.processMessage(batch_int)).?;
        defer a.free(resp);
        try expectBatch(resp, &.{ "7", "7", "8", "7" }, &.{ .{ .ran = "first" }, .duplicate, .{ .ran = "other" }, .duplicate });
        // Rejected duplicates are never dispatched.
        try std.testing.expectEqual(@as(u32, 2), f.handler.calls.load(.acquire));
    }
}

test "batch: the first of duplicate integer ids runs, later ones get -32600 (sequential)" {
    try runIntBatch(0);
}

test "batch: the first of duplicate integer ids runs, later ones get -32600 (worker pool)" {
    try runIntBatch(4);
}

test "batch: duplicate string ids; integer 7 and string \"7\" are distinct" {
    const a = std.testing.allocator;
    for ([_]u16{ 0, 4 }) |workers| {
        for (0..20) |_| {
            var f: Fixture = undefined;
            try f.init(a, workers);
            defer f.deinit();
            const resp = (try f.server.processMessage(
                \\[{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"a"}},
                \\ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"b"}},
                \\ {"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"c"}},
                \\ {"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"d"}}]
            )).?;
            defer a.free(resp);
            try expectBatch(resp, &.{ "x", "7", "7", "x" }, &.{ .{ .ran = "a" }, .{ .ran = "b" }, .{ .ran = "c" }, .duplicate });
        }
    }
}

test "batch: notifications and client responses do not count as request ids" {
    const a = std.testing.allocator;
    for ([_]u16{ 0, 4 }) |workers| {
        var f: Fixture = undefined;
        try f.init(a, workers);
        defer f.deinit();
        const resp = (try f.server.processMessage(
            \\[{"jsonrpc":"2.0","id":5,"result":{}},
            \\ {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":1}},
            \\ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"only"}}]
        )).?;
        defer a.free(resp);
        try expectBatch(resp, &.{"5"}, &.{.{ .ran = "only" }});
    }
}
