//! Server-to-client request escaping (SONNY-6585 follow-up).
//!
//! `requestElicitation` and `requestSamplingFull` build JSON from caller
//! strings and send it to the client over the stdio transport. These tests
//! negotiate the client capabilities with a real `initialize` round trip,
//! capture the exact bytes the server writes to its stdio writer, and check
//! that each line is one valid JSON message whose strings decode back to
//! the caller's input, whatever control characters or quotes it holds.

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

inline fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn noopList(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
    return a.dupe(u8, "{}");
}
fn noopCall(_: ?*anyopaque, _: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
    return error.ToolNotFound;
}
fn noopRead(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return error.ResourceNotFound;
}
fn noopTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
    return noopList(ctx, null);
}
fn noopUri(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn noopPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.PromptNotFound;
}
fn noopComplete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return noopList(ctx, null);
}

const Capture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    file: std.Io.File,
    out_buf: [4096]u8 = undefined,
    server: mcp.Server,

    fn init(self: *Capture, allocator: *const std.mem.Allocator) !void {
        self.allocator = allocator.*;
        self.server = try mcp.Server.init(allocator.*, .{ .name = "out-test", .version = "1" }, .{
            .ctx = @ptrCast(@constCast(allocator)),
            .listTools = noopList,
            .callTool = noopCall,
            .listResources = noopList,
            .readResource = noopRead,
            .listResourceTemplates = noopTemplates,
            .subscribeResource = noopUri,
            .unsubscribeResource = noopUri,
            .listPrompts = noopList,
            .getPrompt = noopPrompt,
            .complete = noopComplete,
            .setLogLevel = noopUri,
        });
        errdefer self.server.deinit();

        const init_resp = try self.server.processMessage(
            \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{},"sampling":{}},"clientInfo":{"name":"t","version":"1"}}}
        );
        if (init_resp) |r| self.allocator.free(r);
        _ = try self.server.processMessage(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );

        // Route the stdio transport into a file the test can read back.
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.file = try self.tmp.dir.createFile(testIo(), "stdout.jsonl", .{ .read = true });
        self.server.stdout_writer_wrap = self.file.writer(testIo(), &self.out_buf);
        self.server.session = mcp.Session.init(self.allocator, &self.server);
    }

    fn deinit(self: *Capture) void {
        self.server.stdout_writer_wrap = null;
        self.server.deinit();
        self.file.close(testIo());
        self.tmp.cleanup();
    }

    /// Waits until the server has written one full line, then releases the
    /// pending server-to-client request so the calling thread returns.
    fn takeLine(self: *Capture) ![]u8 {
        var waited_ms: u32 = 0;
        while (waited_ms < 5000) : (waited_ms += 1) {
            const bytes = try self.tmp.dir.readFileAlloc(testIo(), "stdout.jsonl", self.allocator, .limited(1 << 20));
            if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| {
                self.releasePending();
                const line = try self.allocator.dupe(u8, bytes[0..nl]);
                self.allocator.free(bytes);
                return line;
            }
            self.allocator.free(bytes);
            testIo().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        self.releasePending();
        return error.TestNoOutboundMessage;
    }

    fn releasePending(self: *Capture) void {
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

fn parseLine(line: []const u8) !json.Document {
    var err = json.ParseError.init();
    return json.parse(std.testing.allocator, line, .{}, &err) catch |e| {
        std.debug.print("outbound message is not valid JSON ({s}): {s}\n", .{ @errorName(e), line });
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

const tricky = "say \"hi\" \\ \x01\x08\x0c\x1f\x7f\n\r\t end";

fn elicit(server: *mcp.Server, mode: mcp.Server.ElicitationMode, message: []const u8, arg: []const u8, out: *?anyerror) void {
    if (server.requestElicitation(mode, message, arg)) |r| {
        server.allocator.free(r);
    } else |e| out.* = e;
}

fn sample(server: *mcp.Server, req: mcp.SamplingRequest, out: *?anyerror) void {
    if (server.requestSamplingFull(req)) |r| {
        server.allocator.free(r);
    } else |e| out.* = e;
}

test "requestElicitation form mode escapes every control character in message" {
    const a = std.testing.allocator;
    var c: Capture = undefined;
    try c.init(&a);
    defer c.deinit();

    var call_err: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, elicit, .{ &c.server, mcp.Server.ElicitationMode.form, tricky, "{\"type\":\"object\"}", &call_err });
    const line = c.takeLine() catch |e| {
        t.join();
        return e;
    };
    t.join();
    defer a.free(line);
    try std.testing.expectEqual(@as(?anyerror, error.TestReleased), call_err);

    var doc = try parseLine(line);
    defer doc.deinit();
    const params = field(doc.root, "params").?;
    try std.testing.expectEqualStrings(tricky, field(params, "message").?.str);
}

test "requestElicitation url mode escapes the url" {
    const a = std.testing.allocator;
    var c: Capture = undefined;
    try c.init(&a);
    defer c.deinit();

    const url = "https://example.com/pay?q=\"x\"&n=\\\x01";
    var call_err: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, elicit, .{ &c.server, mcp.Server.ElicitationMode.url, "pay", url, &call_err });
    const line = c.takeLine() catch |e| {
        t.join();
        return e;
    };
    t.join();
    defer a.free(line);

    var doc = try parseLine(line);
    defer doc.deinit();
    const params = field(doc.root, "params").?;
    try std.testing.expectEqualStrings(url, field(params, "url").?.str);
}

test "requestSamplingFull escapes systemPrompt and stopSequences" {
    const a = std.testing.allocator;
    var c: Capture = undefined;
    try c.init(&a);
    defer c.deinit();

    const stops = [_][]const u8{ "\x00stop\"", "\x1b[0m" };
    var call_err: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, sample, .{ &c.server, mcp.SamplingRequest{
        .messages_json = "[]",
        .max_tokens = 5,
        .system_prompt = tricky,
        .stop_sequences = &stops,
    }, &call_err });
    const line = c.takeLine() catch |e| {
        t.join();
        return e;
    };
    t.join();
    defer a.free(line);

    var doc = try parseLine(line);
    defer doc.deinit();
    const params = field(doc.root, "params").?;
    try std.testing.expectEqualStrings(tricky, field(params, "systemPrompt").?.str);
    const seqs = field(params, "stopSequences").?.arr;
    try std.testing.expectEqualStrings(stops[0], seqs[0].str);
    try std.testing.expectEqualStrings(stops[1], seqs[1].str);
}
