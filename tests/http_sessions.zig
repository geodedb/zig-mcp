//! Streamable HTTP transport: per-client sessions (SONNY-6644).
//!
//! MCP 2025-11-25 basic/transports, "Streamable HTTP": the server assigns
//! an `MCP-Session-Id` at initialization; every later request carries it;
//! a POSTed request may be answered with an SSE stream that carries
//! request-related server messages before the response; a GET opens a
//! stream for other server messages; the server "MUST NOT broadcast the
//! same message across multiple streams"; DELETE ends a session, after
//! which its id gets 404; replay after `Last-Event-ID` never delivers
//! messages from another stream.
//!
//! Every test runs a real server on a loopback port and two concurrent
//! raw-socket clients, A and B, and proves neither sees the other's
//! messages.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");
const http = @import("http_test_client.zig");

const testIo = http.testIo;

const SessionHandler = struct {
    allocator: std.mem.Allocator,
    server: *mcp.Server = undefined,
    started: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn handler(self: *SessionHandler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *SessionHandler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn text(self: *SessionHandler, s: []const u8) ![]const u8 {
        const quoted = try json.stringify(self.allocator, .{ .str = s });
        defer self.allocator.free(quoted);
        return std.fmt.allocPrint(self.allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}]}}", .{quoted});
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, args: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "ask_roots")) {
            // A server-to-client request made while serving this client.
            const roots = try self.server.requestRoots();
            defer self.allocator.free(roots);
            return self.text(roots);
        }
        if (std.mem.eql(u8, name, "log")) {
            // args carries a per-client marker so a leak is visible.
            try self.server.emitLog("info", "test", args);
            return self.text("logged");
        }
        if (std.mem.eql(u8, name, "wait_cancel")) {
            _ = self.started.fetchAdd(1, .acq_rel);
            var waited_ms: u32 = 0;
            while (!cancel.isCancelled()) : (waited_ms += 1) {
                if (waited_ms >= 5000) return error.Timeout;
                testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
            return error.Cancelled;
        }
        if (std.mem.eql(u8, name, "known")) return self.text("ok");
        return error.ToolNotFound;
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
    allocator: std.mem.Allocator,
    handler: SessionHandler,
    server: mcp.Server,
    port: u16,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{
            .name = "http-sessions",
            .version = "1",
            .http_port = 0,
        }, self.handler.handler());
        self.handler.server = &self.server;
        errdefer self.server.deinit();
        self.port = try self.server.serveHttp();
    }

    fn deinit(self: *Fixture) void {
        self.server.stop();
        self.server.deinit();
    }

    /// initialize (+ notifications/initialized) as a new client; returns
    /// the session id the server assigned.
    fn connect(self: *Fixture, capabilities: []const u8) ![]u8 {
        const a = self.allocator;
        const body = try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":0,"method":"initialize","params":{{"protocolVersion":"2025-11-25","capabilities":{s},"clientInfo":{{"name":"t","version":"1"}}}}}}
        , .{capabilities});
        defer a.free(body);
        const r = try http.post(a, self.port, null, body);
        defer a.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        const sid = r.session_id orelse return error.TestNoSessionId;
        var n = try http.post(a, self.port, sid,
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
        defer n.deinit(a);
        try std.testing.expectEqual(@as(u16, 202), n.status);
        return sid;
    }

    fn openGet(self: *Fixture, sid: []const u8, last_event_id: ?u64) !http.Conn {
        var r = try http.request(self.allocator, self.port, "GET", sid, .sse, last_event_id, "");
        defer r.head.deinit(self.allocator);
        errdefer r.conn.close();
        try std.testing.expectEqual(@as(u16, 200), r.head.status);
        try std.testing.expect(r.head.isSse());
        return r.conn;
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

fn expectSilent(conn: *http.Conn, who: []const u8) !void {
    if (try conn.nextEvent(300)) |ev| {
        defer std.testing.allocator.free(ev);
        std.debug.print("{s} received a message meant for another client: {s}\n", .{ who, ev });
        return error.TestCrossSessionLeak;
    }
}

// ----------------------------------------------------------------------------
// Session lifecycle
// ----------------------------------------------------------------------------

test "initialize gives each client its own stable Mcp-Session-Id" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);
    try std.testing.expect(!std.mem.eql(u8, sid_a, sid_b));
    for (sid_a) |c| try std.testing.expect(c >= 0x21 and c <= 0x7e);

    var r = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    // A non-initialize response never hands out a different session.
    if (r.session_id) |echo| try std.testing.expectEqualStrings(sid_a, echo);
}

