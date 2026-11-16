//! Minimal raw-socket HTTP/1.1 + SSE client for the Streamable HTTP
//! transport tests. Every read has a deadline, so a server that never
//! answers fails the test instead of hanging it.

const std = @import("std");

pub inline fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Conn = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    eof: bool = false,

    pub fn open(allocator: std.mem.Allocator, port: u16) !Conn {
        var addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
        const stream = try std.Io.net.IpAddress.connect(&addr, testIo(), .{ .mode = .stream });
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn close(self: *Conn) void {
        var copy = self.stream;
        copy.close(testIo());
        self.buf.deinit(self.allocator);
    }

    pub fn send(self: *Conn, bytes: []const u8) !void {
        var w_buf: [4096]u8 = undefined;
        var sw = self.stream.writer(testIo(), &w_buf);
        try sw.interface.writeAll(bytes);
        try sw.interface.flush();
    }

    /// Reads whatever is available within `timeout_ms`. Returns false on
    /// timeout; sets `eof` when the peer closed.
    fn fill(self: *Conn, timeout_ms: i32) !bool {
        if (self.eof) return false;
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) return false;
        var tmp: [4096]u8 = undefined;
        const n = std.posix.read(self.stream.socket.handle, &tmp) catch |e| switch (e) {
            error.ConnectionResetByPeer => 0,
            else => return e,
        };
        if (n == 0) {
            self.eof = true;
            return false;
        }
        try self.buf.appendSlice(self.allocator, tmp[0..n]);
        return true;
    }

    fn deadline(timeout_ms: u32) i64 {
        return std.Io.Timestamp.now(testIo(), .awake).toMilliseconds() + timeout_ms;
    }

    fn remaining(dl: i64) i32 {
        const now = std.Io.Timestamp.now(testIo(), .awake).toMilliseconds();
        return @intCast(@max(0, dl - now));
    }

    fn take(self: *Conn, n: usize) ![]u8 {
        const out = try self.allocator.dupe(u8, self.buf.items[0..n]);
        std.mem.copyForwards(u8, self.buf.items, self.buf.items[n..]);
        self.buf.shrinkRetainingCapacity(self.buf.items.len - n);
        return out;
    }

    pub const Head = struct {
        status: u16,
        session_id: ?[]u8 = null,
        content_type: ?[]u8 = null,
        content_length: ?usize = null,

        pub fn deinit(self: *Head, allocator: std.mem.Allocator) void {
            if (self.session_id) |s| allocator.free(s);
            if (self.content_type) |s| allocator.free(s);
        }

        pub fn isSse(self: Head) bool {
            const ct = self.content_type orelse return false;
            return std.mem.startsWith(u8, ct, "text/event-stream");
        }
    };

    pub fn readHead(self: *Conn, timeout_ms: u32) !Head {
        const dl = deadline(timeout_ms);
        while (std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") == null) {
            if (self.eof) return error.TestConnectionClosed;
            const r = remaining(dl);
            if (r == 0) return error.TestTimeout;
            _ = try self.fill(r);
        }
        const end = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n").?;
        const raw = try self.take(end + 4);
        defer self.allocator.free(raw);

        var head: Head = .{ .status = 0 };
        errdefer head.deinit(self.allocator);
        var lines = std.mem.splitSequence(u8, raw[0..end], "\r\n");
        const status_line = lines.next() orelse return error.TestBadResponse;
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next();
        head.status = try std.fmt.parseInt(u16, parts.next() orelse return error.TestBadResponse, 10);
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "mcp-session-id")) {
                head.session_id = try self.allocator.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                head.content_type = try self.allocator.dupe(u8, value);
            } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                head.content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }
        return head;
    }

    pub fn readBody(self: *Conn, len: usize, timeout_ms: u32) ![]u8 {
        const dl = deadline(timeout_ms);
        while (self.buf.items.len < len) {
            if (self.eof) return error.TestConnectionClosed;
            const r = remaining(dl);
            if (r == 0) return error.TestTimeout;
            _ = try self.fill(r);
        }
        return self.take(len);
    }

    /// Next SSE event's `data` (lines joined), or null when nothing arrives
    /// within `timeout_ms` or the stream ends.
    pub fn nextEvent(self: *Conn, timeout_ms: u32) !?[]u8 {
        const dl = deadline(timeout_ms);
        while (true) {
            if (std.mem.indexOf(u8, self.buf.items, "\n\n")) |end| {
                const raw = try self.take(end + 2);
                defer self.allocator.free(raw);
                var data: std.ArrayListUnmanaged(u8) = .empty;
                errdefer data.deinit(self.allocator);
                var has_data = false;
                var lines = std.mem.splitScalar(u8, raw[0..end], '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "data:")) {
                        if (has_data) try data.append(self.allocator, '\n');
                        try data.appendSlice(self.allocator, std.mem.trimStart(u8, line["data:".len..], " "));
                        has_data = true;
                    }
                }
                if (!has_data) {
                    // retry/comment-only event
                    data.deinit(self.allocator);
                    continue;
                }
                return try data.toOwnedSlice(self.allocator);
            }
            if (self.eof) return null;
            const r = remaining(dl);
            if (r == 0) return null;
            _ = try self.fill(r);
        }
    }

    /// True when the peer closes the connection within `timeout_ms`.
    pub fn closedWithin(self: *Conn, timeout_ms: u32) !bool {
        const dl = deadline(timeout_ms);
        while (!self.eof) {
            const r = remaining(dl);
            if (r == 0) return false;
            _ = try self.fill(r);
        }
        return true;
    }
};

