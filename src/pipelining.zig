// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! HTTP/1.1 Request Pipelining
//!
//! Implements HTTP/1.1 request pipelining for improved throughput.
//! Allows multiple requests to be sent without waiting for responses.
//!
//! Features:
//! - Request queuing and ordering
//! - Response matching
//! - Connection keep-alive management
//! - Automatic retry on connection failure

const std = @import("std");
const Allocator = std.mem.Allocator;

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Maximum number of pipelined requests
pub const max_pipeline_depth = 100;

/// Request state in the pipeline
pub const RequestState = enum {
    /// Request is queued but not yet sent
    queued,
    /// Request has been sent, waiting for response
    sent,
    /// Response received
    completed,
    /// Request failed
    failed,
    /// Request was cancelled
    cancelled,
};

/// Pipelined request
pub const PipelinedRequest = struct {
    /// Unique request ID
    id: u64,
    /// HTTP method
    method: Method,
    /// Request path
    path: []const u8,
    /// Request headers
    headers: []const Header,
    /// Request body (optional)
    body: ?[]const u8,
    /// Current state
    state: RequestState,
    /// Response (populated when completed)
    response: ?Response,
    /// Error if failed
    err: ?anyerror,
    /// Timestamp when request was queued
    queued_at: i64,
    /// Timestamp when request was sent
    sent_at: ?i64,
    /// Timestamp when response was received
    completed_at: ?i64,

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,

        pub fn toString(self: Method) []const u8 {
            return switch (self) {
                .GET => "GET",
                .POST => "POST",
                .PUT => "PUT",
                .DELETE => "DELETE",
                .PATCH => "PATCH",
                .HEAD => "HEAD",
                .OPTIONS => "OPTIONS",
            };
        }
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Response = struct {
        status_code: u16,
        headers: []const Header,
        body: []const u8,
    };
};

/// Pipeline statistics
pub const PipelineStats = struct {
    /// Total requests processed
    total_requests: u64 = 0,
    /// Currently pending requests
    pending_requests: u32 = 0,
    /// Requests completed successfully
    successful_requests: u64 = 0,
    /// Requests that failed
    failed_requests: u64 = 0,
    /// Total bytes sent
    bytes_sent: u64 = 0,
    /// Total bytes received
    bytes_received: u64 = 0,
    /// Average latency in nanoseconds
    avg_latency_ns: u64 = 0,
    /// Pipeline stalls (had to wait for response before sending)
    pipeline_stalls: u64 = 0,
};

