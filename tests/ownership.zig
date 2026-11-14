//! Handler result ownership tests (SONNY-6531).
//!
//! Every `Handler` callback that returns `[]const u8` hands the slice to the
//! server, which frees it with `Server.allocator` once the JSON-RPC response
//! is built. These tests drive the real `Server.processMessage` round trip
//! under the strict `std.testing.allocator` with a handler that returns a
//! fresh heap allocation from every callback: a result the server does not
//! free is reported as a leak and fails the test.

const std = @import("std");
const mcp = @import("mcp");

/// A handler whose every string-returning callback returns bytes allocated
/// with `allocator` (the same allocator the server is built with), the way a
/// real server builds responses from live data.
const HeapHandler = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn handler(self: *HeapHandler) mcp.Handler {
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

    fn owned(ctx: ?*anyopaque, comptime text: []const u8) ![]const u8 {
        const self: *HeapHandler = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return self.allocator.dupe(u8, text);
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"tools\":[]}");
    }

    fn callTool(ctx: ?*anyopaque, _: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        return owned(ctx, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}");
    }

    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"resources\":[]}");
    }

    fn readResource(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return owned(ctx, "{\"contents\":[{\"uri\":\"file:///a\",\"text\":\"hello\"}]}");
    }

    fn listResourceTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
        return owned(ctx, "{\"resourceTemplates\":[]}");
    }

    fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"prompts\":[]}");
    }

    fn getPrompt(ctx: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"messages\":[]}");
    }

    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return owned(ctx, "{\"completion\":{\"values\":[]}}");
    }

    fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

fn initServer(server: *mcp.Server) !void {
    const allocator = std.testing.allocator;
    const init_response = try server.processMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    );
    if (init_response) |r| allocator.free(r);
    const initialized = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    try std.testing.expect(initialized == null);
}

/// Sends one request through a fresh server backed by `HeapHandler`, checks
/// that it succeeded with `expected` in the result, and lets the testing
/// allocator report anything left unfreed.
fn expectRoundTripFreesResult(request: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var heap_handler = HeapHandler{ .allocator = allocator };
    var server = try mcp.Server.init(allocator, .{
        .name = "ownership-test",
        .version = "1.0.0",
    }, heap_handler.handler());
    defer server.deinit();

    try initServer(&server);

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"result\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, expected) != null);
    try std.testing.expectEqual(@as(usize, 1), heap_handler.calls);
}

test "tools/list result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    , "\"tools\":[]");
}

test "tools/call result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"x":1}}}
    , "\"text\":\"ok\"");
}

test "resources/list result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"resources/list"}
    , "\"resources\":[]");
}

test "resources/read result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"file:///a"}}
    , "\"text\":\"hello\"");
}

test "resources/templates/list result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"resources/templates/list"}
    , "\"resourceTemplates\":[]");
}

test "prompts/list result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"prompts/list"}
    , "\"prompts\":[]");
}

test "prompts/get result is freed by the server" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"p"}}
    , "\"messages\":[]");
}

test "prompts/get with arguments frees the serialized arguments" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"p","arguments":{"a":"b"}}}
    , "\"messages\":[]");
}

test "completion/complete frees its result and the serialized params" {
    try expectRoundTripFreesResult(
        \\{"jsonrpc":"2.0","id":2,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"p"},"argument":{"name":"a","value":"v"}}}
    , "\"completion\":");
}

test "a notification frees the handler result" {
    const allocator = std.testing.allocator;
    var heap_handler = HeapHandler{ .allocator = allocator };
    var server = try mcp.Server.init(allocator, .{
        .name = "ownership-test",
        .version = "1.0.0",
    }, heap_handler.handler());
    defer server.deinit();

    try initServer(&server);

    // No id: the server must still free the result it never sends.
    const response = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"file:///a"}}
    );
    try std.testing.expect(response == null);
    try std.testing.expectEqual(@as(usize, 1), heap_handler.calls);
}

test "batch of handler calls frees every result" {
    const allocator = std.testing.allocator;
    var heap_handler = HeapHandler{ .allocator = allocator };
    var server = try mcp.Server.init(allocator, .{
        .name = "ownership-test",
        .version = "1.0.0",
        .worker_threads = 0,
    }, heap_handler.handler());
    defer server.deinit();

    try initServer(&server);

    const response = try server.processMessage(
        \\[{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"file:///a"}},{"jsonrpc":"2.0","id":3,"method":"prompts/list"},{"jsonrpc":"2.0","id":4,"method":"resources/templates/list"}]
    );
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expectEqual(@as(usize, 3), heap_handler.calls);
}

test "DemoHandler results are freed without leaks or invalid frees" {
    // DemoHandler is the library's reference handler; every callback that
    // returns bytes must follow the ownership contract.
    const allocator = std.testing.allocator;
    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "ownership-test",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    try initServer(&server);

    const requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"resources/list"}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"resources/templates/list"}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"prompts/list"}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"p"}}}
        ,
    };
    for (requests) |request| {
        const response = try server.processMessage(request);
        defer if (response) |r| allocator.free(r);
        try std.testing.expect(response != null);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "\"result\":") != null);
    }
}
