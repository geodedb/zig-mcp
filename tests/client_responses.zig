//! Server-to-client requests, client responses and request-id hygiene
//! (SONNY-6643).
//!
//! MCP 2025-11-25 basic "Responses": a response carries the id of the
//! request it answers and a `result` or an `error`; it has no `method`.
//! JSON-RPC 2.0: a response is never answered. These tests negotiate the
//! client capabilities with a real `initialize`, capture the exact bytes the
//! server writes to its stdio writer, and feed the client's response back
//! through `Server.processMessage`, under `std.testing.allocator`.
//!
//! They also check that the Session/notification builders cannot emit
//! invalid JSON from caller input, and that a second in-flight request
//! reusing an id is rejected with -32600 without orphaning the first.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

inline fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Handler = struct {
    allocator: std.mem.Allocator,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn handler(self: *Handler) mcp.Handler {
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

    fn self_(ctx: ?*anyopaque) *Handler {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return self_(ctx).allocator.dupe(u8, "{\"tools\":[]}");
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
        const self = self_(ctx);
        if (std.mem.eql(u8, name, "wait_cancel")) {
            self.started.store(true, .release);
            var waited_ms: u32 = 0;
            while (!cancel.isCancelled()) : (waited_ms += 1) {
                if (waited_ms >= 5000) return error.Timeout;
                testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
            return error.Cancelled;
        }
        if (std.mem.eql(u8, name, "known")) {
            return self.allocator.dupe(u8, "{\"content\":[]}");
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

/// An initialized server whose stdio transport writes into a file, with a
/// stdio Session, as `serveStdio` sets up.
const Fixture = struct {
    allocator: std.mem.Allocator,
    handler: Handler,
    tmp: std.testing.TmpDir,
    file: std.Io.File,
    out_buf: [4096]u8 = undefined,
    consumed: usize = 0,
    server: mcp.Server,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.consumed = 0;
        self.handler = .{ .allocator = allocator };
        self.server = try mcp.Server.init(allocator, .{ .name = "resp-test", .version = "1" }, self.handler.handler());
        errdefer self.server.deinit();

        const init_resp = try self.server.processMessage(
            \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{},"elicitation":{},"sampling":{}},"clientInfo":{"name":"t","version":"1"}}}
        );
        if (init_resp) |r| allocator.free(r);
        _ = try self.server.processMessage(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );

        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.file = try self.tmp.dir.createFile(testIo(), "stdout.jsonl", .{ .read = true });
        self.server.stdout_writer_wrap = self.file.writer(testIo(), &self.out_buf);
        self.server.session = mcp.Session.init(allocator, &self.server);
    }

    fn deinit(self: *Fixture) void {
        self.server.stdout_writer_wrap = null;
        self.server.deinit();
        self.file.close(testIo());
        self.tmp.cleanup();
    }

    /// Returns the next line the server wrote, waiting up to 5 s.
    fn nextLine(self: *Fixture) ![]u8 {
        var waited_ms: u32 = 0;
        while (waited_ms < 5000) : (waited_ms += 1) {
            const bytes = try self.tmp.dir.readFileAlloc(testIo(), "stdout.jsonl", self.allocator, .limited(1 << 20));
            defer self.allocator.free(bytes);
            const rest = bytes[self.consumed..];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                self.consumed += nl + 1;
                return self.allocator.dupe(u8, rest[0..nl]);
            }
            testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        return error.TestNoOutboundMessage;
    }

    fn written(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(testIo(), "stdout.jsonl", self.allocator, .limited(1 << 20));
    }

    /// Fails the stuck request so a red test does not hang for its full
    /// timeout (30 s to 5 min).
    fn releasePending(self: *Fixture) void {
        const s = &self.server.session.?;
        s.mutex.lockUncancelable(testIo());
        defer s.mutex.unlock(testIo());
        var it = s.pending_requests.valueIterator();
        while (it.next()) |ctx| {
            ctx.*.err = error.TestReleased;
            ctx.*.done.set(testIo());
        }
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

const Outcome = struct {
    result: ?[]const u8 = null,
    err: ?anyerror = null,
};

const Kind = enum { roots, elicitation, sampling };

fn runRequest(server: *mcp.Server, kind: Kind, out: *Outcome) void {
    const r = switch (kind) {
        .roots => server.requestRoots(),
        .elicitation => server.requestElicitation(.form, "name?", "{\"type\":\"object\"}"),
        .sampling => server.requestSampling("[]", 10),
    };
    if (r) |v| out.result = v else |e| out.err = e;
}

/// Starts `kind` on a thread, reads the request it sent, answers it with
/// `reply` (`{id}` is replaced by the request id), and returns the outcome.
fn roundTrip(f: *Fixture, kind: Kind, comptime method: []const u8, comptime reply: []const u8, out: *Outcome) !void {
    const a = f.allocator;
    const t = try std.Thread.spawn(.{}, runRequest, .{ &f.server, kind, out });
    defer t.join();
    errdefer f.releasePending();

    const line = try f.nextLine();
    defer a.free(line);
    var doc = try parse(line);
    defer doc.deinit();
    try std.testing.expectEqualStrings(method, field(doc.root, "method").?.str);
    const id = field(doc.root, "id").?.num.lexeme;

    const msg = try std.mem.replaceOwned(u8, a, reply, "{id}", id);
    defer a.free(msg);
    const resp = try f.server.processMessage(msg);
    if (resp) |r| {
        defer a.free(r);
        std.debug.print("a client response was answered: {s}\n", .{r});
        return error.TestResponseAnswered;
    }
}

// ----------------------------------------------------------------------------
// Client responses resolve server requests
// ----------------------------------------------------------------------------

test "requestRoots returns the client's result" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var out: Outcome = .{};
    try roundTrip(&f, .roots, "roots/list",
        \\{"jsonrpc":"2.0","id":{id},"result":{ "roots": [ {"uri":"file:///home/u","name":"home"} ] }}
    , &out);
    try std.testing.expect(out.err == null);
    const result = out.result.?;
    defer a.free(result);
    try std.testing.expectEqualStrings("{\"roots\":[{\"uri\":\"file:///home/u\",\"name\":\"home\"}]}", result);
}

test "requestSampling returns the client's result" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var out: Outcome = .{};
    try roundTrip(&f, .sampling, "sampling/createMessage",
        \\{"jsonrpc":"2.0","id":{id},"result":{"role":"assistant","content":{"type":"text","text":"hi"},"model":"m"}}
    , &out);
    try std.testing.expect(out.err == null);
    const result = out.result.?;
    defer a.free(result);
    var doc = try parse(result);
    defer doc.deinit();
    try std.testing.expectEqualStrings("m", field(doc.root, "model").?.str);
}

test "requestElicitation fails with ClientError when the client answers with an error" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var out: Outcome = .{};
    try roundTrip(&f, .elicitation, "elicitation/create",
        \\{"jsonrpc":"2.0","id":{id},"error":{"code":-32603,"message":"user closed the dialog"}}
    , &out);
    try std.testing.expect(out.result == null);
    try std.testing.expectEqual(@as(?anyerror, error.ClientError), out.err);
}