test "requests without a session get 400, unknown sessions 404" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var r1 = try http.post(a, f.port, null,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer r1.deinit(a);
    try std.testing.expectEqual(@as(u16, 400), r1.status);

    var r2 = try http.post(a, f.port, "0123456789abcdef0123456789abcdef",
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer r2.deinit(a);
    try std.testing.expectEqual(@as(u16, 404), r2.status);

    var g = try http.request(a, f.port, "GET", null, .sse, null, "");
    defer g.conn.close();
    defer g.head.deinit(a);
    try std.testing.expectEqual(@as(u16, 400), g.head.status);
}

test "initialization state and capabilities are per session" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{\"roots\":{}}");
    defer a.free(sid_a);

    // B initializes but never sends notifications/initialized.
    var init_b = try http.post(a, f.port, null,
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"b","version":"1"}}}
    );
    defer init_b.deinit(a);
    const sid_b = init_b.session_id.?;

    var list_b = try http.post(a, f.port, sid_b,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer list_b.deinit(a);
    var doc_b = try parse(list_b.body);
    defer doc_b.deinit();
    try std.testing.expectEqualStrings("-32003", field(field(doc_b.root, "error").?, "code").?.num.lexeme);

    var list_a = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer list_a.deinit(a);
    var doc_a = try parse(list_a.body);
    defer doc_a.deinit();
    try std.testing.expect(field(doc_a.root, "result") != null);
}

test "DELETE ends the session: its stream closes and its id gets 404" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);
    var get_a = try f.openGet(sid_a, null);
    defer get_a.close();
    var get_b = try f.openGet(sid_b, null);
    defer get_b.close();

    var d = try http.request(a, f.port, "DELETE", sid_a, .json, null, "");
    defer d.conn.close();
    defer d.head.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), d.head.status);

    try std.testing.expect(try get_a.closedWithin(3000));
    try std.testing.expect(!try get_b.closedWithin(200));

    var r = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u16, 404), r.status);

    var ok = try http.post(a, f.port, sid_b,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer ok.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), ok.status);
}

// ----------------------------------------------------------------------------
// Server-to-client messages reach only their own client
// ----------------------------------------------------------------------------

const PostResult = struct {
    reply: ?http.Reply = null,
    err: ?anyerror = null,
};

test "a server-to-client request during a tool call reaches only the calling client" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{\"roots\":{}}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{\"roots\":{}}");
    defer a.free(sid_b);
    var get_a = try f.openGet(sid_a, null);
    defer get_a.close();
    var get_b = try f.openGet(sid_b, null);
    defer get_b.close();

    // A calls a tool that asks A for its roots; the call stays open as an
    // SSE stream that carries the roots/list request.
    var call = try http.request(a, f.port, "POST", sid_a, .sse, null,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"ask_roots"}}
    );
    defer call.conn.close();
    defer call.head.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), call.head.status);
    try std.testing.expect(call.head.isSse());

    const req_ev = (try call.conn.nextEvent(3000)) orelse return error.TestNoServerRequest;
    defer a.free(req_ev);
    var req_doc = try parse(req_ev);
    defer req_doc.deinit();
    try std.testing.expectEqualStrings("roots/list", field(req_doc.root, "method").?.str);
    const req_id = field(req_doc.root, "id").?.num.lexeme;

    // While A's call is blocked, B is served concurrently.
    var ping_b = try http.post(a, f.port, sid_b,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer ping_b.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), ping_b.status);

    // Neither GET stream carried the request.
    try expectSilent(&get_b, "B's GET stream");
    try expectSilent(&get_a, "A's GET stream");

    // B answering A's request id must not resolve it.
    const forged = try std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"roots":[{{"uri":"file:///b-secret"}}]}}}}
    , .{req_id});
    defer a.free(forged);
    var fr = try http.post(a, f.port, sid_b, forged);
    defer fr.deinit(a);
    try std.testing.expectEqual(@as(u16, 202), fr.status);

    const answer = try std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"roots":[{{"uri":"file:///a-home"}}]}}}}
    , .{req_id});
    defer a.free(answer);
    var ar = try http.post(a, f.port, sid_a, answer);
    defer ar.deinit(a);
    try std.testing.expectEqual(@as(u16, 202), ar.status);

    const result_ev = (try call.conn.nextEvent(3000)) orelse return error.TestNoToolResult;
    defer a.free(result_ev);
    var res_doc = try parse(result_ev);
    defer res_doc.deinit();
    try std.testing.expectEqualStrings("10", field(res_doc.root, "id").?.num.lexeme);
    const txt = field(field(field(res_doc.root, "result").?, "content").?.arr[0], "text").?.str;
    try std.testing.expect(std.mem.indexOf(u8, txt, "a-home") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "b-secret") == null);
    // The POST stream ends after the response.
    try std.testing.expect(try call.conn.closedWithin(3000));
}