pub const Accept = enum { json, sse };

/// Sends one HTTP request on a fresh connection and returns it with the
/// response head read. The caller reads the body or events and closes it.
pub fn request(
    allocator: std.mem.Allocator,
    port: u16,
    method: []const u8,
    session_id: ?[]const u8,
    accept: Accept,
    last_event_id: ?u64,
    body: []const u8,
) !struct { conn: Conn, head: Conn.Head } {
    var conn = try start(allocator, port, method, session_id, accept, last_event_id, body);
    errdefer conn.close();
    const head = try conn.readHead(3000);
    return .{ .conn = conn, .head = head };
}

/// Sends one HTTP request and returns the connection without waiting for
/// the response (for requests the server answers later).
pub fn start(
    allocator: std.mem.Allocator,
    port: u16,
    method: []const u8,
    session_id: ?[]const u8,
    accept: Accept,
    last_event_id: ?u64,
    body: []const u8,
) !Conn {
    var conn = try Conn.open(allocator, port);
    errdefer conn.close();
    var req: std.ArrayListUnmanaged(u8) = .empty;
    defer req.deinit(allocator);
    try req.print(allocator, "{s} /mcp HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n", .{method});
    try req.appendSlice(allocator, switch (accept) {
        .json => "Accept: application/json, text/event-stream\r\n",
        .sse => "Accept: text/event-stream, application/json\r\n",
    });
    if (session_id) |sid| try req.print(allocator, "Mcp-Session-Id: {s}\r\n", .{sid});
    if (last_event_id) |id| try req.print(allocator, "Last-Event-ID: {d}\r\n", .{id});
    if (body.len > 0 or std.mem.eql(u8, method, "POST")) {
        try req.print(allocator, "Content-Type: application/json\r\nContent-Length: {d}\r\n", .{body.len});
    }
    try req.appendSlice(allocator, "\r\n");
    try req.appendSlice(allocator, body);
    try conn.send(req.items);
    return conn;
}

/// A complete POST exchange whose response is read in full: a JSON body,
/// or, for an SSE response, the data of every event joined with '\n'.
pub const Reply = struct {
    status: u16,
    session_id: ?[]u8,
    body: []u8,

    pub fn deinit(self: *Reply, allocator: std.mem.Allocator) void {
        if (self.session_id) |s| allocator.free(s);
        allocator.free(self.body);
    }
};

pub fn post(allocator: std.mem.Allocator, port: u16, session_id: ?[]const u8, body: []const u8) !Reply {
    var r = try request(allocator, port, "POST", session_id, .json, null, body);
    defer r.conn.close();
    errdefer r.head.deinit(allocator);
    var out: []u8 = undefined;
    if (r.head.isSse()) {
        var all: std.ArrayListUnmanaged(u8) = .empty;
        errdefer all.deinit(allocator);
        while (try r.conn.nextEvent(3000)) |ev| {
            defer allocator.free(ev);
            if (all.items.len > 0) try all.append(allocator, '\n');
            try all.appendSlice(allocator, ev);
        }
        out = try all.toOwnedSlice(allocator);
    } else {
        out = try r.conn.readBody(r.head.content_length orelse 0, 3000);
    }
    if (r.head.content_type) |ct| allocator.free(ct);
    return .{ .status = r.head.status, .session_id = r.head.session_id, .body = out };
}