test "a second response for the same id is ignored" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    var out: Outcome = .{};
    try roundTrip(&f, .roots, "roots/list",
        \\{"jsonrpc":"2.0","id":{id},"result":{"roots":[]}}
    , &out);
    const result = out.result.?;
    defer a.free(result);

    // The request has id 1 (the first one this session made).
    const again = try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":1,"result":{"roots":[{"uri":"file:///late"}]}}
    );
    try std.testing.expect(again == null);
}

test "responses to unknown ids are dropped, never answered" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":4242,"result":{}}
        ,
        \\{"jsonrpc":"2.0","id":"abc","result":{}}
        ,
        \\{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"no"}}
        ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
        ,
    }) |msg| {
        const resp = try f.server.processMessage(msg);
        if (resp) |r| {
            defer a.free(r);
            std.debug.print("response {s} was answered: {s}\n", .{ msg, r });
            return error.TestResponseAnswered;
        }
    }
}

test "a response inside a batch is not answered; the requests are" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\[{"jsonrpc":"2.0","id":99,"result":{}},{"jsonrpc":"2.0","id":5,"method":"ping"}]
    )).?;
    defer a.free(resp);
    var doc = try parse(resp);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.root.arr.len);
    try std.testing.expectEqualStrings("5", field(doc.root.arr[0], "id").?.num.lexeme);
}

test "a message with neither method, result nor error is still Invalid Request" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    const resp = (try f.server.processMessage(
        \\{"jsonrpc":"2.0","id":3}
    )).?;
    defer a.free(resp);
    var doc = try parse(resp);
    defer doc.deinit();
    try std.testing.expectEqualStrings("-32600", field(field(doc.root, "error").?, "code").?.num.lexeme);
}

// ----------------------------------------------------------------------------
// Builders never emit invalid JSON
// ----------------------------------------------------------------------------

const tricky = "a\"b\\c\x01\n";