test "notifications sent while serving a request reach only that client" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);
    var get_b = try f.openGet(sid_b, null);
    defer get_b.close();

    var call = try http.request(a, f.port, "POST", sid_a, .sse, null,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"log","arguments":{"marker":"secret-of-a"}}}
    );
    defer call.conn.close();
    defer call.head.deinit(a);

    const log_ev = (try call.conn.nextEvent(3000)) orelse return error.TestNoLog;
    defer a.free(log_ev);
    try std.testing.expect(std.mem.indexOf(u8, log_ev, "notifications/message") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_ev, "secret-of-a") != null);
    const res_ev = (try call.conn.nextEvent(3000)) orelse return error.TestNoToolResult;
    defer a.free(res_ev);
    try std.testing.expect(std.mem.indexOf(u8, res_ev, "\"id\":3") != null);

    try expectSilent(&get_b, "B's GET stream");
}

test "list_changed reaches each client once, on its own stream" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);
    var get_a = try f.openGet(sid_a, null);
    defer get_a.close();
    var get_b = try f.openGet(sid_b, null);
    defer get_b.close();

    try f.server.notifyToolListChanged();

    for ([_]*http.Conn{ &get_a, &get_b }) |c| {
        const ev = (try c.nextEvent(3000)) orelse return error.TestNoListChanged;
        defer a.free(ev);
        try std.testing.expect(std.mem.indexOf(u8, ev, "notifications/tools/list_changed") != null);
        try expectSilent(c, "a GET stream (second copy)");
    }
}

test "a session-scoped message with no session context is refused, not broadcast" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    var get_a = try f.openGet(sid_a, null);
    defer get_a.close();

    try std.testing.expectError(error.NoSession, f.server.emitLog("info", "bg", "who gets this?"));
    try expectSilent(&get_a, "A's GET stream");
}

test "Last-Event-ID replay never crosses sessions" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);
    {
        var get_a = try f.openGet(sid_a, null);
        defer get_a.close();
        try f.server.notifyToolListChanged();
        const ev = (try get_a.nextEvent(3000)) orelse return error.TestNoEvent;
        a.free(ev);
    }
    // B asks for everything after event 0: only B's own events may replay.
    var get_b = try f.openGet(sid_b, 0);
    defer get_b.close();
    var seen: u32 = 0;
    while (try get_b.nextEvent(300)) |ev| {
        a.free(ev);
        seen += 1;
    }
    // B's own copy of the list_changed is the only thing it may see.
    try std.testing.expect(seen <= 1);
}

// ----------------------------------------------------------------------------
// Request ids and cancellation are per session
// ----------------------------------------------------------------------------

test "the same request id in two sessions is not a duplicate, and B cannot cancel A's request" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const sid_a = try f.connect("{}");
    defer a.free(sid_a);
    const sid_b = try f.connect("{}");
    defer a.free(sid_b);

    var call_a: struct { conn: http.Conn } = .{ .conn = try http.start(a, f.port, "POST", sid_a, .json, null,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_cancel"}}
    ) };
    defer call_a.conn.close();

    var spins: u32 = 0;
    while (f.handler.started.load(.acquire) == 0) : (spins += 1) {
        if (spins > 3000) return error.TestHandlerDidNotStart;
        testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    var rb = try http.post(a, f.port, sid_b,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"known"}}
    );
    defer rb.deinit(a);
    var doc_b = try parse(rb.body);
    defer doc_b.deinit();
    try std.testing.expect(field(doc_b.root, "result") != null);

    var cb = try http.post(a, f.port, sid_b,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}
    );
    defer cb.deinit(a);
    try std.testing.expect(!try call_a.conn.closedWithin(300));

    var ca = try http.post(a, f.port, sid_a,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}
    );
    defer ca.deinit(a);
    try std.testing.expect(try call_a.conn.closedWithin(3000));
}