/// HTTP/1.1 Request Pipeline
pub const Pipeline = struct {
    allocator: Allocator,
    /// Queue of requests
    requests: std.ArrayListUnmanaged(PipelinedRequest) = .empty,
    /// Next request ID
    next_id: u64,
    /// Maximum pipeline depth
    max_depth: u32,
    /// Statistics
    stats: PipelineStats,
    /// Connection state
    connection_state: ConnectionState,
    /// Keep-alive settings
    keep_alive: KeepAlive,
    /// Mutex for thread safety
    mutex: std.Io.Mutex,

    pub const ConnectionState = enum {
        disconnected,
        connecting,
        connected,
        draining,
    };

    pub const KeepAlive = struct {
        enabled: bool = true,
        timeout_ms: u32 = 30000,
        max_requests: u32 = 1000,
        requests_on_connection: u32 = 0,
    };

    /// Initialize a new pipeline
    pub fn init(allocator: Allocator) Pipeline {
        return .{
            .allocator = allocator,
            .next_id = 1,
            .max_depth = max_pipeline_depth,
            .stats = .{},
            .connection_state = .disconnected,
            .keep_alive = .{},
            .mutex = std.Io.Mutex.init,
        };
    }

    /// Deinitialize the pipeline
    pub fn deinit(self: *Pipeline) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            self.freeRequest(req);
        }
        self.requests.deinit(self.allocator);
    }

    fn freeRequest(self: *Pipeline, req: *PipelinedRequest) void {
        self.allocator.free(req.path);
        for (req.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(req.headers);
        if (req.body) |b| self.allocator.free(b);
        if (req.response) |r| {
            for (r.headers) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            self.allocator.free(r.headers);
            self.allocator.free(r.body);
        }
    }

    /// Queue a new request
    pub fn queueRequest(
        self: *Pipeline,
        method: PipelinedRequest.Method,
        path: []const u8,
        headers: []const PipelinedRequest.Header,
        body: ?[]const u8,
    ) !u64 {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        // Check pipeline depth
        var pending: u32 = 0;
        for (self.requests.items) |req| {
            if (req.state == .queued or req.state == .sent) {
                pending += 1;
            }
        }

        if (pending >= self.max_depth) {
            return error.PipelineFull;
        }

        // Copy data
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        var headers_copy = try self.allocator.alloc(PipelinedRequest.Header, headers.len);
        errdefer self.allocator.free(headers_copy);
        for (headers, 0..) |h, i| {
            headers_copy[i] = .{
                .name = try self.allocator.dupe(u8, h.name),
                .value = try self.allocator.dupe(u8, h.value),
            };
        }

        const body_copy = if (body) |b| try self.allocator.dupe(u8, b) else null;

        const id = self.next_id;
        self.next_id += 1;

        try self.requests.append(self.allocator, .{
            .id = id,
            .method = method,
            .path = path_copy,
            .headers = headers_copy,
            .body = body_copy,
            .state = .queued,
            .response = null,
            .err = null,
            .queued_at = std.Io.Timestamp.now(io(), .real).toSeconds(),
            .sent_at = null,
            .completed_at = null,
        });

        self.stats.total_requests += 1;
        self.stats.pending_requests = pending + 1;

        return id;
    }

    /// Get the next request to send
    pub fn getNextToSend(self: *Pipeline) ?*PipelinedRequest {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.state == .queued) {
                return req;
            }
        }
        return null;
    }

    /// Mark a request as sent
    pub fn markSent(self: *Pipeline, id: u64) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.id == id and req.state == .queued) {
                req.state = .sent;
                req.sent_at = std.Io.Timestamp.now(io(), .real).toSeconds();
                break;
            }
        }
    }

    /// Complete a request with a response
    pub fn completeRequest(
        self: *Pipeline,
        id: u64,
        status_code: u16,
        headers: []const PipelinedRequest.Header,
        body: []const u8,
    ) !void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.id == id and req.state == .sent) {
                // Copy response data
                var headers_copy = try self.allocator.alloc(PipelinedRequest.Header, headers.len);
                for (headers, 0..) |h, i| {
                    headers_copy[i] = .{
                        .name = try self.allocator.dupe(u8, h.name),
                        .value = try self.allocator.dupe(u8, h.value),
                    };
                }

                req.response = .{
                    .status_code = status_code,
                    .headers = headers_copy,
                    .body = try self.allocator.dupe(u8, body),
                };
                req.state = .completed;
                req.completed_at = std.Io.Timestamp.now(io(), .real).toSeconds();

                self.stats.successful_requests += 1;
                if (self.stats.pending_requests > 0) {
                    self.stats.pending_requests -= 1;
                }

                // Update latency
                if (req.sent_at) |sent| {
                    const latency: u64 = @intCast(req.completed_at.? - sent);
                    self.stats.avg_latency_ns = (self.stats.avg_latency_ns + latency * 1_000_000_000) / 2;
                }

                break;
            }
        }
    }

    /// Fail a request
    pub fn failRequest(self: *Pipeline, id: u64, err: anyerror) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.id == id and (req.state == .queued or req.state == .sent)) {
                req.state = .failed;
                req.err = err;
                req.completed_at = std.Io.Timestamp.now(io(), .real).toSeconds();

                self.stats.failed_requests += 1;
                if (self.stats.pending_requests > 0) {
                    self.stats.pending_requests -= 1;
                }
                break;
            }
        }
    }

    /// Cancel a request
    pub fn cancelRequest(self: *Pipeline, id: u64) bool {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.id == id) {
                if (req.state == .queued) {
                    req.state = .cancelled;
                    if (self.stats.pending_requests > 0) {
                        self.stats.pending_requests -= 1;
                    }
                    return true;
                }
                // Can't cancel sent requests
                return false;
            }
        }
        return false;
    }

    /// Get request by ID
    pub fn getRequest(self: *Pipeline, id: u64) ?*const PipelinedRequest {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (self.requests.items) |*req| {
            if (req.id == id) {
                return req;
            }
        }
        return null;
    }

    /// Remove completed/failed/cancelled requests
    pub fn cleanup(self: *Pipeline) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        var i: usize = 0;
        while (i < self.requests.items.len) {
            const state = self.requests.items[i].state;
            if (state == .completed or state == .failed or state == .cancelled) {
                var req = self.requests.orderedRemove(i);
                self.freeRequest(&req);
            } else {
                i += 1;
            }
        }
    }

    /// Get statistics
    pub fn getStats(self: *Pipeline) PipelineStats {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        return self.stats;
    }

    /// Serialize a request to HTTP/1.1 format
    pub fn serializeRequest(
        self: *Pipeline,
        req: *const PipelinedRequest,
        writer: anytype,
    ) !void {
        _ = self;

        // Request line
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ req.method.toString(), req.path });

        // Headers
        for (req.headers) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        // Content-Length if body present
        if (req.body) |body| {
            try writer.print("Content-Length: {d}\r\n", .{body.len});
        }

        // End of headers
        try writer.writeAll("\r\n");

        // Body
        if (req.body) |body| {
            try writer.writeAll(body);
        }
    }

    /// Parse HTTP/1.1 response
    pub fn parseResponse(
        self: *Pipeline,
        data: []const u8,
    ) !struct { status_code: u16, headers: []PipelinedRequest.Header, body: []const u8, consumed: usize } {
        // Find header end
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.IncompleteResponse;
        const header_section = data[0..header_end];

        // Parse status line
        var lines = std.mem.splitSequence(u8, header_section, "\r\n");
        const status_line = lines.next() orelse return error.InvalidResponse;

        // Parse "HTTP/1.1 200 OK"
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return error.InvalidResponse; // HTTP version
        const status_str = parts.next() orelse return error.InvalidResponse;
        const status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidStatusCode;

        // Parse headers
        var headers_list = std.ArrayList(PipelinedRequest.Header).init(self.allocator);
        errdefer {
            for (headers_list.items) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            headers_list.deinit();
        }

        var content_length: ?usize = null;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOf(u8, line, ":") orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch null;
            }

            try headers_list.append(.{
                .name = try self.allocator.dupe(u8, name),
                .value = try self.allocator.dupe(u8, value),
            });
        }

        // Calculate body position and size
        const body_start = header_end + 4;
        const body_len = content_length orelse (data.len - body_start);

        if (data.len < body_start + body_len) {
            return error.IncompleteResponse;
        }

        return .{
            .status_code = status_code,
            .headers = try headers_list.toOwnedSlice(),
            .body = data[body_start .. body_start + body_len],
            .consumed = body_start + body_len,
        };
    }
};