test "Session.notify escapes the method and minifies params" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    try f.server.session.?.notify("notifications/" ++ tricky,
        \\{
        \\  "k": [1, 2]
        \\}
    );
    const line = try f.nextLine();
    defer a.free(line);
    var doc = try parse(line);
    defer doc.deinit();
    try std.testing.expectEqualStrings("notifications/" ++ tricky, field(doc.root, "method").?.str);
    try std.testing.expectEqual(@as(usize, 2), field(field(doc.root, "params").?, "k").?.arr.len);
}

test "Session.notify and Session.request reject params that are not one JSON value" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    try std.testing.expectError(error.InvalidParamsJson, f.server.session.?.notify("x", "{\"a\":"));
    try std.testing.expectError(error.InvalidParamsJson, f.server.session.?.request("x", "{} {}", 1000));
    try std.testing.expectEqual(@as(u32, 0), f.server.session.?.pending_requests.count());

    const bytes = try f.written();
    defer a.free(bytes);
    try std.testing.expectEqualStrings("", bytes);
}

test "notifyProgress, emitLog and notifyResourceUpdated escape caller strings" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();

    try f.server.notifyProgress(tricky, 1, 2);
    try f.server.emitLog("info", tricky, tricky);
    try f.server.notifyResourceUpdated("file:///" ++ tricky);

    {
        const line = try f.nextLine();
        defer a.free(line);
        var doc = try parse(line);
        defer doc.deinit();
        try std.testing.expectEqualStrings(tricky, field(field(doc.root, "params").?, "progressToken").?.str);
    }
    {
        const line = try f.nextLine();
        defer a.free(line);
        var doc = try parse(line);
        defer doc.deinit();
        const params = field(doc.root, "params").?;
        try std.testing.expectEqualStrings(tricky, field(params, "logger").?.str);
        try std.testing.expectEqualStrings(tricky, field(field(params, "data").?, "message").?.str);
    }
    {
        const line = try f.nextLine();
        defer a.free(line);
        var doc = try parse(line);
        defer doc.deinit();
        try std.testing.expectEqualStrings("file:///" ++ tricky, field(field(doc.root, "params").?, "uri").?.str);
    }
}

// ----------------------------------------------------------------------------
// Duplicate in-flight request ids
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

fn waitStarted(h: *Handler) !void {
    var spins: u32 = 0;
    while (!h.started.load(.acquire)) : (spins += 1) {
        if (spins > 5000) return error.TestHandlerDidNotStart;
        testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

fn expectDuplicateRejected(a: std.mem.Allocator, f: *Fixture, first: []const u8, second: []const u8, cancel: []const u8, expected_id: []const u8) !void {
    var result: CallResult = .{};
    const t = try std.Thread.spawn(.{}, runCall, .{ &f.server, first, &result });
    try waitStarted(&f.handler);

    const dup = (try f.server.processMessage(second)) orelse {
        _ = try f.server.processMessage(cancel);
        t.join();
        return error.TestExpectedResponse;
    };
    defer a.free(dup);

    // The first request must still be reachable by its id.
    _ = try f.server.processMessage(cancel);
    t.join();
    if (result.response) |r| {
        defer a.free(r);
        std.debug.print("first request was orphaned and answered: {s}\n", .{r});
        return error.TestFirstRequestOrphaned;
    }

    var doc = try parse(dup);
    defer doc.deinit();
    const id = field(doc.root, "id").?;
    switch (id) {
        .num => |n| try std.testing.expectEqualStrings(expected_id, n.lexeme),
        .str => |s| try std.testing.expectEqualStrings(expected_id, s),
        else => return error.TestUnexpectedId,
    }
    const e = field(doc.root, "error") orelse {
        std.debug.print("duplicate id was accepted: {s}\n", .{dup});
        return error.TestDuplicateAccepted;
    };
    try std.testing.expectEqualStrings("-32600", field(e, "code").?.num.lexeme);
}

test "duplicate in-flight integer id is rejected and does not orphan the first request" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();
    try expectDuplicateRejected(a, &f,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wait_cancel"}}
    ,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"known"}}
    ,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}
    , "7");
}

test "duplicate in-flight string id on another method is rejected" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();
    try expectDuplicateRejected(a, &f,
        \\{"jsonrpc":"2.0","id":"r1","method":"tools/call","params":{"name":"wait_cancel"}}
    ,
        \\{"jsonrpc":"2.0","id":"r1","method":"ping"}
    ,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r1"}}
    , "r1");
}

test "an id can be reused once the earlier request has completed" {
    const a = std.testing.allocator;
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();
    for (0..2) |_| {
        const resp = (try f.server.processMessage(
            \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"known"}}
        )).?;
        defer a.free(resp);
        var doc = try parse(resp);
        defer doc.deinit();
        try std.testing.expect(field(doc.root, "result") != null);
    }
}
