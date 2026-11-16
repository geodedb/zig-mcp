//! Coverage-guided fuzz target for the JSON-RPC dispatcher.
//!
//! `zig build test` runs it once over the corpus; `zig build test --fuzz`
//! (the CI `fuzz` job) mutates inputs for as long as it is allowed to run.
//! Every input goes through a real `Server.processMessage` on an initialized
//! server whose handler echoes request data back into results and error
//! details. Properties checked for every input:
//!
//! - no crash, no leak (a leak-checking allocator per input);
//! - a response, when there is one, is a single valid JSON value with no
//!   raw newline (stdio framing);
//! - a message without an `id` member never gets a response.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

const EchoHandler = struct {
    allocator: std.mem.Allocator,

    fn handler(self: *EchoHandler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *EchoHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listTools(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
        // Echo the client-controlled cursor raw: a result that is not one
        // JSON value must become an Internal error, never a bad response.
        return std.fmt.allocPrint(self_(ctx).allocator, "{{\"tools\":[],\"nextCursor\":{s}}}", .{cursor orelse "null"});
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, args_json: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "echo")) {
            // args_json is serialized by the server, so it is valid JSON.
            return std.fmt.allocPrint(self.allocator, "{{\"content\":[],\"structuredContent\":{s}}}", .{args_json});
        }
        try mcp.setErrorDetail(self.allocator, name, args_json);
        return error.ToolNotFound;
    }

    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"resources\":[]}");
    }

    fn readResource(ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
        try mcp.setErrorDetail(self_(ctx).allocator, uri, null);
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
        try mcp.setErrorDetail(self_(ctx).allocator, name, null);
        return error.PromptNotFound;
    }

    fn complete(ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8 {
        return std.fmt.allocPrint(self_(ctx).allocator, "{{\"completion\":{{\"values\":[]}},\"echo\":{s}}}", .{params_json});
    }

    fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

fn hasTopLevelId(input: []const u8) bool {
    var err = json.ParseError.init();
    var doc = json.parse(std.heap.page_allocator, input, .{}, &err) catch return true;
    defer doc.deinit();
    if (doc.root != .obj) return true;
    for (doc.root.obj) |m| {
        if (std.mem.eql(u8, m.k, "id")) return true;
    }
    return false;
}

fn checkOne(input: []const u8) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc.deinit() == .leak) @panic("leak in dispatcher");
    const a = debug_alloc.allocator();

    var h: EchoHandler = .{ .allocator = a };
    var server = try mcp.Server.init(a, .{ .name = "fuzz", .version = "1" }, h.handler());
    defer server.deinit();

    const init_resp = try server.processMessage(
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"f","version":"1"}}}
    );
    if (init_resp) |r| a.free(r);
    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    const resp = server.processMessage(input) catch |e| switch (e) {
        error.OutOfMemory => return,
        else => return e,
    };
    const r = resp orelse return;
    defer a.free(r);

    if (std.mem.indexOfAny(u8, r, "\r\n") != null) @panic("response contains a raw newline");
    var err = json.ParseError.init();
    var doc = json.parse(a, r, .{ .max_nodes = std.math.maxInt(u32), .max_bytes = std.math.maxInt(usize) }, &err) catch
        @panic("response is not valid JSON");
    doc.deinit();

    // A single, well-formed notification must never be answered.
    if (input.len > 0 and input[0] == '{' and !hasTopLevelId(input)) {
        if (std.mem.indexOf(u8, r, "\"id\":null") == null) @panic("notification answered");
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    try checkOne(buf[0..n]);
}

/// Encodes `s` the way `std.testing.Smith.slice` reads it from a corpus
/// entry: a little-endian u32 length followed by the bytes.
fn seed(comptime s: []const u8) []const u8 {
    const encoded = comptime blk: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, s.len, .little);
        break :blk len ++ s[0..s.len].*;
    };
    return &encoded;
}

test "fuzz: dispatcher responses are always valid single-line JSON" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        seed(
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a\"b\u0001","arguments":{"x":"\n"}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":"s\"\\","method":"tools/call","params":{"name":"echo","arguments":{"k":[1,2,{"z":null}]}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"]}\n{"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"nope"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"file:///\u007f\""}}
        ),
        seed(
            \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"x"},{"jsonrpc":"2.0","id":null,"method":"ping"}]
        ),
        seed(
            \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"abc"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":4,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"p"}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"\t"}}
        ),
        seed("not json"),
    } });
}