/// Pipeline manager for multiple connections
pub const PipelineManager = struct {
    allocator: Allocator,
    pipelines: std.StringHashMap(*Pipeline),
    mutex: std.Io.Mutex,

    pub fn init(allocator: Allocator) PipelineManager {
        return .{
            .allocator = allocator,
            .pipelines = std.StringHashMap(*Pipeline).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *PipelineManager) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        var iter = self.pipelines.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pipelines.deinit();
    }

    /// Get or create pipeline for a host
    pub fn getPipeline(self: *PipelineManager, host: []const u8) !*Pipeline {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        if (self.pipelines.get(host)) |pipeline| {
            return pipeline;
        }

        const pipeline = try self.allocator.create(Pipeline);
        pipeline.* = Pipeline.init(self.allocator);

        const host_copy = try self.allocator.dupe(u8, host);
        try self.pipelines.put(host_copy, pipeline);

        return pipeline;
    }

    /// Get aggregate statistics
    pub fn getStats(self: *PipelineManager) PipelineStats {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        var stats = PipelineStats{};
        var iter = self.pipelines.iterator();
        while (iter.next()) |entry| {
            const p_stats = entry.value_ptr.*.getStats();
            stats.total_requests += p_stats.total_requests;
            stats.pending_requests += p_stats.pending_requests;
            stats.successful_requests += p_stats.successful_requests;
            stats.failed_requests += p_stats.failed_requests;
            stats.bytes_sent += p_stats.bytes_sent;
            stats.bytes_received += p_stats.bytes_received;
        }
        return stats;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "pipeline basic operations" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    // Queue a request
    const id = try pipeline.queueRequest(
        .POST,
        "/mcp",
        &[_]PipelinedRequest.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        "{\"test\":true}",
    );

    try std.testing.expect(id > 0);

    // Get next to send
    const req = pipeline.getNextToSend();
    try std.testing.expect(req != null);
    try std.testing.expectEqualStrings("/mcp", req.?.path);

    // Mark as sent
    pipeline.markSent(id);
    try std.testing.expect(pipeline.getNextToSend() == null);

    // Complete request
    try pipeline.completeRequest(id, 200, &[_]PipelinedRequest.Header{}, "{}");

    const completed = pipeline.getRequest(id);
    try std.testing.expect(completed != null);
    try std.testing.expectEqual(RequestState.completed, completed.?.state);
}

test "pipeline depth limit" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    pipeline.max_depth = 2;
    defer pipeline.deinit();

    _ = try pipeline.queueRequest(.GET, "/1", &.{}, null);
    _ = try pipeline.queueRequest(.GET, "/2", &.{}, null);

    // Third should fail
    try std.testing.expectError(error.PipelineFull, pipeline.queueRequest(.GET, "/3", &.{}, null));
}

test "pipeline cancellation" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    const id = try pipeline.queueRequest(.GET, "/test", &.{}, null);

    // Should be able to cancel queued request
    try std.testing.expect(pipeline.cancelRequest(id));

    const req = pipeline.getRequest(id);
    try std.testing.expectEqual(RequestState.cancelled, req.?.state);
}

test "request serialization" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    const id = try pipeline.queueRequest(
        .POST,
        "/mcp",
        &[_]PipelinedRequest.Header{
            .{ .name = "Host", .value = "localhost" },
        },
        "{}",
    );

    const req = pipeline.getRequest(id).?;

    var buf: [1024]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    try pipeline.serializeRequest(req, &fbs);

    const output = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "POST /mcp HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host: localhost") != null);
}
