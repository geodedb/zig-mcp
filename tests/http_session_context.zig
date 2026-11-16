//! Streamable HTTP sessions: explicit session context and idle expiry
//! (SONNY-6644).
//!
//! A handler that wants to reach its client later (from a background
//! thread, after the request returned) retains the session it is serving
//! with `Server.retainCurrentSession()` and sends inside
//! `Server.enterSession(ref)`. Messages sent that way reach only that
//! client's GET stream. Idle sessions expire after
//! `ServerOptions.http_session_idle_timeout_ms`, after which their id gets
//! 404. Real server on a loopback port, two raw-socket clients.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");
const http = @import("http_test_client.zig");

const testIo = http.testIo;

const CaptureHandler = struct {
    allocator: std.mem.Allocator,
    server: *mcp.Server = undefined,
    captured: ?mcp.SessionRef = null,

    fn handler(self: *CaptureHandler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *CaptureHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "capture")) {
            if (self.captured) |old| old.release();
            self.captured = self.server.retainCurrentSession() orelse return error.NoSession;
            return self.allocator.dupe(u8, "{\"content\":[]}");
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

const Fixture = struct {
    allocator: std.mem.Allocator,
    handler: CaptureHandler,
    server: mcp.Server,
    port: u16,

    fn init(self: *Fixture, allocator: std.mem.Allocator, idle_timeout_ms: u32) !void {
        self.allocator = allocator;
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "http-ctx",
            .version = "1",
            .http_port = 0,
            .http_session_idle_timeout_ms = idle_timeout_ms,
        }, self.handler.handler());
        self.handler.server = &self.server;
        errdefer self.server.deinit();
        self.port = try self.server.serveHttp();
    }

    fn deinit(self: *Fixture) void {
        if (self.handler.captured) |ref| ref.release();
        self.server.stop();
        self.server.deinit();
    }

    fn connect(self: *Fixture) ![]u8 {
        const a = self.allocator;
        const r = try http.post(a, self.port, null,
            \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        );
        defer a.free(r.body);
        const sid = r.session_id orelse return error.TestNoSessionId;
        var n = try http.post(a, self.port, sid,
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
        n.deinit(a);
        return sid;
    }

    fn openGet(self: *Fixture, sid: []const u8) !http.Conn {
        var r = try http.request(self.allocator, self.port, "GET", sid, .sse, null, "");
        defer r.head.deinit(self.allocator);
        errdefer r.conn.close();
        try std.testing.expectEqual(@as(u16, 200), r.head.status);
        return r.conn;
    }
};

test "a retained session context sends only to that client's stream" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();

    const sid_a = try f.connect();
    defer a.free(sid_a);
    const sid_b = try f.connect();
    defer a.free(sid_b);
    var get_a = try f.openGet(sid_a);
    defer get_a.close();
    var get_b = try f.openGet(sid_b);
    defer get_b.close();

    var cap = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture"}}
    );
    cap.deinit(a);
    const ref = f.handler.captured.?;
    try std.testing.expectEqualStrings(sid_a, ref.id());

    // Later, from this (non-request) thread:
    {
        const scope = f.server.enterSession(ref);
        defer scope.exit();
        try f.server.emitLog("info", "bg", "for-a-only");
    }
    const ev = (try get_a.nextEvent(3000)) orelse return error.TestNoEvent;
    defer a.free(ev);
    try std.testing.expect(std.mem.indexOf(u8, ev, "for-a-only") != null);
    if (try get_b.nextEvent(300)) |leak| {
        defer a.free(leak);
        return error.TestCrossSessionLeak;
    }

    // After the session ends, the retained context can no longer send.
    var d = try http.request(a, f.port, "DELETE", sid_a, .json, null, "");
    d.head.deinit(a);
    d.conn.close();
    {
        const scope = f.server.enterSession(ref);
        defer scope.exit();
        try std.testing.expectError(error.NoSession, f.server.emitLog("info", "bg", "too late"));
    }
}

test "idle sessions expire and their id gets 404" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 200);
    defer f.deinit();

    const sid_a = try f.connect();
    defer a.free(sid_a);
    testIo().sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};

    var r = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u16, 404), r.status);

    // An active session is kept alive by its requests.
    const sid_b = try f.connect();
    defer a.free(sid_b);
    for (0..5) |_| {
        testIo().sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        var p = try http.post(a, f.port, sid_b,
            \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        );
        defer p.deinit(a);
        try std.testing.expectEqual(@as(u16, 200), p.status);
    }
}

test "a client that never finishes its request is answered 408 and dropped" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);
    defer f.deinit();
    f.server.options.http_request_timeout_ms = 200;

    // Promises a 10-byte body and never sends it.
    var conn = try http.Conn.open(a, f.port);
    defer conn.close();
    try conn.send("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n");
    var head = try conn.readHead(3000);
    defer head.deinit(a);
    try std.testing.expectEqual(@as(u16, 408), head.status);
    try std.testing.expect(try conn.closedWithin(3000));

    // Other clients are unaffected.
    const sid = try f.connect();
    a.free(sid);
}

fn releaseLater(ref: mcp.SessionRef, released: *std.atomic.Value(bool)) void {
    testIo().sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};
    released.store(true, .release);
    ref.release();
}

test "Server.deinit waits for SessionRefs still held by other threads" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a, 0);

    const sid = try f.connect();
    defer a.free(sid);
    var cap = try http.post(a, f.port, sid,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture"}}
    );
    cap.deinit(a);
    const ref = f.handler.captured.?;
    f.handler.captured = null;

    // Another thread still holds the reference while the server shuts down.
    var released = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, releaseLater, .{ ref, &released });
    defer t.join();

    f.server.stop();
    f.server.deinit();
    // deinit returned only after the reference was released, so the
    // release did not touch freed memory.
    try std.testing.expect(released.load(.acquire));
}
