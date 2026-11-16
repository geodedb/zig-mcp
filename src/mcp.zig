// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! MCP (Model Context Protocol) Server Library for Zig
//!
//! Implements MCP spec revision 2025-11-25 with:
//! - JSON-RPC 2.0 over UTF-8 (single + batch)
//! - stdio and Streamable HTTP transports (with SSE)
//! - WebSocket transport support
//! - Authentication (Bearer, Basic, OAuth2.1)
//! - Parallel request handling with worker thread pool
//! - Buffered I/O and connection pooling
//! - Metrics, tracing, and health checks
//! - Arena allocator support for high-performance scenarios
//! - Deterministic offline testing support

const std = @import("std");
const json = @import("json");
const tp = @import("thread_pool");
const crypto_backend = @import("crypto_backend");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Parallel MCP helpers (batch JSON-RPC, SSE broadcast, tool/resource/prompt
/// fan-out). Re-exported for downstream consumers.
pub const parallel = @import("parallel.zig");

/// Observability seam (otel). The seam is always compiled, but its
/// `enabled` flag tracks `-Dwith_otel`; when off, every call collapses
/// to a comptime-known no-op (verified by the disabled-mode test under
/// tests/observability_disabled_test.zig). Imported as a named module
/// so it lives in a single module tree across all consumers.
pub const observability = @import("observability");

/// Bootstrap helper: builds OTEL TracerProvider/MeterProvider/LoggerProvider
/// from OTEL_* env vars and publishes Tracer/Meter handles to
/// `observability.global`. Application entry-point code calls
/// `observability_init.Otel.init` then `installGlobals()` to publish
/// providers; when `-Dwith_otel=false` this collapses to an empty
/// struct so the import never resolves the otel namespace.
pub const observability_init = if (observability.enabled)
    @import("observability_init")
else
    struct {};

test {
    _ = @import("crypto_backend_smoke_test.zig");
}

test "FIPS-0008: WebSocket accept-key available only in non-fips builds" {
    // Under -Dfips the SHA-1 accept-key fn is @compileError'd out; the gated
    // reference lives in a comptime-pruned block so it is never analyzed.
    if (crypto_backend.fips_enabled) return error.SkipZigTest;
    if (!crypto_backend.fips_enabled) {
        // RFC 6455 §1.3 canonical example:
        //   key "dGhlIHNhbXBsZSBub25jZQ==" -> "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        const accept = try generateWebSocketAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
        try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
    }
}

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Read bytes from a network stream using posix read on the underlying fd.
fn streamRead(stream: std.Io.net.Stream, buf: []u8) !usize {
    return std.posix.read(stream.socket.handle, buf);
}

/// Write all bytes to a network stream via the Io writer interface.
fn streamWriteAll(stream: std.Io.net.Stream, data: []const u8) !void {
    var w_buf: [4096]u8 = undefined;
    var sw = stream.writer(io(), &w_buf);
    sw.interface.writeAll(data) catch return error.BrokenPipe;
    sw.interface.flush() catch return error.BrokenPipe;
}

/// Close a network stream.
fn streamClose(stream: std.Io.net.Stream) void {
    var copy = stream;
    copy.close(io());
}

// ============================================================================
// Public Constants
// ============================================================================

pub const ProtocolVersion = "2025-11-25";

// ============================================================================
// Public Types
// ============================================================================

pub const AuthMode = enum {
    none,
    bearer,
    basic,
    oauth2,
};

pub const ServerOptions = struct {
    name: []const u8,
    version: []const u8,
    instructions: ?[]const u8 = null,
    // GAP-050-052: ServerInfo metadata
    description: ?[]const u8 = null,
    website: ?[]const u8 = null,
    icons: ?[]const u8 = null, // JSON array of icon objects
    worker_threads: u16 = 0,
    max_message_bytes: usize = 8 * 1024 * 1024,
    max_batch_items: u32 = 256,
    max_inflight: u32 = 1024,
    http_bind: []const u8 = "127.0.0.1",
    http_port: u16 = 0,
    http_path: []const u8 = "/mcp",
    http_allowed_origins: ?[]const []const u8 = null, // null = allow localhost only
    auth_mode: AuthMode = .none,
    bearer_token: ?[]const u8 = null,
    basic_user: ?[]const u8 = null,
    basic_pass: ?[]const u8 = null,
    // GAP-029: Rate limiting options
    rate_limit_requests_per_second: u32 = 100, // 0 = unlimited
    rate_limit_burst: u32 = 200, // Allow burst up to this many
    // GAP-005: Request timeout options
    request_timeout_ms: u32 = 60000, // 60 seconds default, 0 = no timeout
    // GAP-035: Tasks capability options
    tasks_enabled: bool = false, // Enable async task support
    tasks_default_ttl_ms: u32 = 300000, // 5 minutes default TTL
    tasks_poll_interval_ms: u32 = 1000, // 1 second default poll interval
    // GAP-053-055: OAuth 2.1 enhancements
    oauth_resource_uri: ?[]const u8 = null, // GAP-054: Resource indicator (RFC 8707)
    oauth_dynamic_registration: bool = false, // GAP-055: Enable DCR endpoint
    oauth_client_metadata_cache_ms: u32 = 300000, // GAP-053: Cache client metadata for 5 min

    // Transport enhancements
    stdio_buffer_size: usize = 64 * 1024, // 64KB buffer for stdio
    websocket_enabled: bool = false, // Enable WebSocket transport
    websocket_path: []const u8 = "/ws",
    connection_pool_size: u16 = 10, // HTTP connection pool size
    connection_pool_timeout_ms: u32 = 30000, // Pool connection timeout
    sse_retry_ms: u32 = 3000, // SSE retry hint for clients (GAP-060)
    /// Streamable HTTP: a session with no request in flight and no open
    /// stream is dropped after this long idle (0 = never); its id then gets
    /// 404 (SONNY-6644).
    http_session_idle_timeout_ms: u32 = 30 * 60 * 1000,
    /// Streamable HTTP: connections served concurrently; more get 503.
    http_max_connections: u32 = 64,
    /// Streamable HTTP: a client must send its whole request within this
    /// long, else it gets 408 and is dropped (0 = no limit).
    http_request_timeout_ms: u32 = 30_000,

    // Performance options
    use_arena_allocator: bool = false, // Use arena for request processing
    arena_reset_threshold: usize = 1024 * 1024, // Reset arena after 1MB

    // Observability
    metrics_enabled: bool = false, // Enable metrics collection
    tracing_enabled: bool = false, // Enable request tracing
    health_check_path: []const u8 = "/health",
};

/// OAuth 2.1 Client Registration (GAP-055)
pub const OAuthClient = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    redirect_uris: ?[]const []const u8 = null,
    grant_types: ?[]const []const u8 = null,
    token_endpoint_auth_method: []const u8 = "client_secret_basic",
    client_name: ?[]const u8 = null,
    client_uri: ?[]const u8 = null,
    registered_at: i64 = 0,
};

/// OAuth 2.1 Token Info (GAP-054)
pub const OAuthToken = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_at: i64,
    resource: ?[]const u8 = null, // RFC 8707 resource indicator
    client_id: []const u8,
    scope: ?[]const u8 = null,
};

/// Cached client metadata from URL (GAP-053)
const CachedClientMetadata = struct {
    client_name: ?[]const u8 = null,
    redirect_uris: ?[]const u8 = null, // JSON array
    grant_types: ?[]const u8 = null, // JSON array
    token_endpoint_auth_method: ?[]const u8 = null,
    fetched_at: i64,
};

// ============================================================================
// HTTP Client for Outbound Connections
// ============================================================================

/// HTTP client for making outbound requests to external servers.
/// Uses Zig 0.15's std.http.Client with connection pooling.
pub const HttpClient = struct {
    allocator: Allocator,
    client: std.http.Client,
    default_timeout_ms: u32,

    /// HTTP methods supported
    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,

        pub fn toStd(self: Method) std.http.Method {
            return switch (self) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .DELETE => .DELETE,
                .PATCH => .PATCH,
                .HEAD => .HEAD,
                .OPTIONS => .OPTIONS,
            };
        }
    };

    /// HTTP response
    pub const Response = struct {
        status: u16,
        body: []const u8,
        allocator: Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    /// Request options
    pub const RequestOptions = struct {
        headers: ?[]const Header = null,
        body: ?[]const u8 = null,
        timeout_ms: ?u32 = null,

        pub const Header = struct {
            name: []const u8,
            value: []const u8,
        };
    };

    /// Initialize an HTTP client
    pub fn init(allocator: Allocator, options: struct {
        default_timeout_ms: u32 = 30000,
        pool_size: usize = 32,
        read_buffer_size: usize = 8192,
        write_buffer_size: usize = 1024,
    }) HttpClient {
        var client = std.http.Client{ .allocator = allocator };
        client.connection_pool.free_size = options.pool_size;
        client.read_buffer_size = options.read_buffer_size;
        client.write_buffer_size = options.write_buffer_size;
        return .{
            .allocator = allocator,
            .client = client,
            .default_timeout_ms = options.default_timeout_ms,
        };
    }

    /// Deinitialize the HTTP client
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Make an HTTP request using Zig 0.15's std.http.Client.fetch
    pub fn request(
        self: *HttpClient,
        method: Method,
        url: []const u8,
        options: RequestOptions,
    ) !Response {
        // Build extra headers if provided
        var extra_headers_list = std.ArrayListUnmanaged(std.http.Header).empty;
        defer extra_headers_list.deinit(self.allocator);

        if (options.headers) |hdrs| {
            for (hdrs) |h| {
                try extra_headers_list.append(self.allocator, .{
                    .name = h.name,
                    .value = h.value,
                });
            }
        }

        // Allocate response buffer
        var response_body = std.ArrayListUnmanaged(u8).empty;
        errdefer response_body.deinit(self.allocator);

        // Use fetch for simpler request handling
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = method.toStd(),
            .payload = options.body,
            .extra_headers = extra_headers_list.items,
            .response_writer = null, // We'll read via response storage
        }) catch |err| {
            return err;
        };

        // Copy body data if there is any
        const body = if (result.body) |b| blk: {
            const copy = try self.allocator.alloc(u8, b.len);
            @memcpy(copy, b);
            break :blk copy;
        } else try self.allocator.alloc(u8, 0);

        return .{
            .status = @intFromEnum(result.status),
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// Make a GET request
    pub fn get(self: *HttpClient, url: []const u8, options: RequestOptions) !Response {
        return self.request(.GET, url, options);
    }

    /// Make a POST request
    pub fn post(self: *HttpClient, url: []const u8, options: RequestOptions) !Response {
        return self.request(.POST, url, options);
    }

    /// Make a PUT request
    pub fn put(self: *HttpClient, url: []const u8, options: RequestOptions) !Response {
        return self.request(.PUT, url, options);
    }

    /// Make a DELETE request
    pub fn delete(self: *HttpClient, url: []const u8, options: RequestOptions) !Response {
        return self.request(.DELETE, url, options);
    }

    /// Make a JSON POST request
    pub fn postJson(self: *HttpClient, url: []const u8, json_body: []const u8) !Response {
        return self.request(.POST, url, .{
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
            .body = json_body,
        });
    }
};

// ============================================================================
// WebSocket Transport
// ============================================================================

/// WebSocket opcode types per RFC 6455
pub const WebSocketOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn isControl(self: WebSocketOpcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

/// WebSocket close status codes per RFC 6455
pub const WebSocketCloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    _,
};

/// WebSocket frame structure
pub const WebSocketFrame = struct {
    fin: bool,
    opcode: WebSocketOpcode,
    masked: bool,
    payload_len: u64,
    mask_key: [4]u8,
    payload: []const u8,

    /// Parse a WebSocket frame from bytes
    pub fn parse(data: []const u8) !struct { frame: WebSocketFrame, consumed: usize } {
        if (data.len < 2) return error.InsufficientData;

        const byte0 = data[0];
        const byte1 = data[1];

        const fin = (byte0 & 0x80) != 0;
        const opcode = @as(WebSocketOpcode, @enumFromInt(@as(u4, @truncate(byte0 & 0x0F))));
        const masked = (byte1 & 0x80) != 0;
        var payload_len: u64 = byte1 & 0x7F;

        var pos: usize = 2;

        // Extended payload length
        if (payload_len == 126) {
            if (data.len < pos + 2) return error.InsufficientData;
            payload_len = @as(u16, data[pos]) << 8 | @as(u16, data[pos + 1]);
            pos += 2;
        } else if (payload_len == 127) {
            if (data.len < pos + 8) return error.InsufficientData;
            payload_len = 0;
            for (0..8) |i| {
                payload_len = (payload_len << 8) | @as(u64, data[pos + i]);
            }
            pos += 8;
        }

        // Mask key (if present)
        var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            if (data.len < pos + 4) return error.InsufficientData;
            @memcpy(&mask_key, data[pos..][0..4]);
            pos += 4;
        }

        // Payload
        if (data.len < pos + payload_len) return error.InsufficientData;
        const payload = data[pos..][0..payload_len];

        return .{
            .frame = .{
                .fin = fin,
                .opcode = opcode,
                .masked = masked,
                .payload_len = payload_len,
                .mask_key = mask_key,
                .payload = payload,
            },
            .consumed = pos + payload_len,
        };
    }

    /// Unmask the payload (XOR with mask key)
    pub fn unmask(self: *const WebSocketFrame, allocator: Allocator) ![]u8 {
        if (!self.masked) {
            const copy = try allocator.alloc(u8, self.payload.len);
            @memcpy(copy, self.payload);
            return copy;
        }

        const result = try allocator.alloc(u8, self.payload.len);
        for (self.payload, 0..) |byte, i| {
            result[i] = byte ^ self.mask_key[i % 4];
        }
        return result;
    }

    /// Encode a WebSocket frame to bytes
    pub fn encode(
        allocator: Allocator,
        opcode: WebSocketOpcode,
        payload: []const u8,
        fin: bool,
        mask: bool,
    ) ![]u8 {
        var size: usize = 2; // Minimum header size

        // Calculate extended length bytes needed
        if (payload.len >= 126 and payload.len < 65536) {
            size += 2;
        } else if (payload.len >= 65536) {
            size += 8;
        }

        // Mask key
        if (mask) size += 4;

        // Payload
        size += payload.len;

        const frame = try allocator.alloc(u8, size);
        errdefer allocator.free(frame);

        var pos: usize = 0;

        // Byte 0: FIN + opcode
        frame[pos] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
        pos += 1;

        // Byte 1: MASK + payload length
        var len_byte: u8 = if (mask) 0x80 else 0;
        if (payload.len < 126) {
            len_byte |= @truncate(payload.len);
            frame[pos] = len_byte;
            pos += 1;
        } else if (payload.len < 65536) {
            len_byte |= 126;
            frame[pos] = len_byte;
            pos += 1;
            frame[pos] = @truncate(payload.len >> 8);
            pos += 1;
            frame[pos] = @truncate(payload.len);
            pos += 1;
        } else {
            len_byte |= 127;
            frame[pos] = len_byte;
            pos += 1;
            for (0..8) |i| {
                frame[pos] = @truncate(payload.len >> @intCast((7 - i) * 8));
                pos += 1;
            }
        }

        // Mask key (if masking, use random or zero)
        if (mask) {
            // For simplicity, use zero mask (not ideal for security but functional)
            frame[pos] = 0;
            frame[pos + 1] = 0;
            frame[pos + 2] = 0;
            frame[pos + 3] = 0;
            pos += 4;
        }

        // Payload (XOR with mask if masking)
        if (mask) {
            for (payload, 0..) |byte, i| {
                frame[pos + i] = byte; // With zero mask, no XOR needed
            }
        } else {
            @memcpy(frame[pos..][0..payload.len], payload);
        }

        return frame;
    }
};

/// WebSocket connection handler for MCP transport
pub const WebSocketConnection = struct {
    allocator: Allocator,
    stream: std.Io.net.Stream,
    session_id: []const u8,
    is_open: bool = true,
    fragment_buffer: std.ArrayListUnmanaged(u8) = .empty,
    fragment_opcode: ?WebSocketOpcode = null,

    pub fn init(allocator: Allocator, stream: std.Io.net.Stream, session_id: []const u8) !WebSocketConnection {
        const sid_copy = try allocator.dupe(u8, session_id);
        return .{
            .allocator = allocator,
            .stream = stream,
            .session_id = sid_copy,
        };
    }

    pub fn deinit(self: *WebSocketConnection) void {
        self.fragment_buffer.deinit(self.allocator);
        self.allocator.free(self.session_id);
        streamClose(self.stream);
    }

    /// Send a text message
    pub fn sendText(self: *WebSocketConnection, message: []const u8) !void {
        const frame = try WebSocketFrame.encode(self.allocator, .text, message, true, false);
        defer self.allocator.free(frame);
        try streamWriteAll(self.stream, frame);
    }

    /// Send a binary message
    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        const frame = try WebSocketFrame.encode(self.allocator, .binary, data, true, false);
        defer self.allocator.free(frame);
        try streamWriteAll(self.stream, frame);
    }

    /// Send a close frame
    pub fn sendClose(self: *WebSocketConnection, code: WebSocketCloseCode) !void {
        var payload: [2]u8 = undefined;
        const code_int = @intFromEnum(code);
        payload[0] = @truncate(code_int >> 8);
        payload[1] = @truncate(code_int);
        const frame = try WebSocketFrame.encode(self.allocator, .close, &payload, true, false);
        defer self.allocator.free(frame);
        streamWriteAll(self.stream, frame) catch {};
        self.is_open = false;
    }

    /// Send a ping frame
    pub fn sendPing(self: *WebSocketConnection, data: []const u8) !void {
        const frame = try WebSocketFrame.encode(self.allocator, .ping, data, true, false);
        defer self.allocator.free(frame);
        try streamWriteAll(self.stream, frame);
    }

    /// Send a pong frame
    pub fn sendPong(self: *WebSocketConnection, data: []const u8) !void {
        const frame = try WebSocketFrame.encode(self.allocator, .pong, data, true, false);
        defer self.allocator.free(frame);
        try streamWriteAll(self.stream, frame);
    }

    /// Read and process a WebSocket frame, returning the complete message payload
    /// Returns null for control frames that were handled internally
    pub fn receiveMessage(self: *WebSocketConnection, buffer: []const u8) !?struct { opcode: WebSocketOpcode, payload: []u8 } {
        const parsed = try WebSocketFrame.parse(buffer);
        const frame = parsed.frame;

        // Handle control frames
        if (frame.opcode.isControl()) {
            switch (frame.opcode) {
                .ping => {
                    // Respond with pong
                    const payload = try frame.unmask(self.allocator);
                    defer self.allocator.free(payload);
                    try self.sendPong(payload);
                    return null;
                },
                .pong => {
                    // Ignore pong frames
                    return null;
                },
                .close => {
                    // Send close response if we haven't already
                    if (self.is_open) {
                        self.sendClose(.normal) catch {};
                    }
                    return null;
                },
                else => return null,
            }
        }

        // Handle data frames
        const payload = try frame.unmask(self.allocator);

        if (!frame.fin) {
            // Fragment: save for later
            if (frame.opcode != .continuation) {
                self.fragment_opcode = frame.opcode;
                self.fragment_buffer.clearRetainingCapacity();
            }
            try self.fragment_buffer.appendSlice(self.allocator, payload);
            self.allocator.free(payload);
            return null;
        }

        // Final frame
        if (self.fragment_opcode) |opcode| {
            // Complete fragmented message
            try self.fragment_buffer.appendSlice(self.allocator, payload);
            self.allocator.free(payload);

            const complete = try self.allocator.dupe(u8, self.fragment_buffer.items);
            self.fragment_buffer.clearRetainingCapacity();
            self.fragment_opcode = null;

            return .{ .opcode = opcode, .payload = complete };
        }

        return .{ .opcode = frame.opcode, .payload = payload };
    }
};

/// Generate WebSocket accept key from client key (SHA-1 hash per RFC 6455).
///
/// FIPS-0008: SHA-1 is NOT FIPS-140-3 approved and RFC 6455 mandates it,
/// so there is no interop-preserving FIPS substitute. Under -Dfips=true
/// this capability is REMOVED (hard compile error); fips deployments must
/// front MCP with a TLS-terminating proxy or use a non-WebSocket transport.
pub fn generateWebSocketAcceptKey(client_key: []const u8) ![28]u8 {
    if (crypto_backend.fips_enabled) {
        @compileError("generateWebSocketAcceptKey: SHA-1 WebSocket handshake is not FIPS-140-3 approved and is removed under -Dfips=true (RFC 6455 mandates SHA-1; no approved substitute). Terminate WebSocket/TLS at a validated proxy instead.");
    }
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    // Concatenate client key with magic GUID
    // fips-exempt: non-security — WebSocket Sec-WebSocket-Accept SHA-1 (RFC 6455
    // handshake magic); non-fips path only, @compileError'd under -Dfips=true above.
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(magic);
    const hash = hasher.finalResult();

    // Base64 encode the result
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &hash);
    return result;
}

// ============================================================================
// Arena Allocator Support
// ============================================================================

/// Arena allocator wrapper for efficient per-request allocation.
/// All allocations within a request scope can be freed at once when the
/// request completes, improving performance for short-lived allocations.
pub const RequestArena = struct {
    arena: ArenaAllocator,
    parent_allocator: Allocator,
    reset_threshold: usize,
    bytes_allocated: usize = 0,

    /// Create a new request arena
    pub fn init(parent: Allocator, reset_threshold: usize) RequestArena {
        return .{
            .arena = ArenaAllocator.init(parent),
            .parent_allocator = parent,
            .reset_threshold = reset_threshold,
        };
    }

    /// Get the allocator interface for this arena
    pub fn allocator(self: *RequestArena) Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena, freeing all allocations at once.
    /// This is much faster than freeing individual allocations.
    pub fn reset(self: *RequestArena) void {
        // If we've exceeded the threshold, free memory back to parent
        if (self.bytes_allocated > self.reset_threshold) {
            _ = self.arena.reset(.free_all);
        } else {
            _ = self.arena.reset(.retain_capacity);
        }
        self.bytes_allocated = 0;
    }

    /// Deinitialize the arena
    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }

    /// Track allocation size (for threshold checking)
    pub fn trackAllocation(self: *RequestArena, size: usize) void {
        self.bytes_allocated += size;
    }
};

// ============================================================================
// Metrics and Observability
// ============================================================================

/// Metrics collector for MCP server observability
pub const Metrics = struct {
    /// Request counts by method
    requests_total: std.StringHashMapUnmanaged(u64) = .{},
    /// Error counts by error code
    errors_total: std.StringHashMapUnmanaged(u64) = .{},
    /// Request latency histogram buckets (in microseconds)
    latency_buckets: [12]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    /// Bucket boundaries (in microseconds): 100us, 500us, 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s, 10s, inf
    bucket_boundaries: [11]u64 = .{ 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000, 5000000, 10000000 },
    /// Current active connections
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Total bytes received
    bytes_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total bytes sent
    bytes_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Mutex for non-atomic operations
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Allocator for hash maps
    allocator: Allocator,

    pub fn init(alloc: Allocator) Metrics {
        return .{ .allocator = alloc };
    }

    pub fn deinit(self: *Metrics) void {
        self.requests_total.deinit(self.allocator);
        self.errors_total.deinit(self.allocator);
    }

    /// Record a request
    pub fn recordRequest(self: *Metrics, method: []const u8, latency_us: u64) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        // Increment request count
        if (self.requests_total.getPtr(method)) |count| {
            count.* += 1;
        } else {
            self.requests_total.put(self.allocator, method, 1) catch {};
        }

        // Update latency histogram
        var bucket_idx: usize = self.bucket_boundaries.len;
        for (self.bucket_boundaries, 0..) |boundary, i| {
            if (latency_us <= boundary) {
                bucket_idx = i;
                break;
            }
        }
        self.latency_buckets[bucket_idx] += 1;
    }

    /// Record an error
    pub fn recordError(self: *Metrics, error_code: []const u8) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        if (self.errors_total.getPtr(error_code)) |count| {
            count.* += 1;
        } else {
            self.errors_total.put(self.allocator, error_code, 1) catch {};
        }
    }

    /// Update active connections count
    pub fn connectionOpened(self: *Metrics) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn connectionClosed(self: *Metrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    /// Update byte counters
    pub fn recordBytesReceived(self: *Metrics, bytes: u64) void {
        _ = self.bytes_received.fetchAdd(bytes, .monotonic);
    }

    pub fn recordBytesSent(self: *Metrics, bytes: u64) void {
        _ = self.bytes_sent.fetchAdd(bytes, .monotonic);
    }

    /// Export metrics in Prometheus format
    pub fn exportPrometheus(self: *Metrics, alloc: Allocator) ![]const u8 {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(alloc);

        // Active connections
        try buf.appendSlice(alloc, "# HELP mcp_active_connections Current number of active connections\n");
        try buf.appendSlice(alloc, "# TYPE mcp_active_connections gauge\n");
        try buf.print(alloc, "mcp_active_connections {d}\n\n", .{self.active_connections.load(.monotonic)});

        // Bytes counters
        try buf.appendSlice(alloc, "# HELP mcp_bytes_received_total Total bytes received\n");
        try buf.appendSlice(alloc, "# TYPE mcp_bytes_received_total counter\n");
        try buf.print(alloc, "mcp_bytes_received_total {d}\n\n", .{self.bytes_received.load(.monotonic)});

        try buf.appendSlice(alloc, "# HELP mcp_bytes_sent_total Total bytes sent\n");
        try buf.appendSlice(alloc, "# TYPE mcp_bytes_sent_total counter\n");
        try buf.print(alloc, "mcp_bytes_sent_total {d}\n\n", .{self.bytes_sent.load(.monotonic)});

        // Request counts by method
        try buf.appendSlice(alloc, "# HELP mcp_requests_total Total requests by method\n");
        try buf.appendSlice(alloc, "# TYPE mcp_requests_total counter\n");
        var req_iter = self.requests_total.iterator();
        while (req_iter.next()) |entry| {
            try buf.print(alloc, "mcp_requests_total{{method=\"{s}\"}} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try buf.append(alloc, '\n');

        // Error counts
        try buf.appendSlice(alloc, "# HELP mcp_errors_total Total errors by code\n");
        try buf.appendSlice(alloc, "# TYPE mcp_errors_total counter\n");
        var err_iter = self.errors_total.iterator();
        while (err_iter.next()) |entry| {
            try buf.print(alloc, "mcp_errors_total{{code=\"{s}\"}} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try buf.append(alloc, '\n');

        // Latency histogram
        try buf.appendSlice(alloc, "# HELP mcp_request_latency_microseconds Request latency histogram\n");
        try buf.appendSlice(alloc, "# TYPE mcp_request_latency_microseconds histogram\n");
        var cumulative: u64 = 0;
        for (self.bucket_boundaries, 0..) |boundary, i| {
            cumulative += self.latency_buckets[i];
            try buf.print(alloc, "mcp_request_latency_microseconds_bucket{{le=\"{d}\"}} {d}\n", .{ boundary, cumulative });
        }
        cumulative += self.latency_buckets[self.bucket_boundaries.len];
        try buf.print(alloc, "mcp_request_latency_microseconds_bucket{{le=\"+Inf\"}} {d}\n", .{cumulative});

        return buf.toOwnedSlice(alloc);
    }
};

/// Simple request tracing for debugging and observability
pub const Trace = struct {
    id: u64,
    method: []const u8,
    start_time: i64,
    spans: std.ArrayListUnmanaged(Span) = .empty,
    alloc: Allocator,

    pub const Span = struct {
        name: []const u8,
        start_us: i64,
        end_us: i64,
    };

    pub fn init(alloc: Allocator, id: u64, method: []const u8) Trace {
        return .{
            .id = id,
            .method = method,
            .start_time = std.time.microTimestamp(),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Trace) void {
        self.spans.deinit(self.alloc);
    }

    /// Start a new span
    pub fn startSpan(self: *Trace, name: []const u8) usize {
        const idx = self.spans.items.len;
        self.spans.append(self.alloc, .{
            .name = name,
            .start_us = std.time.microTimestamp(),
            .end_us = 0,
        }) catch {};
        return idx;
    }

    /// End a span
    pub fn endSpan(self: *Trace, idx: usize) void {
        if (idx < self.spans.items.len) {
            self.spans.items[idx].end_us = std.time.microTimestamp();
        }
    }

    /// Get total duration in microseconds
    pub fn durationUs(self: *const Trace) i64 {
        return std.time.microTimestamp() - self.start_time;
    }
};

/// Health check status
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,

    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
};

/// Health check response
pub const HealthCheck = struct {
    status: HealthStatus = .healthy,
    version: []const u8,
    uptime_seconds: i64 = 0,
    checks: std.StringHashMapUnmanaged(HealthStatus) = .{},

    /// Export health check as JSON
    pub fn toJson(self: *const HealthCheck, alloc: Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(alloc);

        try buf.appendSlice(alloc, "{\"status\":\"");
        try buf.appendSlice(alloc, self.status.toString());
        try buf.appendSlice(alloc, "\",\"version\":\"");
        try buf.appendSlice(alloc, self.version);
        try buf.print(alloc, "\",\"uptime_seconds\":{d}", .{self.uptime_seconds});

        if (self.checks.count() > 0) {
            try buf.appendSlice(alloc, ",\"checks\":{");
            var first = true;
            var iter = self.checks.iterator();
            while (iter.next()) |entry| {
                if (!first) try buf.append(alloc, ',');
                first = false;
                try buf.print(alloc, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.*.toString() });
            }
            try buf.append(alloc, '}');
        }

        try buf.append(alloc, '}');
        return buf.toOwnedSlice(alloc);
    }
};

/// Cancellation signal passed to `Handler.callTool`. The server sets it when
/// the client sends `notifications/cancelled` for the request (string or
/// integer id) or when `checkRequestTimeouts` expires it. A handler
/// that stops early returns `error.Cancelled`; when the client cancelled the
/// request the server then sends no response (MCP cancellation, SONNY-6585).
pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    by_peer: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }

    /// True when the cancellation came from the client's
    /// `notifications/cancelled`, not from a server-side timeout.
    pub fn isCancelledByPeer(self: *const CancelToken) bool {
        return self.by_peer.load(.acquire);
    }

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }

    fn cancelByPeer(self: *CancelToken) void {
        self.by_peer.store(true, .release);
        self.cancel();
    }
};

pub const Session = struct {
    allocator: Allocator,
    server: *Server,
    session_id: ?[]const u8 = null,
    /// The Streamable HTTP client this session talks to, or null for stdio
    /// (SONNY-6644). Its messages go only to that client.
    http: ?*HttpSession = null,
    pending_requests: std.AutoHashMap(i64, *RequestContext),
    next_request_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    const RequestContext = struct {
        id: i64,
        response: ?[]const u8 = null,
        err: ?anyerror = null,
        done: std.Io.Event = .unset,
    };

    pub fn init(allocator: Allocator, server: *Server) Session {
        return .{
            .allocator = allocator,
            .server = server,
            .pending_requests = std.AutoHashMap(i64, *RequestContext).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        self.pending_requests.deinit();
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
    }

    /// Sends a notification to the client. `method` is JSON-escaped;
    /// `params_json`, when given, must be exactly one JSON value (it is sent
    /// minified) or `error.InvalidParamsJson` is returned and nothing is sent.
    pub fn notify(self: *Session, method: []const u8, params_json: ?[]const u8) anyerror!void {
        const notification = try self.buildNotification(method, params_json);
        defer self.allocator.free(notification);
        try self.server.deliver(self.http, notification);
    }

    /// Sends a request to the client and waits up to `timeout_ms` for its
    /// response, which `Server.processMessage` delivers when the client's
    /// reply arrives. Returns the `result` as minified JSON, allocated with
    /// the session allocator (the caller frees it); `error.ClientError` when
    /// the client answered with a JSON-RPC error; `error.Timeout` when no
    /// response arrived. `params_json` follows the `notify` rules.
    pub fn request(self: *Session, method: []const u8, params_json: ?[]const u8, timeout_ms: u32) anyerror![]const u8 {
        // Observability seam: wrap the round-trip in a client-side RPC
        // span. The seam is null-tracer-safe (no panic when otel isn't
        // initialized) and the disabled build collapses to a no-op.
        // The defer is the lifecycle backstop; the success path below
        // overwrites status to .ok before ending.
        var __obs_span = observability.startRpcClientSpan(method);
        defer __obs_span.end(null);
        errdefer observability.endRpcClientSpan(__obs_span, false, JsonRpcError.InternalError);

        const id = self.next_request_id.fetchAdd(1, .monotonic);

        // Build (and validate) the request before registering it, so a bad
        // params_json leaves nothing pending.
        const req = try self.buildRequest(id, method, params_json);
        defer self.allocator.free(req);

        var ctx = RequestContext{ .id = id };

        {
            self.mutex.lockUncancelable(io());
            defer self.mutex.unlock(io());
            try self.pending_requests.put(id, &ctx);
        }
        var removed = false;
        defer if (!removed) {
            self.mutex.lockUncancelable(io());
            defer self.mutex.unlock(io());
            _ = self.pending_requests.remove(id);
        };

        try self.server.deliver(self.http, req);

        // Wait for the client's response (resolved by Server.resolveClientResponse).
        const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
        const timed_out = if (ctx.done.waitTimeout(io(), .{ .duration = .{ .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)), .clock = .awake } })) false else |_| true;

        // Deregister under the mutex: once it is released no response can
        // touch ctx, so a response that raced the timeout is returned (and
        // not leaked).
        {
            self.mutex.lockUncancelable(io());
            defer self.mutex.unlock(io());
            _ = self.pending_requests.remove(id);
            removed = true;
        }

        if (ctx.response) |response| {
            observability.endRpcClientSpan(__obs_span, true, 0);
            return response;
        }
        if (ctx.err) |e| return e;
        if (timed_out) return error.Timeout;
        return error.NoResponse;
    }

    /// Fails every request still waiting for the client with `err` (the
    /// session ended or the server stopped).
    fn failPending(self: *Session, err: anyerror) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        var it = self.pending_requests.valueIterator();
        while (it.next()) |ctx| {
            ctx.*.err = err;
            ctx.*.done.set(io());
        }
        self.pending_requests.clearRetainingCapacity();
    }

    fn buildNotification(self: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return buildMessageJson(self.allocator, null, method, params_json);
    }

    fn buildRequest(self: *Session, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return buildMessageJson(self.allocator, id, method, params_json);
    }
};

/// Client capabilities parsed from initialize request (GAP-002)
pub const ClientCapabilities = struct {
    roots: bool = false,
    roots_list_changed: bool = false,
    sampling: bool = false,
    sampling_tools: bool = false, // GAP-057: Client supports tool calling in sampling
    sampling_context: bool = false, // GAP-058: Client supports context inclusion in sampling
    elicitation: bool = false, // GAP-041: Client supports elicitation
    experimental: ?[]const u8 = null, // GAP-026: Raw JSON of experimental capabilities
};

/// Sampling request parameters (GAP-056)
pub const SamplingRequest = struct {
    /// Required: Messages for the LLM (as JSON string)
    messages_json: []const u8,
    /// Required: Maximum tokens to generate
    max_tokens: u32,
    /// Optional: System prompt for the LLM
    system_prompt: ?[]const u8 = null,
    /// Optional: Temperature for sampling (0.0 to 1.0)
    temperature: ?f64 = null,
    /// Optional: Stop sequences
    stop_sequences: ?[]const []const u8 = null,
    /// Optional: Tools available to the model (as JSON string)
    tools_json: ?[]const u8 = null,
    /// Optional: Tool choice mode ("auto", "required", "none")
    tool_choice: ?[]const u8 = null,
    /// Optional: Model preferences (as JSON string)
    model_preferences_json: ?[]const u8 = null,
    /// Optional: Context inclusion scope ("none", "thisServer", "allServers")
    include_context: ?[]const u8 = null,
    /// Optional: Provider-specific metadata (as JSON string)
    metadata_json: ?[]const u8 = null,
};

/// Client info from initialize request
pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Task state (GAP-035)
pub const TaskState = enum {
    working,
    input_required,
    completed,
    failed,
    cancelled,

    pub fn isTerminal(self: TaskState) bool {
        return self == .completed or self == .failed or self == .cancelled;
    }
};

/// Task info for async request tracking (GAP-035-040)
pub const Task = struct {
    id: []const u8,
    status: TaskState,
    created_at: i64,
    last_updated: i64,
    ttl_ms: u32,
    poll_interval_ms: u32,
    result: ?[]const u8, // Stored result JSON when completed
    method: []const u8, // Original method name
    /// Mcp-Session-Id of the Streamable HTTP client that created the task,
    /// null for stdio. Only that client can see it (SONNY-6644).
    owner: ?[]const u8 = null,

    /// Frees a task returned by `Server.createTask` or `Server.getTask`
    /// (pass the server's allocator).
    pub fn deinit(self: *Task, allocator: Allocator) void {
        if (self.result) |r| allocator.free(r);
        if (self.owner) |o| allocator.free(o);
        allocator.free(self.method);
        allocator.free(self.id);
        self.* = undefined;
    }

    /// An owned deep copy (strings duplicated with `allocator`).
    fn clone(self: *const Task, allocator: Allocator) !Task {
        var copy = self.*;
        copy.id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(copy.id);
        copy.method = try allocator.dupe(u8, self.method);
        errdefer allocator.free(copy.method);
        copy.result = if (self.result) |r| try allocator.dupe(u8, r) else null;
        errdefer if (copy.result) |r| allocator.free(r);
        copy.owner = if (self.owner) |o| try allocator.dupe(u8, o) else null;
        return copy;
    }

    pub fn toJson(self: *const Task, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        try buf.print(allocator,
            \\{{"taskId":"{s}","status":"{s}","createdAt":{d},"lastUpdatedAt":{d},"ttl":{d},"pollInterval":{d}}}
        , .{
            self.id,
            @tagName(self.status),
            self.created_at,
            self.last_updated,
            self.ttl_ms,
            self.poll_interval_ms,
        });
        return buf.toOwnedSlice(allocator);
    }
};

/// Request tracking info for timeout/cancellation (GAP-005, GAP-024)
const RequestInfo = struct {
    token: *CancelToken,
    start_time: i64,
};

/// Handler callbacks for MCP server operations.
///
/// ## Content Types (GAP-027, GAP-028)
///
/// Tool results (callTool), prompts (getPrompt), and resources (readResource) can return
/// various content types. Return these as JSON arrays of content objects:
///
/// ### Text Content
/// ```json
/// {"type": "text", "text": "Plain text content"}
/// ```
///
/// ### Image Content
/// ```json
/// {"type": "image", "data": "<base64-encoded-data>", "mimeType": "image/png"}
/// ```
///
/// ### Audio Content (GAP-027)
/// ```json
/// {"type": "audio", "data": "<base64-encoded-audio>", "mimeType": "audio/wav"}
/// ```
/// Supported formats: audio/wav, audio/mp3, audio/ogg, audio/webm, etc.
///
/// ### Resource Link
/// ```json
/// {"type": "resource_link", "uri": "file:///path/to/file", "name": "file.txt",
///  "description": "File description", "mimeType": "text/plain"}
/// ```
///
/// ### Embedded Resource (GAP-028)
/// ```json
/// {"type": "resource", "resource": {
///   "uri": "file:///path/to/file",
///   "mimeType": "text/plain",
///   "text": "File contents here"
/// }}
/// ```
/// For binary resources, use "blob" with base64-encoded data instead of "text".
///
/// ### Annotations (optional on all content types)
/// ```json
/// {"type": "text", "text": "...", "annotations": {
///   "audience": ["user", "assistant"],
///   "priority": 0.9,
///   "lastModified": "2025-01-03T12:00:00Z"
/// }}
/// ```
///
/// ## Tool Metadata (GAP-042-045)
///
/// listTools should return tools with optional metadata fields:
/// ```json
/// {"tools": [{
///   "name": "my-tool",
///   "description": "What the tool does",
///   "inputSchema": {"type": "object", "properties": {...}},
///   "title": "My Tool",                    // GAP-042: Display name
///   "icons": [{"src": "icon.png", "mimeType": "image/png", "sizes": ["32x32"]}],  // GAP-043
///   "outputSchema": {"type": "object"},    // GAP-044: Result validation schema
///   "annotations": {                        // GAP-045: Behavior metadata
///     "destructive": false,
///     "idempotent": true,
///     "openWorld": false
///   }
/// }]}
/// ```
///
/// ## Prompt Metadata (GAP-046-047)
///
/// listPrompts should return prompts with optional metadata:
/// ```json
/// {"prompts": [{
///   "name": "my-prompt",
///   "description": "What the prompt does",
///   "title": "My Prompt",                  // GAP-046: Display name
///   "icons": [{"src": "icon.png", "mimeType": "image/png"}],  // GAP-047
///   "arguments": [{"name": "arg1", "required": true}]
/// }]}
/// ```
///
/// ## Resource Metadata (GAP-048-049)
///
/// listResources should return resources with optional metadata:
/// ```json
/// {"resources": [{
///   "uri": "file:///path/to/file",
///   "name": "file.txt",
///   "title": "My File",                    // GAP-048: Display name
///   "icons": [{"src": "icon.png", "mimeType": "image/png"}],  // GAP-049
///   "mimeType": "text/plain"
/// }]}
/// ```
///
/// ## Result Ownership (SONNY-6531)
///
/// Every callback that returns `[]const u8` (`listTools`, `callTool`,
/// `listResources`, `readResource`, `listResourceTemplates`, `listPrompts`,
/// `getPrompt`, `complete`) transfers ownership of the returned slice to the
/// server. The server frees it with the allocator it was constructed with
/// (`Server.allocator`) once the JSON-RPC response has been built, and also
/// when the request was a notification (no response is sent) or building the
/// response failed. Implementations MUST therefore return bytes allocated
/// with that same allocator on every successful call: a static/comptime
/// string literal, a slice into a buffer the handler keeps, or bytes from
/// another allocator would be freed by the server (an invalid free). To
/// return fixed text, `dupe` it: `return allocator.dupe(u8, "{...}");`.
/// A callback that returns an error hands nothing over and must free
/// anything it allocated itself. Argument slices (`cursor`, `name`, `uri`,
/// `args_json`, `params_json`, `level`) are borrowed from the server and are
/// only valid for the duration of the call.
///
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    /// `tools/list`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above).
    listTools: *const fn (ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    /// `tools/call`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above); owned since v0.1.12. Tool
    /// responses are typically per-call heap allocations (JSON built from
    /// user/tool-supplied data), so a server that did not free them would
    /// leak for its whole lifetime.
    callTool: *const fn (ctx: ?*anyopaque, name: []const u8, args_json: []const u8, cancel: *const CancelToken) anyerror![]const u8,
    /// `resources/list`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above).
    listResources: *const fn (ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    /// `resources/read`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above). Resource contents are usually
    /// read or rendered per call, so this is the callback most likely to
    /// leak if it were not freed.
    readResource: *const fn (ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8,
    /// `resources/templates/list`. Returns a `Server.allocator`-owned slice
    /// the server frees (see "Result Ownership" above).
    listResourceTemplates: *const fn (ctx: ?*anyopaque) anyerror![]const u8,
    subscribeResource: *const fn (ctx: ?*anyopaque, uri: []const u8) anyerror!void,
    unsubscribeResource: *const fn (ctx: ?*anyopaque, uri: []const u8) anyerror!void, // GAP-022
    /// `prompts/list`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above).
    listPrompts: *const fn (ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8,
    /// `prompts/get`. Returns a `Server.allocator`-owned slice the server
    /// frees (see "Result Ownership" above). `args_json` is the serialized
    /// `arguments` object (or null) and is freed by the server after the call.
    getPrompt: *const fn (ctx: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8,
    /// `completion/complete`. Returns a `Server.allocator`-owned slice the
    /// server frees (see "Result Ownership" above). `params_json` is the
    /// serialized request params and is freed by the server after the call.
    complete: *const fn (ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8,
    setLogLevel: *const fn (ctx: ?*anyopaque, level: []const u8) anyerror!void,
};

// ============================================================================
// JSON-RPC Types
// ============================================================================

const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,

    // Standard JSON-RPC 2.0 error codes
    const ParseError: i32 = -32700;
    const InvalidRequest: i32 = -32600;
    const MethodNotFound: i32 = -32601;
    const InvalidParams: i32 = -32602;
    const InternalError: i32 = -32603;

    // MCP-specific error codes (GAP-031). MCP 2025-11-25 server/resources:
    // resource not found is -32002. server/tools and server/prompts: an
    // unknown tool and an invalid prompt name are -32602 (SONNY-6585).
    const ResourceNotFound: i32 = -32002;
    const ToolNotFound: i32 = InvalidParams;
    const PromptNotFound: i32 = InvalidParams;
    const NotInitialized: i32 = -32003;
};

// ============================================================================
// Handler-supplied error detail (SONNY-6585)
// ============================================================================

const ErrorDetail = struct {
    allocator: Allocator,
    message: []u8,
    data_json: ?[]u8,

    fn deinit(self: ErrorDetail) void {
        self.allocator.free(self.message);
        if (self.data_json) |d| self.allocator.free(d);
    }
};

/// Detail set by the handler running on this thread. The server dispatches
/// each message, and calls its handler, on a single thread, so a handler's
/// detail is never seen by another request.
threadlocal var error_detail: ?ErrorDetail = null;

/// Sets the JSON-RPC error `message` and optional `data` for the error the
/// calling handler is about to return. Call it from inside a `Handler`
/// callback, then return the error; the error code still comes from the
/// error (`error.ToolNotFound` -> -32602, `error.ResourceNotFound` -> -32002,
/// ...). Without a detail the message is the error name.
///
/// `message` and `data_json` are copied with `allocator`, which the server
/// uses to free them once the response is built, when the request was a
/// notification, or when the handler succeeds after all. A later call
/// replaces an earlier one. `data_json` must be exactly one JSON value (for
/// example `{"uri":"file:///x"}`); it is sent minified. Anything else
/// returns `error.InvalidErrorData` and stores nothing.
pub fn setErrorDetail(
    allocator: Allocator,
    message: []const u8,
    data_json: ?[]const u8,
) error{ InvalidErrorData, OutOfMemory }!void {
    const data: ?[]u8 = if (data_json) |raw| blk: {
        var err_info = json.ParseError.init();
        var doc = json.parse(allocator, raw, .{}, &err_info) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidErrorData,
        };
        defer doc.deinit();
        break :blk json.stringify(allocator, doc.root) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidErrorData,
        };
    } else null;
    errdefer if (data) |d| allocator.free(d);

    const owned_message = try allocator.dupe(u8, message);
    clearErrorDetail();
    error_detail = .{ .allocator = allocator, .message = owned_message, .data_json = data };
}

fn takeErrorDetail() ?ErrorDetail {
    const detail = error_detail;
    error_detail = null;
    return detail;
}

fn clearErrorDetail() void {
    if (takeErrorDetail()) |d| d.deinit();
}

/// Appends `raw`, which must be exactly one JSON value, re-serialised
/// without insignificant whitespace, so a pretty-printed handler result
/// cannot put a raw newline into a newline-delimited stdio message.
/// Returns `error.InvalidHandlerResult` when `raw` is not one JSON value.
fn appendCompactJson(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(allocator, raw, .{
        .max_bytes = @max(raw.len, 1),
        .max_nodes = std.math.maxInt(u32),
        .unique_keys = false,
    }, &err_info) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHandlerResult,
    };
    defer doc.deinit();
    const compact = json.stringify(allocator, doc.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHandlerResult,
    };
    defer allocator.free(compact);
    try buf.appendSlice(allocator, compact);
}

/// Appends caller-supplied `params_json` minified, or returns
/// `error.InvalidParamsJson` when it is not exactly one JSON value.
fn appendParamsJson(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
    appendCompactJson(allocator, buf, raw) catch |e| switch (e) {
        error.InvalidHandlerResult => return error.InvalidParamsJson,
        else => |other| return other,
    };
}

/// Builds a server-to-client JSON-RPC request (`id` set) or notification.
/// `method` is escaped and `params_json` validated (see `appendParamsJson`).
fn buildMessageJson(allocator: Allocator, id: ?i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",");
    if (id) |i| try buf.print(allocator, "\"id\":{d},", .{i});
    try buf.appendSlice(allocator, "\"method\":");
    try appendJsonString(allocator, &buf, method);
    if (params_json) |p| {
        try buf.appendSlice(allocator, ",\"params\":");
        try appendParamsJson(allocator, &buf, p);
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Appends `s` as a JSON string literal: quotes, backslashes and control
/// characters are escaped and invalid UTF-8 becomes U+FFFD, so the output is
/// always valid JSON whatever bytes `s` holds.
fn appendJsonString(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    try appendJsonStringContents(allocator, buf, s);
    try buf.append(allocator, '"');
}

/// `appendJsonString` without the surrounding quotes.
fn appendJsonStringContents(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                0x08 => try buf.appendSlice(allocator, "\\b"),
                0x0c => try buf.appendSlice(allocator, "\\f"),
                0x00...0x07, 0x0b, 0x0e...0x1f => try buf.print(allocator, "\\u{x:0>4}", .{c}),
                else => try buf.append(allocator, c),
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (len == 0 or i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) {
            try buf.appendSlice(allocator, "\\ufffd");
            i += 1;
            continue;
        }
        try buf.appendSlice(allocator, s[i .. i + len]);
        i += len;
    }
}

const RequestId = union(enum) {
    int: i64,
    str: []const u8,
};

// ============================================================================
// SSE Event Buffer for Last-Event-ID Resumption (GAP-059)
// ============================================================================

/// Ring buffer to store recent SSE events for client resumption
const SseEventBuffer = struct {
    /// Maximum number of events to store
    const BUFFER_SIZE: usize = 256;

    /// Stored SSE event
    const Event = struct {
        id: u64,
        data: []const u8,
        allocator: Allocator,

        fn deinit(self: *Event) void {
            self.allocator.free(self.data);
        }
    };

    /// Events stored in ring buffer
    events: [BUFFER_SIZE]?Event = [_]?Event{null} ** BUFFER_SIZE,
    /// Current write position
    write_pos: usize = 0,
    /// Lowest event ID still in buffer (for fast rejection of old IDs)
    min_event_id: u64 = 0,
    /// Mutex for thread-safe access
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Store a new event in the buffer
    pub fn store(self: *SseEventBuffer, allocator: Allocator, event_id: u64, data: []const u8) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        // Free old event at this position if present
        if (self.events[self.write_pos]) |*old_event| {
            old_event.deinit();
        }

        // Store new event with copied data
        self.events[self.write_pos] = .{
            .id = event_id,
            .data = allocator.dupe(u8, data) catch return,
            .allocator = allocator,
        };

        // Update min event ID if buffer is full
        self.write_pos = (self.write_pos + 1) % BUFFER_SIZE;
        if (event_id > BUFFER_SIZE) {
            self.min_event_id = event_id - BUFFER_SIZE + 1;
        }
    }

    /// Get events after a given event ID for replay
    /// Returns events that should be replayed, caller must NOT free the data slices
    pub fn getEventsAfter(self: *SseEventBuffer, after_id: u64, out: []Event, max_count: usize) usize {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        // Quick reject if ID is too old
        if (after_id > 0 and after_id < self.min_event_id) {
            return 0; // Events no longer available
        }

        var count: usize = 0;
        for (&self.events) |*maybe_event| {
            if (count >= max_count or count >= out.len) break;
            if (maybe_event.*) |event| {
                if (event.id > after_id) {
                    out[count] = event;
                    count += 1;
                }
            }
        }

        // Sort by event ID to ensure proper replay order
        std.mem.sort(Event, out[0..count], {}, struct {
            fn lessThan(_: void, a: Event, b: Event) bool {
                return a.id < b.id;
            }
        }.lessThan);

        return count;
    }

    /// Clean up all stored events
    pub fn deinit(self: *SseEventBuffer) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());

        for (&self.events) |*maybe_event| {
            if (maybe_event.*) |*event| {
                event.deinit();
                maybe_event.* = null;
            }
        }
    }
};

// ============================================================================
// Per-client state (SONNY-6644)
// ============================================================================

/// In-flight requests by id, for cancellation and duplicate detection
/// (GAP-024, SONNY-6643). There is one per client: the server's own (stdio
/// and direct `processMessage`) and one per Streamable HTTP session, so ids
/// and cancellations never cross clients.
const RequestRegistry = struct {
    int_ids: std.AutoHashMapUnmanaged(i64, RequestInfo) = .{},
    /// Keys borrow the id from the parsed message, which outlives the
    /// registration.
    str_ids: std.StringHashMapUnmanaged(RequestInfo) = .{},
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn deinit(self: *RequestRegistry, allocator: Allocator) void {
        self.int_ids.deinit(allocator);
        self.str_ids.deinit(allocator);
    }

    /// Returns `error.DuplicateRequestId`, leaving the existing entry alone,
    /// when a request with the same id is still in flight.
    fn register(self: *RequestRegistry, allocator: Allocator, request_id: RequestId, token: *CancelToken) error{ DuplicateRequestId, OutOfMemory }!void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        const info: RequestInfo = .{
            .token = token,
            .start_time = std.Io.Timestamp.now(io(), .real).toMilliseconds(),
        };
        switch (request_id) {
            .int => |i| {
                const gop = try self.int_ids.getOrPut(allocator, i);
                if (gop.found_existing) return error.DuplicateRequestId;
                gop.value_ptr.* = info;
            },
            .str => |str| {
                const gop = try self.str_ids.getOrPut(allocator, str);
                if (gop.found_existing) return error.DuplicateRequestId;
                gop.value_ptr.* = info;
            },
        }
    }

    fn unregister(self: *RequestRegistry, request_id: RequestId) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        switch (request_id) {
            .int => |i| _ = self.int_ids.remove(i),
            .str => |str| _ = self.str_ids.remove(str),
        }
    }

    /// String and integer ids are distinct: "7" does not match 7.
    fn cancel(self: *RequestRegistry, request_id: RequestId) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        const info = switch (request_id) {
            .int => |i| self.int_ids.get(i),
            .str => |str| self.str_ids.get(str),
        };
        if (info) |i| i.token.cancelByPeer();
    }

    fn expire(self: *RequestRegistry, now: i64, timeout_ms: i64) void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        var iter = self.int_ids.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.start_time > timeout_ms) entry.value_ptr.token.cancel();
        }
        var str_iter = self.str_ids.iterator();
        while (str_iter.next()) |entry| {
            if (now - entry.value_ptr.start_time > timeout_ms) entry.value_ptr.token.cancel();
        }
    }
};

/// What a client negotiated in `initialize`.
const ClientState = struct {
    initialized: bool = false,
    capabilities: ClientCapabilities = .{},
    protocol_version: ?[]const u8 = null,

    fn deinit(self: *ClientState, allocator: Allocator) void {
        if (self.protocol_version) |v| allocator.free(v);
        if (self.capabilities.experimental) |e| allocator.free(e);
    }
};

/// Pointers to the state of the client being served: an HTTP session's, or
/// the server's own fields for stdio and direct `processMessage`.
const ClientStateRef = struct {
    initialized: *bool,
    capabilities: *ClientCapabilities,
    protocol_version: *?[]const u8,
};

/// One Streamable HTTP client (MCP 2025-11-25 basic/transports), created at
/// `initialize` and identified by its `MCP-Session-Id`. Everything the
/// server says to this client goes only to this client's streams.
const HttpSession = struct {
    server: *Server,
    /// Owned; also the key in `Server.http_sessions`.
    id: []u8,
    /// References from connection threads and `SessionRef`s. Guarded by
    /// `Server.sessions_mutex`, like `closed` and `last_active_ms`.
    refs: u32 = 0,
    closed: bool = false,
    last_active_ms: i64,
    client: ClientState = .{},
    /// Server-to-client requests waiting for this client's responses.
    session: Session,
    requests: RequestRegistry = .{},
    /// The standalone GET stream, written under `stream_mutex`.
    stream_mutex: std.Io.Mutex = std.Io.Mutex.init,
    get_stream: ?std.Io.net.Stream = null,
    /// Messages sent to the GET stream, for `Last-Event-ID` replay. Only
    /// this session's own events are ever replayed to it.
    events: SseEventBuffer = .{},
    /// SSE event ids, unique across all streams of this session.
    next_event_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    fn sendOnGetStream(self: *HttpSession, data: []const u8) !void {
        self.stream_mutex.lockUncancelable(io());
        defer self.stream_mutex.unlock(io());
        const id = self.next_event_id.fetchAdd(1, .monotonic);
        self.events.store(self.server.allocator, id, data);
        const stream = self.get_stream orelse return error.NoClientStream;
        try writeSseEvent(stream, id, data);
    }
};

/// The SSE response stream of a POSTed request: messages related to that
/// request are sent here, before its response (Streamable HTTP).
const PostStream = struct {
    stream: std.Io.net.Stream,
    session: *HttpSession,
    accepts_sse: bool,
    started: bool = false,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn sendEvent(self: *PostStream, data: []const u8) !void {
        self.mutex.lockUncancelable(io());
        defer self.mutex.unlock(io());
        if (!self.started) {
            try writeSseHead(self.stream, self.session.id);
            self.started = true;
        }
        const id = self.session.next_event_id.fetchAdd(1, .monotonic);
        try writeSseEvent(self.stream, id, data);
    }
};

/// Which client the current thread is serving.
const DispatchContext = struct {
    http: ?*HttpSession = null,
    post: ?*PostStream = null,
};

threadlocal var dispatch_ctx: DispatchContext = .{};

/// A counted reference to the Streamable HTTP client a handler is serving,
/// from `Server.retainCurrentSession`. Pass it to `Server.enterSession` to
/// send to that client later, from any thread. Release it when done, and
/// before `Server.deinit`.
pub const SessionRef = struct {
    session: *HttpSession,

    /// The client's `MCP-Session-Id`.
    pub fn id(self: SessionRef) []const u8 {
        return self.session.id;
    }

    pub fn release(self: SessionRef) void {
        self.session.server.releaseHttpSession(self.session);
    }
};

/// Returned by `Server.enterSession`; `exit` restores the previous context.
pub const SessionScope = struct {
    previous: DispatchContext,

    pub fn exit(self: SessionScope) void {
        dispatch_ctx = self.previous;
    }
};

fn writeSseHead(stream: std.Io.net.Stream, session_id: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n");
    try w.print("Mcp-Session-Id: {s}\r\nMCP-Protocol-Version: {s}\r\n\r\n", .{ session_id, ProtocolVersion });
    try streamWriteAll(stream, w.buffered());
}

fn writeSseEvent(stream: std.Io.net.Stream, id: u64, data: []const u8) !void {
    var head: [48]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&head, "id: {d}\ndata: ", .{id});
    var w_buf: [4096]u8 = undefined;
    var sw = stream.writer(io(), &w_buf);
    sw.interface.writeAll(prefix) catch return error.BrokenPipe;
    sw.interface.writeAll(data) catch return error.BrokenPipe;
    sw.interface.writeAll("\n\n") catch return error.BrokenPipe;
    sw.interface.flush() catch return error.BrokenPipe;
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(io(), .awake).toMilliseconds();
}

// ============================================================================
// Server Implementation
// ============================================================================

pub const Server = struct {
    allocator: Allocator,
    options: ServerOptions,
    handler: Handler,
    state: State = .created,
    initialized: bool = false,
    session: ?Session = null,
    cached_init_response: ?[]const u8 = null,
    client_capabilities: ClientCapabilities = .{},
    /// Server-owned copy of the client's requested protocol version.
    client_protocol_version: ?[]const u8 = null,

    // Transport state
    http_listener: ?std.Io.net.Server = null,
    http_thread: ?std.Thread = null,

    // Streamable HTTP sessions (GAP-011/012, SONNY-6644), keyed by session
    // id (owned by the session). Guards each session's refs/closed too.
    http_sessions: std.StringHashMapUnmanaged(*HttpSession) = .{},
    sessions_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Open HTTP connections: each runs on its own thread; stop() shuts the
    // streams down to wake those threads and waits for them.
    http_conns: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    http_conns_mutex: std.Io.Mutex = std.Io.Mutex.init,
    http_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Cancellation and timeout tracking (GAP-024, GAP-005) for stdio and
    // direct processMessage; each HTTP session has its own.
    requests: RequestRegistry = .{},

    // Serializes building the cached initialize response.
    init_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Rate limiting (GAP-029)
    rate_limit_tokens: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rate_limit_last_refill: i64 = 0,
    rate_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Tasks (GAP-035-040)
    tasks: std.StringHashMapUnmanaged(Task) = .{},
    tasks_mutex: std.Io.Mutex = std.Io.Mutex.init,
    task_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    // OAuth 2.1 (GAP-053-055)
    oauth_clients: std.StringHashMapUnmanaged(OAuthClient) = .{},
    oauth_tokens: std.StringHashMapUnmanaged(OAuthToken) = .{},
    oauth_mutex: std.Io.Mutex = std.Io.Mutex.init,
    oauth_client_metadata_cache: std.StringHashMapUnmanaged(CachedClientMetadata) = .{},

    // Worker pool
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Shared thread-pool for batch work and future work-submission. When
    /// `own_pool` is true the Server created it in `startWorkers` and must
    /// destroy it in `deinit`; otherwise it was injected externally (tests)
    /// and the Server must NOT free it.
    pool: ?*tp.ThreadPool = null,
    own_pool: bool = false,

    // Stdio (with buffered I/O - Zig 0.15 API)
    stdin_file: ?std.Io.File = null,
    stdout_file: ?std.Io.File = null,

    // Runtime-allocated I/O buffers (freed in deinit)
    stdin_buffer: ?[]u8 = null,
    stdout_buffer: ?[]u8 = null,

    // Buffered reader/writer wrappers (using runtime buffers)
    stdin_reader_wrap: ?std.Io.File.Reader = null,
    stdout_writer_wrap: ?std.Io.File.Writer = null,

    // Legacy direct access (for backward compatibility in tests using unbuffered I/O)
    stdin_reader: ?std.Io.File.Reader = null,
    stdout_writer: ?std.Io.File.Writer = null,

    // Default I/O buffer size (can be configured via options.stdio_buffer_size)
    const DefaultStdioBufferSize: usize = 65536;

    const State = enum {
        created,
        running,
        stopped,
    };

    pub fn init(a: Allocator, opt: ServerOptions, h: Handler) anyerror!Server {
        const server = Server{
            .allocator = a,
            .options = opt,
            .handler = h,
        };

        return server;
    }

    /// Creates the server-owned thread-pool. Intended to be called from the
    /// server's owning thread (serve* entry points and processMessage, which
    /// today run serially per-server). NOT thread-safe against itself: two
    /// concurrent invocations on a null pool could each create a pool and
    /// leak one.
    fn startWorkers(self: *Server) !void {
        if (self.pool != null) return; // Externally injected or already started.
        if (self.options.worker_threads == 0) return;

        const pool = try self.allocator.create(tp.ThreadPool);
        errdefer self.allocator.destroy(pool);

        pool.* = try tp.ThreadPool.init(self.allocator, .{
            .max_threads = self.options.worker_threads,
        });
        self.pool = pool;
        self.own_pool = true;
    }

    /// Test-only entry point for exercising `startWorkers` without spinning up
    /// serveStdio / serveHttp. Idempotent — safe to call more than once; no-op
    /// when a pool is already attached (server-owned or externally injected).
    pub fn ensureWorkers(self: *Server) !void {
        try self.startWorkers();
    }

    pub fn deinit(self: *Server) void {
        self.stop();

        // Shut down and destroy the owned thread pool before tearing down
        // sessions / SSE connections so any in-flight tasks still observing
        // those resources complete (or are cancelled) first.
        if (self.pool) |pool| {
            if (self.own_pool) {
                // Best-effort graceful shutdown; fall through on error.
                pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
                pool.deinit();
                self.allocator.destroy(pool);
            }
            self.pool = null;
        }

        // HTTP sessions (stop() has drained every connection thread).
        {
            var it = self.http_sessions.valueIterator();
            while (it.next()) |hs| self.destroyHttpSession(hs.*);
            self.http_sessions.deinit(self.allocator);
            self.http_conns.deinit(self.allocator);
        }

        // Clean up active requests (GAP-024)
        self.requests.deinit(self.allocator);

        // Tasks (GAP-035-040) were never freed.
        {
            var it = self.tasks.valueIterator();
            while (it.next()) |task| self.freeTask(task);
            self.tasks.deinit(self.allocator);
        }

        if (self.session) |*s| {
            s.deinit();
        }

        // Free I/O buffers (allocated in serveStdio)
        if (self.stdin_buffer) |buf| {
            self.allocator.free(buf);
        }
        if (self.stdout_buffer) |buf| {
            self.allocator.free(buf);
        }

        // Free cached init response
        if (self.cached_init_response) |cached| {
            self.allocator.free(cached);
        }

        if (self.client_protocol_version) |v| {
            self.allocator.free(v);
        }
        if (self.client_capabilities.experimental) |e| {
            self.allocator.free(e);
        }
    }

    pub fn serveStdio(self: *Server) anyerror!void {
        self.state = .running;
        try self.startWorkers();

        // Initialize stdio files using cross-platform Zig API
        self.stdin_file = std.Io.File.stdin();
        self.stdout_file = std.Io.File.stdout();

        // Allocate I/O buffers for improved performance
        const buf_size = self.options.stdio_buffer_size;
        self.stdin_buffer = try self.allocator.alloc(u8, buf_size);
        self.stdout_buffer = try self.allocator.alloc(u8, buf_size);

        // Create buffered reader/writer using Zig 0.16 API
        self.stdin_reader_wrap = self.stdin_file.?.reader(io(), self.stdin_buffer.?);
        self.stdout_writer_wrap = self.stdout_file.?.writer(io(), self.stdout_buffer.?);

        self.session = Session.init(self.allocator, self);

        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(self.allocator);

        while (self.state == .running) {
            line_buf.clearRetainingCapacity();

            // Read line (newline-delimited JSON) byte by byte
            if (self.stdin_reader_wrap) |*reader| {
                var read_buf: [1]u8 = undefined;
                while (true) {
                    const bytes_read = reader.interface.readSliceShort(&read_buf) catch break;
                    if (bytes_read == 0) {
                        if (line_buf.items.len > 0) break; // Process last line
                        self.state = .stopped;
                        break;
                    }
                    if (read_buf[0] == '\n') break;
                    if (line_buf.items.len < self.options.max_message_bytes) {
                        line_buf.append(self.allocator, read_buf[0]) catch break;
                    }
                }
            }

            if (line_buf.items.len == 0) continue;

            // Process the message
            const response = self.processMessage(line_buf.items) catch |err| {
                const err_resp = self.makeErrorResponse(null, JsonRpcError.InternalError, @errorName(err)) catch continue;
                self.sendResponse(err_resp) catch {};
                continue;
            };

            if (response) |resp| {
                self.sendResponse(resp) catch {};
            }
        }
    }

    pub fn serveHttp(self: *Server) anyerror!u16 {
        try self.startWorkers();

        var address = std.Io.net.IpAddress.parseIp4(self.options.http_bind, self.options.http_port) catch
            return error.InvalidAddress;

        self.http_listener = try std.Io.net.IpAddress.listen(&address, io(), .{
            .reuse_address = true,
        });

        const actual_port = self.http_listener.?.socket.address.getPort();

        self.state = .running;
        // daemon: HTTP accept loop — runs for the server's lifetime blocking
        // on listener.accept. Not pool work — a pool worker holding an accept
        // loop starves the pool, and accept cannot be cooperatively yielded.
        self.http_thread = try std.Thread.spawn(.{}, httpServerThread, .{self});

        return actual_port;
    }

    // ========================================================================
    // Public Notification Methods (GAP-016 - GAP-020)
    // ========================================================================

    /// Notify clients that the tool list has changed (GAP-019)
    pub fn notifyToolListChanged(self: *Server) !void {
        try self.sendNotificationToAll("notifications/tools/list_changed");
    }

    /// Notify clients that the resource list has changed (GAP-016)
    pub fn notifyResourceListChanged(self: *Server) !void {
        try self.sendNotificationToAll("notifications/resources/list_changed");
    }

    /// Notify clients that a subscribed resource was updated (GAP-017)
    pub fn notifyResourceUpdated(self: *Server, uri: []const u8) !void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"uri\":");
        try appendJsonString(self.allocator, &buf, uri);
        try buf.append(self.allocator, '}');
        const params = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(params);
        try self.sendNotification("notifications/resources/updated", params);
    }

    /// Notify clients that the prompt list has changed (GAP-018)
    pub fn notifyPromptListChanged(self: *Server) !void {
        try self.sendNotificationToAll("notifications/prompts/list_changed");
    }

    /// Emit a log message to connected clients (GAP-020)
    pub fn emitLog(self: *Server, level: []const u8, logger: []const u8, message: []const u8) !void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"level\":");
        try appendJsonString(self.allocator, &buf, level);
        try buf.appendSlice(self.allocator, ",\"logger\":");
        try appendJsonString(self.allocator, &buf, logger);
        try buf.appendSlice(self.allocator, ",\"data\":{\"message\":");
        try appendJsonString(self.allocator, &buf, message);
        try buf.appendSlice(self.allocator, "}}");
        const params = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(params);
        try self.sendNotification("notifications/message", params);
    }

    /// Request LLM sampling from client (GAP-014, GAP-056)
    /// Only works if client declared sampling capability
    /// Use requestSamplingFull for extended parameters (tools, modelPreferences, etc.)
    pub fn requestSampling(self: *Server, messages_json: []const u8, max_tokens: u32) ![]const u8 {
        return self.requestSamplingFull(.{
            .messages_json = messages_json,
            .max_tokens = max_tokens,
        });
    }

    /// Request LLM sampling with full parameter support (GAP-056)
    /// Supports all 2025-11-25 spec parameters: systemPrompt, temperature, stopSequences,
    /// tools, toolChoice, modelPreferences, includeContext, metadata
    pub fn requestSamplingFull(self: *Server, req: SamplingRequest) ![]const u8 {
        const caps = self.clientState().capabilities;
        if (!caps.sampling) {
            return error.SamplingNotSupported;
        }

        // Validate tools parameter requires client capability
        if (req.tools_json != null and !caps.sampling_tools) {
            return error.SamplingToolsNotSupported;
        }

        // Validate includeContext requires client capability
        if (req.include_context != null and !caps.sampling_context) {
            return error.SamplingContextNotSupported;
        }

        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"messages\":");
        try buf.appendSlice(self.allocator, req.messages_json);
        try buf.appendSlice(self.allocator, ",\"maxTokens\":");
        try buf.print(self.allocator, "{d}", .{req.max_tokens});

        // Optional parameters
        if (req.system_prompt) |sp| {
            try buf.appendSlice(self.allocator, ",\"systemPrompt\":\"");
            try self.writeJsonEscapedString(&buf, sp);
            try buf.append(self.allocator, '"');
        }

        if (req.temperature) |temp| {
            try buf.appendSlice(self.allocator, ",\"temperature\":");
            try buf.print(self.allocator, "{d}", .{temp});
        }

        if (req.stop_sequences) |seqs| {
            try buf.appendSlice(self.allocator, ",\"stopSequences\":[");
            for (seqs, 0..) |seq, i| {
                if (i > 0) try buf.append(self.allocator, ',');
                try buf.append(self.allocator, '"');
                try self.writeJsonEscapedString(&buf, seq);
                try buf.append(self.allocator, '"');
            }
            try buf.append(self.allocator, ']');
        }

        if (req.tools_json) |tools| {
            try buf.appendSlice(self.allocator, ",\"tools\":");
            try buf.appendSlice(self.allocator, tools);
        }

        if (req.tool_choice) |tc| {
            try buf.appendSlice(self.allocator, ",\"toolChoice\":\"");
            try self.writeJsonEscapedString(&buf, tc);
            try buf.append(self.allocator, '"');
        }

        if (req.model_preferences_json) |mp| {
            try buf.appendSlice(self.allocator, ",\"modelPreferences\":");
            try buf.appendSlice(self.allocator, mp);
        }

        if (req.include_context) |ic| {
            try buf.appendSlice(self.allocator, ",\"includeContext\":\"");
            try self.writeJsonEscapedString(&buf, ic);
            try buf.append(self.allocator, '"');
        }

        if (req.metadata_json) |md| {
            try buf.appendSlice(self.allocator, ",\"metadata\":");
            try buf.appendSlice(self.allocator, md);
        }

        try buf.append(self.allocator, '}');
        const params = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(params);

        if (self.currentSession()) |s| {
            return try s.request("sampling/createMessage", params, 60000);
        }
        return error.NoSession;
    }

    /// Appends `str` JSON-escaped, without quotes (see `appendJsonString`).
    fn writeJsonEscapedString(self: *Server, out: *std.ArrayListUnmanaged(u8), str: []const u8) !void {
        try appendJsonStringContents(self.allocator, out, str);
    }

    /// Request filesystem roots from client (GAP-015)
    /// Only works if client declared roots capability
    pub fn requestRoots(self: *Server) ![]const u8 {
        if (!self.clientState().capabilities.roots) {
            return error.RootsNotSupported;
        }

        if (self.currentSession()) |s| {
            return try s.request("roots/list", null, 30000);
        }
        return error.NoSession;
    }

    /// Elicitation mode for requesting user input (GAP-041)
    pub const ElicitationMode = enum {
        form,
        url,
    };

    /// Request user input from client via elicitation (GAP-041)
    /// Only works if client declared elicitation capability
    /// mode: .form for structured data collection, .url for OAuth/payments
    /// message: explanation of why input is needed
    /// schema_or_url: JSON Schema for form mode, URL for url mode
    pub fn requestElicitation(
        self: *Server,
        mode: ElicitationMode,
        message: []const u8,
        schema_or_url: []const u8,
    ) ![]const u8 {
        if (!self.clientState().capabilities.elicitation) {
            return error.ElicitationNotSupported;
        }

        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"mode\":\"");
        try buf.appendSlice(self.allocator, @tagName(mode));
        try buf.appendSlice(self.allocator, "\",\"message\":\"");
        try self.writeJsonEscapedString(&buf, message);
        try buf.appendSlice(self.allocator, "\"");

        switch (mode) {
            .form => {
                try buf.appendSlice(self.allocator, ",\"requestedSchema\":");
                try buf.appendSlice(self.allocator, schema_or_url);
            },
            .url => {
                try buf.appendSlice(self.allocator, ",\"url\":");
                try appendJsonString(self.allocator, &buf, schema_or_url);
            },
        }
        try buf.append(self.allocator, '}');

        const params = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(params);

        if (self.currentSession()) |s| {
            return try s.request("elicitation/create", params, 300000); // 5 min timeout for user input
        }
        return error.NoSession;
    }

    /// Send progress notification (GAP-023)
    pub fn notifyProgress(self: *Server, progress_token: []const u8, progress: u32, total: ?u32) !void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"progressToken\":");
        try appendJsonString(self.allocator, &buf, progress_token);
        try buf.appendSlice(self.allocator, ",\"progress\":");
        try buf.print(self.allocator, "{d}", .{progress});
        if (total) |t| {
            try buf.appendSlice(self.allocator, ",\"total\":");
            try buf.print(self.allocator, "{d}", .{t});
        }
        try buf.append(self.allocator, '}');
        const params = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(params);
        try self.sendNotification("notifications/progress", params);
    }

    fn sendNotification(self: *Server, method: []const u8, params: ?[]const u8) !void {
        const notification = try buildMessageJson(self.allocator, null, method, params);
        defer self.allocator.free(notification);
        try self.sendToClient(notification);
    }

    pub fn stop(self: *Server) void {
        self.shutdown.store(true, .release);
        self.state = .stopped;

        // Wake up accept() by making a dummy connection
        if (self.http_listener) |listener| {
            const port = listener.socket.address.getPort();
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            if (std.Io.net.IpAddress.connect(&addr, io(), .{ .mode = .stream })) |conn| {
                streamClose(conn);
            } else |_| {}
        }

        // Join HTTP thread first (it will exit since state != .running)
        if (self.http_thread) |t| {
            t.join();
            self.http_thread = null;
        }

        // Now safe to close listener
        if (self.http_listener) |*listener| {
            listener.deinit(io());
            self.http_listener = null;
        }

        // SONNY-6644: wake every connection thread (blocked reading a request,
        // holding a GET stream open, or waiting for a client's response) and
        // wait until all of them are gone.
        while (self.http_connections.load(.acquire) > 0) {
            self.shutdownHttpConnections();
            self.failAllSessionRequests(error.ServerStopped);
            io().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }

        // The shared thread-pool is shut down in deinit — stop() only tears
        // down listeners/accept loops.
    }

    // ========================================================================
    // Internal Methods
    // ========================================================================

    fn httpServerThread(self: *Server) void {
        while (self.state == .running) {
            var listener = self.http_listener orelse break;
            const conn = listener.accept(io()) catch |err| {
                if (err == error.ConnectionAborted) continue;
                break;
            };
            if (self.state != .running) {
                streamClose(conn);
                break;
            }
            self.expireIdleSessions();

            // SONNY-6644: serve each connection on its own thread, so a
            // request waiting for its client (or an open SSE stream) never
            // blocks other clients.
            const active = self.http_connections.fetchAdd(1, .acq_rel);
            if (active >= self.options.http_max_connections) {
                _ = self.http_connections.fetchSub(1, .acq_rel);
                self.sendHttpResponse(conn, 503, "Service Unavailable", null) catch {};
                streamClose(conn);
                continue;
            }
            const t = std.Thread.spawn(.{}, httpConnectionThread, .{ self, conn }) catch {
                _ = self.http_connections.fetchSub(1, .acq_rel);
                self.sendHttpResponse(conn, 503, "Service Unavailable", null) catch {};
                streamClose(conn);
                continue;
            };
            t.detach();
        }
    }

    fn httpConnectionThread(self: *Server, stream: std.Io.net.Stream) void {
        defer _ = self.http_connections.fetchSub(1, .acq_rel);
        self.trackHttpConnection(stream);
        self.handleHttpConnection(stream) catch {};
        // Untrack before closing: stop() must never shut down a closed (and
        // possibly reused) descriptor.
        self.untrackHttpConnection(stream);
        streamClose(stream);
    }

    fn trackHttpConnection(self: *Server, stream: std.Io.net.Stream) void {
        self.http_conns_mutex.lockUncancelable(io());
        defer self.http_conns_mutex.unlock(io());
        self.http_conns.append(self.allocator, stream) catch {};
    }

    fn untrackHttpConnection(self: *Server, stream: std.Io.net.Stream) void {
        self.http_conns_mutex.lockUncancelable(io());
        defer self.http_conns_mutex.unlock(io());
        for (self.http_conns.items, 0..) |s, i| {
            if (s.socket.handle == stream.socket.handle) {
                _ = self.http_conns.swapRemove(i);
                return;
            }
        }
    }

    fn shutdownHttpConnections(self: *Server) void {
        self.http_conns_mutex.lockUncancelable(io());
        defer self.http_conns_mutex.unlock(io());
        for (self.http_conns.items) |s| s.shutdown(io(), .both) catch {};
    }

    fn failAllSessionRequests(self: *Server, err: anyerror) void {
        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        var it = self.http_sessions.valueIterator();
        while (it.next()) |hs| hs.*.session.failPending(err);
    }

    const max_http_header_bytes: usize = 16 * 1024;

    /// Reads into `tmp` once the request deadline allows; 0 at end of stream.
    fn readRequestChunk(self: *Server, stream: std.Io.net.Stream, tmp: []u8, deadline_ms: ?i64) !usize {
        if (deadline_ms) |dl| {
            const left = dl - nowMs();
            if (left <= 0) return error.RequestTimeout;
            var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32)))) catch return 0;
            if (ready == 0) return error.RequestTimeout;
        }
        _ = self;
        return streamRead(stream, tmp) catch 0;
    }

    /// Reads one HTTP request (head and Content-Length body) within
    /// `http_request_timeout_ms`. Returns null when the peer closed first.
    fn readHttpRequest(self: *Server, stream: std.Io.net.Stream, out: *std.ArrayListUnmanaged(u8)) !?usize {
        var tmp: [8192]u8 = undefined;
        const deadline: ?i64 = if (self.options.http_request_timeout_ms == 0) null else nowMs() + self.options.http_request_timeout_ms;
        const header_end = while (true) {
            if (std.mem.indexOf(u8, out.items, "\r\n\r\n")) |he| break he;
            if (out.items.len > max_http_header_bytes) return error.HeadersTooLarge;
            const n = try self.readRequestChunk(stream, &tmp, deadline);
            if (n == 0) return null;
            try out.appendSlice(self.allocator, tmp[0..n]);
        };
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, out.items[0..header_end], "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const val = std.mem.trim(u8, line["content-length:".len..], " ");
                content_length = std.fmt.parseInt(usize, val, 10) catch return error.BadContentLength;
            }
        }
        if (content_length > self.options.max_message_bytes) return error.BodyTooLarge;
        const total = header_end + 4 + content_length;
        while (out.items.len < total) {
            const n = try self.readRequestChunk(stream, &tmp, deadline);
            if (n == 0) return null;
            try out.appendSlice(self.allocator, tmp[0..n]);
        }
        return total;
    }

    fn handleHttpConnection(self: *Server, stream: std.Io.net.Stream) !void {
        var raw = std.ArrayListUnmanaged(u8).empty;
        defer raw.deinit(self.allocator);
        const total = (self.readHttpRequest(stream, &raw) catch |err| {
            switch (err) {
                error.HeadersTooLarge => try self.sendHttpResponse(stream, 431, "Request Header Fields Too Large", null),
                error.BodyTooLarge => try self.sendHttpResponse(stream, 413, "Payload Too Large", null),
                error.RequestTimeout => try self.sendHttpResponse(stream, 408, "Request Timeout", null),
                else => try self.sendHttpResponse(stream, 400, "Bad Request", null),
            }
            return;
        }) orelse return;

        const request_bytes = raw.items[0..total];

        // Parse HTTP request
        var lines = std.mem.splitSequence(u8, request_bytes, "\r\n");
        const request_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method_str = parts.next() orelse return;
        const path = parts.next() orelse return;

        // Parse headers
        var auth_header: ?[]const u8 = null;
        var session_id: ?[]const u8 = null;
        var origin_header: ?[]const u8 = null;
        var accept_header: ?[]const u8 = null;
        var protocol_version: ?[]const u8 = null; // GAP-034
        var last_event_id: ?u64 = null; // GAP-059: SSE resumption

        while (lines.next()) |line| {
            if (line.len == 0) break;

            if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                auth_header = std.mem.trim(u8, line["authorization:".len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, "mcp-session-id:")) {
                session_id = std.mem.trim(u8, line["mcp-session-id:".len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, "origin:")) {
                origin_header = std.mem.trim(u8, line["origin:".len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, "accept:")) {
                accept_header = std.mem.trim(u8, line["accept:".len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, "mcp-protocol-version:")) {
                protocol_version = std.mem.trim(u8, line["mcp-protocol-version:".len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, "last-event-id:")) {
                // GAP-059: Parse Last-Event-ID for SSE resumption
                const val = std.mem.trim(u8, line["last-event-id:".len..], " ");
                last_event_id = std.fmt.parseInt(u64, val, 10) catch null;
            }
        }

        // GAP-034: Validate MCP-Protocol-Version header
        // If no header provided, assume 2025-03-26 per spec
        // If invalid version provided, return 400 Bad Request
        if (protocol_version) |ver| {
            // Accept current version or previous versions for backward compatibility
            const valid = std.mem.eql(u8, ver, "2025-11-25") or
                std.mem.eql(u8, ver, "2025-06-18") or
                std.mem.eql(u8, ver, "2025-03-26") or
                std.mem.eql(u8, ver, "2024-11-05");
            if (!valid) {
                try self.sendHttpResponse(stream, 400, "Bad Request", null);
                return;
            }
        }

        // Validate Origin header to prevent DNS rebinding attacks (GAP-006)
        if (!self.checkOrigin(origin_header)) {
            try self.sendHttpResponse(stream, 403, "Forbidden", null);
            return;
        }

        // Handle OAuth2 well-known endpoint (no auth required)
        if (std.mem.eql(u8, path, "/.well-known/oauth-authorization-server")) {
            const oauth_meta = try self.getOAuthMetadata();
            defer self.allocator.free(oauth_meta);
            try self.sendHttpResponse(stream, 200, "OK", oauth_meta);
            return;
        }

        const header_end = std.mem.indexOf(u8, request_bytes, "\r\n\r\n").?;
        const body = request_bytes[header_end + 4 ..];

        // GAP-055: Handle OAuth2 Dynamic Client Registration (no auth required)
        const register_path = std.fmt.allocPrint(self.allocator, "{s}/register", .{self.options.http_path}) catch return;
        defer self.allocator.free(register_path);
        if (std.mem.eql(u8, path, register_path) and std.mem.eql(u8, method_str, "POST")) {
            if (!self.options.oauth_dynamic_registration) {
                try self.sendHttpResponse(stream, 404, "Not Found", null);
                return;
            }
            const response = self.registerOAuthClient(body) catch {
                try self.sendHttpResponse(stream, 400, "Bad Request", null);
                return;
            };
            defer self.allocator.free(response);
            try self.sendHttpResponse(stream, 201, "Created", response);
            return;
        }

        // Check authentication
        if (!self.checkAuth(auth_header)) {
            try self.sendHttpResponse(stream, 401, "Unauthorized", null);
            return;
        }

        // GAP-029: Check rate limit
        if (!self.checkRateLimit()) {
            try self.sendHttpResponse(stream, 429, "Too Many Requests", null);
            return;
        }

        if (!std.mem.startsWith(u8, path, self.options.http_path)) {
            try self.sendHttpResponse(stream, 404, "Not Found", null);
            return;
        }

        // SONNY-6644 / GAP-012: the session named by Mcp-Session-Id. An
        // unknown, ended or expired session gets 404.
        var hs: ?*HttpSession = null;
        if (session_id) |sid| {
            hs = self.retainHttpSession(sid) orelse {
                try self.sendHttpResponse(stream, 404, "Not Found", null);
                return;
            };
        }
        defer if (hs) |h| self.releaseHttpSession(h);

        if (std.mem.eql(u8, method_str, "POST")) {
            if (hs == null) {
                // Only initialize may come without a session; it creates
                // one. Anything else gets 400 (Streamable HTTP, "Session
                // Management").
                if (!isInitializeMessage(self.allocator, body)) {
                    try self.sendHttpResponse(stream, 400, "Bad Request", null);
                    return;
                }
                hs = try self.createHttpSession();
            }
            const accepts_sse = if (accept_header) |acc| std.mem.indexOf(u8, acc, "text/event-stream") != null else false;
            try self.servePost(stream, hs.?, body, accepts_sse);
        } else if (std.mem.eql(u8, method_str, "GET")) {
            const h = hs orelse {
                try self.sendHttpResponse(stream, 400, "Bad Request", null);
                return;
            };
            try self.serveGetStream(stream, h, last_event_id);
        } else if (std.mem.eql(u8, method_str, "DELETE")) {
            // GAP-008: Handle session deletion
            const h = hs orelse {
                try self.sendHttpResponse(stream, 400, "Bad Request", null);
                return;
            };
            self.closeHttpSession(h);
            try self.sendHttpResponse(stream, 200, "OK", null);
        } else {
            try self.sendHttpResponse(stream, 405, "Method Not Allowed", null);
        }
    }

    /// True when `body` is a single JSON-RPC `initialize` request.
    fn isInitializeMessage(allocator: Allocator, body: []const u8) bool {
        var err_info = json.ParseError.init();
        var doc = json.parse(allocator, body, .{}, &err_info) catch return false;
        defer doc.deinit();
        if (doc.root != .obj) return false;
        for (doc.root.obj) |m| {
            if (std.mem.eql(u8, m.k, "method")) return m.v == .str and std.mem.eql(u8, m.v.str, "initialize");
        }
        return false;
    }

    /// Dispatches one POSTed message for `hs`. Messages the server sends to
    /// the client while serving it (server-to-client requests, progress,
    /// logs) travel on this POST's own SSE stream, opened on first use, and
    /// the response follows as the stream's last event. Without such
    /// messages the response is plain JSON (202 for notifications and
    /// responses).
    fn servePost(self: *Server, stream: std.Io.net.Stream, hs: *HttpSession, body: []const u8, accepts_sse: bool) !void {
        var ps = PostStream{ .stream = stream, .session = hs, .accepts_sse = accepts_sse };
        const previous = dispatch_ctx;
        dispatch_ctx = .{ .http = hs, .post = &ps };
        const response = blk: {
            defer dispatch_ctx = previous;
            break :blk try self.processMessage(body);
        };
        defer if (response) |r| self.allocator.free(r);

        if (ps.started) {
            if (response) |r| try ps.sendEvent(r);
            return; // closing the connection ends the stream
        }
        if (response) |r| {
            try self.sendHttpResponseWithSession(stream, 200, "OK", r, hs.id);
        } else {
            try self.sendHttpResponseWithSession(stream, 202, "Accepted", null, hs.id);
        }
    }

    /// The session's standalone GET stream (Streamable HTTP "Listening for
    /// Messages from the Server"). It replays this session's events after
    /// Last-Event-ID, then stays open until the client goes away, the
    /// session ends, or the server stops. A new GET replaces the old stream,
    /// so each message is sent on one stream only.
    fn serveGetStream(self: *Server, stream: std.Io.net.Stream, hs: *HttpSession, last_event_id: ?u64) !void {
        try writeSseHead(stream, hs.id);

        // Send retry field (GAP-060) to hint reconnection delay to clients
        if (self.options.sse_retry_ms > 0) {
            var retry_buf: [32]u8 = undefined;
            const retry_msg = std.fmt.bufPrint(&retry_buf, "retry: {d}\n\n", .{self.options.sse_retry_ms}) catch "retry: 3000\n\n";
            streamWriteAll(stream, retry_msg) catch {};
        }

        {
            hs.stream_mutex.lockUncancelable(io());
            defer hs.stream_mutex.unlock(io());

            // A DELETE that raced this GET has already shut the session's
            // streams down; do not register a new one it would never close.
            if (self.isSessionClosed(hs)) return;

            // GAP-059: replay this session's missed events.
            if (last_event_id) |after_id| {
                var replay_events: [64]SseEventBuffer.Event = undefined;
                const count = hs.events.getEventsAfter(after_id, &replay_events, 64);
                for (replay_events[0..count]) |event| {
                    writeSseEvent(stream, event.id, event.data) catch break;
                }
            }
            if (hs.get_stream) |old| old.shutdown(io(), .both) catch {};
            hs.get_stream = stream;
        }
        defer {
            hs.stream_mutex.lockUncancelable(io());
            defer hs.stream_mutex.unlock(io());
            if (hs.get_stream) |cur| {
                if (cur.socket.handle == stream.socket.handle) hs.get_stream = null;
            }
        }

        var sink: [256]u8 = undefined;
        while (true) {
            const n = streamRead(stream, &sink) catch break;
            if (n == 0) break;
        }
    }

    // ------------------------------------------------------------------
    // Session table (SONNY-6644)
    // ------------------------------------------------------------------

    fn createHttpSession(self: *Server) !*HttpSession {
        const hs = try self.allocator.create(HttpSession);
        errdefer self.allocator.destroy(hs);

        // Cryptographically secure session ID (GAP-007): 128 random bits as
        // 32 hex digits (visible ASCII only).
        var random_bytes: [16]u8 = undefined;
        io().random(&random_bytes);
        const id = try std.fmt.allocPrint(self.allocator, "{x:0>32}", .{std.mem.readInt(u128, &random_bytes, .big)});
        errdefer self.allocator.free(id);

        hs.* = .{
            .server = self,
            .id = id,
            .refs = 1,
            .last_active_ms = nowMs(),
            .session = Session.init(self.allocator, self),
        };
        hs.session.http = hs;

        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        try self.http_sessions.put(self.allocator, hs.id, hs);
        return hs;
    }

    /// The live session with `id`, with a reference taken, or null.
    fn retainHttpSession(self: *Server, id: []const u8) ?*HttpSession {
        self.expireIdleSessions();
        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        const hs = self.http_sessions.get(id) orelse return null;
        if (hs.closed) return null;
        hs.refs += 1;
        hs.last_active_ms = nowMs();
        return hs;
    }

    fn releaseHttpSession(self: *Server, hs: *HttpSession) void {
        const destroy = blk: {
            self.sessions_mutex.lockUncancelable(io());
            defer self.sessions_mutex.unlock(io());
            hs.refs -= 1;
            hs.last_active_ms = nowMs();
            break :blk hs.refs == 0 and hs.closed;
        };
        if (destroy) self.destroyHttpSession(hs);
    }

    fn isSessionClosed(self: *Server, hs: *HttpSession) bool {
        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        return hs.closed;
    }

    /// Ends a session (DELETE or expiry): its id stops resolving, its GET
    /// stream is closed and its pending server-to-client requests fail.
    fn closeHttpSession(self: *Server, hs: *HttpSession) void {
        const destroy = blk: {
            self.sessions_mutex.lockUncancelable(io());
            defer self.sessions_mutex.unlock(io());
            if (!hs.closed) {
                hs.closed = true;
                _ = self.http_sessions.remove(hs.id);
            }
            break :blk hs.refs == 0;
        };
        {
            hs.stream_mutex.lockUncancelable(io());
            defer hs.stream_mutex.unlock(io());
            if (hs.get_stream) |s| s.shutdown(io(), .both) catch {};
        }
        hs.session.failPending(error.NoSession);
        if (destroy) self.destroyHttpSession(hs);
    }

    /// Drops sessions idle for longer than `http_session_idle_timeout_ms`
    /// with no connection or `SessionRef` holding them.
    fn expireIdleSessions(self: *Server) void {
        const timeout = self.options.http_session_idle_timeout_ms;
        if (timeout == 0) return;
        const now = nowMs();
        var expired: [16]*HttpSession = undefined;
        var n: usize = 0;
        {
            self.sessions_mutex.lockUncancelable(io());
            defer self.sessions_mutex.unlock(io());
            var it = self.http_sessions.valueIterator();
            while (it.next()) |hs| {
                if (n == expired.len) break;
                if (hs.*.refs == 0 and now - hs.*.last_active_ms > timeout) {
                    expired[n] = hs.*;
                    n += 1;
                }
            }
            for (expired[0..n]) |hs| {
                hs.closed = true;
                _ = self.http_sessions.remove(hs.id);
            }
        }
        for (expired[0..n]) |hs| self.destroyHttpSession(hs);
    }

    fn destroyHttpSession(self: *Server, hs: *HttpSession) void {
        hs.session.deinit();
        hs.requests.deinit(self.allocator);
        hs.client.deinit(self.allocator);
        hs.events.deinit();
        self.allocator.free(hs.id);
        self.allocator.destroy(hs);
    }

    /// The Streamable HTTP client the current handler call is serving, with
    /// a reference taken so it can be reached later (from any thread) via
    /// `enterSession`. Null outside an HTTP request (stdio has one client).
    pub fn retainCurrentSession(self: *Server) ?SessionRef {
        const hs = dispatch_ctx.http orelse return null;
        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        if (hs.closed) return null;
        hs.refs += 1;
        return .{ .session = hs };
    }

    /// Makes the calling thread act for `ref`'s client until `exit`:
    /// notifications and server-to-client requests go to that client's
    /// GET stream only, and fail with `error.NoSession` once the session
    /// has ended.
    pub fn enterSession(self: *Server, ref: SessionRef) SessionScope {
        _ = self;
        const scope = SessionScope{ .previous = dispatch_ctx };
        dispatch_ctx = .{ .http = ref.session, .post = null };
        return scope;
    }

    fn checkOrigin(self: *Server, origin: ?[]const u8) bool {
        // If no allowed origins configured, only allow localhost
        if (self.options.http_allowed_origins == null) {
            // No Origin header is OK (same-origin requests don't send Origin)
            if (origin == null) return true;

            // Allow localhost origins
            const o = origin.?;
            if (std.mem.startsWith(u8, o, "http://localhost") or
                std.mem.startsWith(u8, o, "http://127.0.0.1") or
                std.mem.startsWith(u8, o, "https://localhost") or
                std.mem.startsWith(u8, o, "https://127.0.0.1"))
            {
                return true;
            }
            return false;
        }

        // Check against configured allowed origins
        const allowed = self.options.http_allowed_origins.?;
        if (origin == null) return true; // No Origin header, allow

        for (allowed) |allowed_origin| {
            if (std.mem.eql(u8, origin.?, allowed_origin)) {
                return true;
            }
            // Support wildcard "*"
            if (std.mem.eql(u8, allowed_origin, "*")) {
                return true;
            }
        }
        return false;
    }

    fn checkAuth(self: *Server, auth_header: ?[]const u8) bool {
        switch (self.options.auth_mode) {
            .none => return true,
            .bearer => {
                if (self.options.bearer_token) |expected| {
                    if (auth_header) |header| {
                        if (std.mem.startsWith(u8, header, "Bearer ")) {
                            const token = header["Bearer ".len..];
                            return std.mem.eql(u8, token, expected);
                        }
                    }
                }
                return false;
            },
            .basic => {
                if (self.options.basic_user) |user| {
                    if (self.options.basic_pass) |pass| {
                        if (auth_header) |header| {
                            if (std.mem.startsWith(u8, header, "Basic ")) {
                                const encoded = header["Basic ".len..];
                                var decoded_buf: [256]u8 = undefined;
                                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
                                if (decoded_len > decoded_buf.len) return false;
                                std.base64.standard.Decoder.decode(&decoded_buf, encoded) catch return false;
                                const decoded_str = decoded_buf[0..decoded_len];
                                if (std.mem.indexOf(u8, decoded_str, ":")) |colon| {
                                    const auth_user = decoded_str[0..colon];
                                    const auth_pass = decoded_str[colon + 1 ..];
                                    return std.mem.eql(u8, auth_user, user) and std.mem.eql(u8, auth_pass, pass);
                                }
                            }
                        }
                    }
                }
                return false;
            },
            .oauth2 => {
                // OAuth2 - check for valid bearer token (issued by our token endpoint)
                if (auth_header) |header| {
                    if (std.mem.startsWith(u8, header, "Bearer ")) {
                        const token = header["Bearer ".len..];
                        // GAP-054: Validate token including resource indicator
                        return self.validateTokenResource(token) catch false;
                    }
                }
                return false;
            },
        }
    }

    fn getOAuthMetadata(self: *Server) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        const base = self.options.http_path;
        const port = self.http_listener.?.socket.address.getPort();

        try buf.appendSlice(self.allocator, "{");
        try buf.print(self.allocator, "\"issuer\":\"http://{s}:{d}\"", .{ self.options.http_bind, port });
        try buf.print(self.allocator, ",\"authorization_endpoint\":\"http://{s}:{d}{s}/authorize\"", .{ self.options.http_bind, port, base });
        try buf.print(self.allocator, ",\"token_endpoint\":\"http://{s}:{d}{s}/token\"", .{ self.options.http_bind, port, base });

        // GAP-055: Include registration endpoint if DCR enabled
        if (self.options.oauth_dynamic_registration) {
            try buf.print(self.allocator, ",\"registration_endpoint\":\"http://{s}:{d}{s}/register\"", .{ self.options.http_bind, port, base });
        }

        // Standard OAuth 2.1 metadata
        try buf.appendSlice(self.allocator, ",\"response_types_supported\":[\"code\"]");
        try buf.appendSlice(self.allocator, ",\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"]");
        try buf.appendSlice(self.allocator, ",\"code_challenge_methods_supported\":[\"S256\"]"); // PKCE required
        try buf.appendSlice(self.allocator, ",\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\",\"client_secret_post\",\"none\"]");

        // GAP-053: Client ID Metadata Documents support
        try buf.appendSlice(self.allocator, ",\"client_id_metadata_document_supported\":true");

        try buf.appendSlice(self.allocator, "}");

        return buf.toOwnedSlice(self.allocator);
    }

    // ========================================================================
    // OAuth 2.1 Methods (GAP-053-055)
    // ========================================================================

    /// GAP-053: Validate client ID as metadata document URL
    /// If client_id starts with https://, fetch and cache metadata
    pub fn validateClientMetadata(self: *Server, client_id: []const u8) !bool {
        // Check if client_id is a URL (GAP-053)
        if (!std.mem.startsWith(u8, client_id, "https://")) {
            // Not a metadata document URL, check if pre-registered
            self.oauth_mutex.lockUncancelable(io());
            defer self.oauth_mutex.unlock(io());
            return self.oauth_clients.contains(client_id);
        }

        // Check cache first
        self.oauth_mutex.lockUncancelable(io());
        if (self.oauth_client_metadata_cache.get(client_id)) |cached| {
            const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();
            const cache_ttl: i64 = @intCast(self.options.oauth_client_metadata_cache_ms);
            if (now - cached.fetched_at < cache_ttl) {
                self.oauth_mutex.unlock(io());
                return true; // Valid cached metadata
            }
        }
        self.oauth_mutex.unlock(io());

        // In a real implementation, fetch metadata from URL via HTTPS
        // For now, we validate the URL format and accept it
        // Note: Production should use std.http.Client to fetch metadata

        const metadata = CachedClientMetadata{
            .fetched_at = std.Io.Timestamp.now(io(), .real).toMilliseconds(),
        };

        self.oauth_mutex.lockUncancelable(io());
        defer self.oauth_mutex.unlock(io());
        try self.oauth_client_metadata_cache.put(self.allocator, client_id, metadata);
        return true;
    }

    /// GAP-054: Validate token has correct resource indicator (RFC 8707)
    pub fn validateTokenResource(self: *Server, token: []const u8) !bool {
        self.oauth_mutex.lockUncancelable(io());
        defer self.oauth_mutex.unlock(io());

        if (self.oauth_tokens.get(token)) |token_info| {
            // Check expiration
            const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();
            if (now > token_info.expires_at) {
                return false; // Token expired
            }

            // GAP-054: Validate resource indicator if configured
            if (self.options.oauth_resource_uri) |expected_resource| {
                if (token_info.resource) |token_resource| {
                    return std.mem.eql(u8, token_resource, expected_resource);
                }
                return false; // Token missing required resource
            }
            return true; // No resource validation required
        }
        return false; // Token not found
    }

    /// GAP-055: Register a new OAuth client dynamically
    pub fn registerOAuthClient(self: *Server, request_json: []const u8) ![]const u8 {
        if (!self.options.oauth_dynamic_registration) {
            return error.DynamicRegistrationDisabled;
        }

        // Parse registration request
        var err_info = json.ParseError.init();
        var doc = json.parse(self.allocator, request_json, .{}, &err_info) catch {
            return error.InvalidRequest;
        };
        defer doc.deinit();

        // Extract fields
        var client_name: ?[]const u8 = null;
        var redirect_uris: ?[]const u8 = null;

        if (doc.root == .obj) {
            for (doc.root.obj) |member| {
                if (std.mem.eql(u8, member.k, "client_name")) {
                    if (member.v == .str) client_name = member.v.str;
                } else if (std.mem.eql(u8, member.k, "redirect_uris")) {
                    redirect_uris = json.stringify(self.allocator, member.v) catch null;
                }
            }
        }

        // Generate client credentials
        var client_id_bytes: [16]u8 = undefined;
        var client_secret_bytes: [32]u8 = undefined;
        io().random(&client_id_bytes);
        io().random(&client_secret_bytes);

        var client_id_hex: [32]u8 = undefined;
        var client_secret_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&client_id_hex, "{x:0>32}", .{std.mem.readInt(u128, &client_id_bytes, .big)}) catch unreachable;
        _ = std.fmt.bufPrint(&client_secret_hex, "{x:0>64}", .{std.mem.readInt(u256, &client_secret_bytes, .big)}) catch unreachable;

        const client_id = try self.allocator.dupe(u8, &client_id_hex);
        const client_secret = try self.allocator.dupe(u8, &client_secret_hex);

        // Store client
        const client = OAuthClient{
            .client_id = client_id,
            .client_secret = client_secret,
            .client_name = if (client_name) |n| try self.allocator.dupe(u8, n) else null,
            .registered_at = std.Io.Timestamp.now(io(), .real).toMilliseconds(),
        };

        self.oauth_mutex.lockUncancelable(io());
        defer self.oauth_mutex.unlock(io());
        try self.oauth_clients.put(self.allocator, client_id, client);

        // Build response
        var buf = std.ArrayListUnmanaged(u8).empty;
        try buf.appendSlice(self.allocator, "{\"client_id\":\"");
        try buf.appendSlice(self.allocator, client_id);
        try buf.appendSlice(self.allocator, "\",\"client_secret\":\"");
        try buf.appendSlice(self.allocator, client_secret);
        try buf.appendSlice(self.allocator, "\",\"client_id_issued_at\":");
        try buf.print(self.allocator, "{d}", .{@divTrunc(client.registered_at, 1000)});
        try buf.appendSlice(self.allocator, ",\"client_secret_expires_at\":0"); // Never expires
        if (client_name) |n| {
            try buf.appendSlice(self.allocator, ",\"client_name\":\"");
            try buf.appendSlice(self.allocator, n);
            try buf.appendSlice(self.allocator, "\"");
        }
        try buf.appendSlice(self.allocator, "}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Issue an OAuth token with resource indicator (GAP-054)
    pub fn issueOAuthToken(self: *Server, client_id: []const u8, resource: ?[]const u8, scope: ?[]const u8) ![]const u8 {
        // Validate client
        if (!try self.validateClientMetadata(client_id)) {
            return error.InvalidClient;
        }

        // Generate token
        var token_bytes: [32]u8 = undefined;
        io().random(&token_bytes);
        var token_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token_hex, "{x:0>64}", .{std.mem.readInt(u256, &token_bytes, .big)}) catch unreachable;

        const access_token = try self.allocator.dupe(u8, &token_hex);
        const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();

        const token_info = OAuthToken{
            .access_token = access_token,
            .expires_at = now + 3600000, // 1 hour
            .resource = if (resource) |r| try self.allocator.dupe(u8, r) else null,
            .client_id = try self.allocator.dupe(u8, client_id),
            .scope = if (scope) |s| try self.allocator.dupe(u8, s) else null,
        };

        self.oauth_mutex.lockUncancelable(io());
        defer self.oauth_mutex.unlock(io());
        try self.oauth_tokens.put(self.allocator, access_token, token_info);

        // Build response
        var buf = std.ArrayListUnmanaged(u8).empty;
        try buf.appendSlice(self.allocator, "{\"access_token\":\"");
        try buf.appendSlice(self.allocator, access_token);
        try buf.appendSlice(self.allocator, "\",\"token_type\":\"Bearer\",\"expires_in\":3600");
        if (scope) |s| {
            try buf.appendSlice(self.allocator, ",\"scope\":\"");
            try buf.appendSlice(self.allocator, s);
            try buf.appendSlice(self.allocator, "\"");
        }
        try buf.appendSlice(self.allocator, "}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Check rate limit, returns true if request is allowed (GAP-029)
    fn checkRateLimit(self: *Server) bool {
        if (self.options.rate_limit_requests_per_second == 0) return true; // Unlimited

        // Connections are served concurrently (SONNY-6644).
        self.rate_mutex.lockUncancelable(io());
        defer self.rate_mutex.unlock(io());

        const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();
        const elapsed_ms = now - self.rate_limit_last_refill;

        // Refill tokens based on elapsed time
        if (elapsed_ms >= 1000) {
            self.rate_limit_tokens.store(self.options.rate_limit_burst, .release);
            self.rate_limit_last_refill = now;
        } else if (elapsed_ms > 0) {
            const tokens_to_add = @as(u32, @intCast(@divTrunc(elapsed_ms * self.options.rate_limit_requests_per_second, 1000)));
            if (tokens_to_add > 0) {
                const current = self.rate_limit_tokens.load(.acquire);
                const new_tokens = @min(current + tokens_to_add, self.options.rate_limit_burst);
                self.rate_limit_tokens.store(new_tokens, .release);
                self.rate_limit_last_refill = now;
            }
        }

        // Try to consume a token
        var current = self.rate_limit_tokens.load(.acquire);
        while (current > 0) {
            if (self.rate_limit_tokens.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |new_val| {
                current = new_val;
            } else {
                return true; // Token consumed
            }
        }
        return false; // Rate limited
    }

    /// Validate URI format (GAP-030)
    fn validateUri(uri: []const u8) bool {
        if (uri.len == 0) return false;
        if (uri.len > 8192) return false; // Max URI length

        // Basic URI validation - must have a scheme or be a relative path
        // Valid: "file:///path", "http://...", "/path", "resource://..."
        if (std.mem.indexOf(u8, uri, "://") != null) {
            // Has scheme - valid
            return true;
        }
        if (uri[0] == '/') {
            // Absolute path - valid
            return true;
        }
        // Relative path or other - allow for flexibility
        return true;
    }

    /// The registry of the client being served (SONNY-6644).
    fn currentRegistry(self: *Server) *RequestRegistry {
        if (dispatch_ctx.http) |hs| return &hs.requests;
        return &self.requests;
    }

    /// Cancel a request by ID (GAP-024), in the current client's registry.
    fn cancelRequest(self: *Server, request_id: RequestId) void {
        self.currentRegistry().cancel(request_id);
    }

    /// Register a request for cancellation/timeout tracking (GAP-024, GAP-005).
    fn registerRequest(self: *Server, request_id: RequestId, token: *CancelToken) error{ DuplicateRequestId, OutOfMemory }!void {
        return self.currentRegistry().register(self.allocator, request_id, token);
    }

    /// Unregister a request after completion (GAP-024)
    fn unregisterRequest(self: *Server, request_id: RequestId) void {
        self.currentRegistry().unregister(request_id);
    }

    /// Delivers the client's response to the server-to-client request with
    /// `id` (SONNY-6643), in the session of the client that sent it, so one
    /// client cannot answer another's request (SONNY-6644). `result` null
    /// means the client answered with an error. Unknown or already-answered
    /// ids are ignored.
    fn resolveClientResponse(self: *Server, id: i64, result: ?json.Value) void {
        const s = self.currentSession() orelse return;
        s.mutex.lockUncancelable(io());
        defer s.mutex.unlock(io());
        const entry = s.pending_requests.fetchRemove(id) orelse return;
        const ctx = entry.value;
        if (result) |r| {
            ctx.response = json.stringify(s.allocator, r) catch |e| blk: {
                ctx.err = e;
                break :blk null;
            };
        } else {
            ctx.err = error.ClientError;
        }
        ctx.done.set(io());
    }

    /// Check and timeout stale requests (GAP-005), for every client.
    pub fn checkRequestTimeouts(self: *Server) void {
        if (self.options.request_timeout_ms == 0) return; // Timeouts disabled
        const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();
        const timeout_ms: i64 = @intCast(self.options.request_timeout_ms);
        self.requests.expire(now, timeout_ms);

        self.sessions_mutex.lockUncancelable(io());
        defer self.sessions_mutex.unlock(io());
        var it = self.http_sessions.valueIterator();
        while (it.next()) |hs| hs.*.requests.expire(now, timeout_ms);
    }

    fn sendHttpResponse(self: *Server, stream: std.Io.net.Stream, status: u16, status_text: []const u8, body: ?[]const u8) !void {
        _ = self;
        var buf: [4096]u8 = undefined;
        var fbs: std.Io.Writer = .fixed(&buf);

        try fbs.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
        try fbs.writeAll("Content-Type: application/json\r\n");
        // GAP-034: MCP-Protocol-Version header
        try fbs.print("MCP-Protocol-Version: {s}\r\n", .{ProtocolVersion});

        if (body) |b| {
            try fbs.print("Content-Length: {d}\r\n", .{b.len});
            try fbs.writeAll("\r\n");
            try streamWriteAll(stream, fbs.buffered());
            try streamWriteAll(stream, b);
        } else {
            try fbs.writeAll("Content-Length: 0\r\n\r\n");
            try streamWriteAll(stream, fbs.buffered());
        }
    }

    fn sendHttpResponseWithSession(self: *Server, stream: std.Io.net.Stream, status: u16, status_text: []const u8, body: ?[]const u8, session_id: []const u8) !void {
        _ = self;
        var buf: [4096]u8 = undefined;
        var fbs: std.Io.Writer = .fixed(&buf);

        try fbs.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
        try fbs.writeAll("Content-Type: application/json\r\n");
        try fbs.print("Mcp-Session-Id: {s}\r\n", .{session_id});
        // GAP-034: MCP-Protocol-Version header
        try fbs.print("MCP-Protocol-Version: {s}\r\n", .{ProtocolVersion});
        const b = body orelse "";
        try fbs.print("Content-Length: {d}\r\n\r\n", .{b.len});
        try streamWriteAll(stream, fbs.buffered());
        try streamWriteAll(stream, b);
    }

    pub fn processMessage(self: *Server, data: []const u8) !?[]const u8 {
        // Check for batch (array)
        if (data.len > 0 and data[0] == '[') {
            return self.processBatch(data);
        }
        return self.processSingleMessage(data);
    }

    const BatchItemResult = struct {
        response: ?[]const u8,
        index: usize,
    };

    fn processBatch(self: *Server, data: []const u8) !?[]const u8 {
        var err_info = json.ParseError.init();
        var doc = json.parse(self.allocator, data, .{
            .max_bytes = self.options.max_message_bytes,
        }, &err_info) catch {
            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.ParseError, "Parse error"));
        };
        defer doc.deinit();

        if (doc.root != .arr) {
            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.InvalidRequest, "Invalid batch"));
        }

        const items = doc.root.arr;
        if (items.len == 0 or items.len > self.options.max_batch_items) {
            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.InvalidRequest, "Invalid batch size"));
        }

        // GAP-003: Initialize MUST NOT be in a batch
        for (items) |item| {
            if (item == .obj) {
                for (item.obj) |member| {
                    if (std.mem.eql(u8, member.k, "method")) {
                        if (member.v == .str and std.mem.eql(u8, member.v.str, "initialize")) {
                            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.InvalidRequest, "initialize must not be in batch"));
                        }
                    }
                }
            }
        }

        // Allocate results array
        const results = try self.allocator.alloc(BatchItemResult, items.len);
        defer self.allocator.free(results);

        // Initialize results
        for (results) |*r| {
            r.* = .{ .response = null, .index = 0 };
        }
        errdefer for (results) |r| {
            if (r.response) |resp| self.allocator.free(resp);
        };

        // SONNY-6644: reject duplicate request ids deterministically. The
        // first request with an id, in batch order, is dispatched; every
        // later request reusing it is answered with -32600 here and never
        // dispatched, whatever order the pool would run them in.
        const skip = try self.allocator.alloc(bool, items.len);
        defer self.allocator.free(skip);
        @memset(skip, false);
        {
            var seen_int: std.AutoHashMapUnmanaged(i64, void) = .empty;
            defer seen_int.deinit(self.allocator);
            var seen_str: std.StringHashMapUnmanaged(void) = .empty;
            defer seen_str.deinit(self.allocator);
            for (items, 0..) |item, i| {
                const rid = batchRequestId(item) orelse continue;
                const dup = switch (rid) {
                    .int => |v| (try seen_int.getOrPut(self.allocator, v)).found_existing,
                    .str => |v| (try seen_str.getOrPut(self.allocator, v)).found_existing,
                };
                if (dup) {
                    skip[i] = true;
                    results[i] = .{
                        .response = try self.makeErrorResponse(rid, JsonRpcError.InvalidRequest, "Duplicate request id"),
                        .index = i,
                    };
                }
            }
        }

        // Parallelism predicate — sequential when single item or parallelism
        // explicitly disabled. Otherwise lazily start the shared pool so
        // callers driving us directly via `processMessage` (tests, library
        // consumers) get parallel dispatch without having to spin up
        // `serveStdio` / `serveHttp` first. `startWorkers` is idempotent.
        const use_parallel = self.options.worker_threads > 0 and items.len > 1;

        if (use_parallel and self.pool == null) {
            // Best-effort — if pool creation fails we fall through to the
            // sequential path below.
            self.startWorkers() catch |err| {
                std.log.warn("mcp: failed to start thread-pool for batch processing ({s}); falling back to sequential", .{@errorName(err)});
            };
        }

        if (!use_parallel or self.pool == null) {
            // Sequential processing (single item, parallelism disabled, or
            // pool couldn't be created).
            for (items, 0..) |item, i| {
                if (skip[i]) continue;
                const response = try self.processJsonValue(item);
                results[i] = .{ .response = response, .index = i };
            }
        } else {
            const pool = self.pool.?;
            // Pool-managed WaitGroup: the pool calls add(1) on each
            // successful submission and done() on completion/cancellation.
            // Partial submits under backpressure are therefore safe — the
            // caller must NOT add(1) per item or call done() in the task.
            var wg = pool.waitGroup();

            const ItemCtx = struct {
                server: *Server,
                item: json.Value,
                index: usize,
                results: []BatchItemResult,
                /// The client the batch came from (SONNY-6644).
                dispatch: DispatchContext,

                fn run(ctx_: *anyopaque, _: *tp.TaskContext) void {
                    const c: *@This() = @ptrCast(@alignCast(ctx_));
                    const previous = dispatch_ctx;
                    dispatch_ctx = c.dispatch;
                    defer dispatch_ctx = previous;
                    const response = c.server.processJsonValue(c.item) catch null;
                    c.results[c.index] = .{ .response = response, .index = c.index };
                }
            };

            const ctxs = try self.allocator.alloc(ItemCtx, items.len);
            defer self.allocator.free(ctxs);
            const tasks = try self.allocator.alloc(tp.BatchTask, items.len);
            defer self.allocator.free(tasks);

            var n_tasks: usize = 0;
            for (items, 0..) |item, i| {
                if (skip[i]) continue;
                ctxs[n_tasks] = .{ .server = self, .item = item, .index = i, .results = results, .dispatch = dispatch_ctx };
                tasks[n_tasks] = .{ .task_fn = ItemCtx.run, .ctx = &ctxs[n_tasks] };
                n_tasks += 1;
            }

            const result = try pool.submitBatch(tasks[0..n_tasks], .{ .wait_group = &wg });
            wg.wait();

            // Any tasks the pool rejected under backpressure were never added
            // to the wait group and must be processed inline so their results
            // land in `results[]`.
            if (result.submitted < n_tasks) {
                for (ctxs[result.submitted..n_tasks]) |c| {
                    const response = self.processJsonValue(c.item) catch null;
                    results[c.index] = .{ .response = response, .index = c.index };
                }
            }
        }

        // Collect responses in order
        var responses = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (responses.items) |r| self.allocator.free(r);
            responses.deinit(self.allocator);
        }

        var all_notifications = true;

        for (results) |*result| {
            if (result.response) |resp| {
                all_notifications = false;
                try responses.append(self.allocator, resp);
                // Now owned by `responses`; keep the errdefer above from
                // freeing it a second time.
                result.response = null;
            }
        }

        if (all_notifications) {
            return null; // No responses needed for batch of notifications
        }

        // Build batch response
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.append(self.allocator, '[');
        for (responses.items, 0..) |resp, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.appendSlice(self.allocator, resp);
        }
        try buf.append(self.allocator, ']');

        return @as(?[]const u8, try buf.toOwnedSlice(self.allocator));
    }

    /// The id of a batch item that is a request (an object with a string
    /// `method` and a string or integer `id`), or null for notifications,
    /// client responses and malformed items, which carry no request id.
    fn batchRequestId(item: json.Value) ?RequestId {
        if (item != .obj) return null;
        var id: ?RequestId = null;
        var has_method = false;
        for (item.obj) |m| {
            if (std.mem.eql(u8, m.k, "method")) {
                has_method = m.v == .str;
            } else if (std.mem.eql(u8, m.k, "id")) {
                id = switch (m.v) {
                    .num => |n| if (std.fmt.parseInt(i64, n.lexeme, 10)) |v| .{ .int = v } else |_| null,
                    .str => |str| .{ .str = str },
                    else => null,
                };
            }
        }
        return if (has_method) id else null;
    }

    fn processSingleMessage(self: *Server, data: []const u8) !?[]const u8 {
        var err_info = json.ParseError.init();
        var doc = json.parse(self.allocator, data, .{
            .max_bytes = self.options.max_message_bytes,
        }, &err_info) catch {
            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.ParseError, "Parse error"));
        };
        defer doc.deinit();

        return self.processJsonValue(doc.root);
    }

    fn processJsonValue(self: *Server, value: json.Value) !?[]const u8 {
        if (value != .obj) {
            return @as(?[]const u8, try self.makeErrorResponse(null, JsonRpcError.InvalidRequest, "Invalid Request"));
        }

        const obj = value.obj;

        // Extract fields
        var id: ?RequestId = null;
        var id_invalid = false;
        var method: ?[]const u8 = null;
        var params: ?json.Value = null;
        var has_jsonrpc = false;
        var result: ?json.Value = null;
        var has_error = false;

        for (obj) |member| {
            if (std.mem.eql(u8, member.k, "jsonrpc")) {
                if (member.v == .str and std.mem.eql(u8, member.v.str, "2.0")) {
                    has_jsonrpc = true;
                }
            } else if (std.mem.eql(u8, member.k, "id")) {
                // MCP basic "Requests": the id MUST be a string or integer
                // and MUST NOT be null. A present id of any other kind is an
                // Invalid Request, not a notification (SONNY-6585).
                id = switch (member.v) {
                    .num => |n| if (std.fmt.parseInt(i64, n.lexeme, 10)) |v| .{ .int = v } else |_| null,
                    .str => |s| .{ .str = s },
                    else => null,
                };
                id_invalid = id == null;
            } else if (std.mem.eql(u8, member.k, "method")) {
                if (member.v == .str) {
                    method = member.v.str;
                }
            } else if (std.mem.eql(u8, member.k, "params")) {
                params = member.v;
            } else if (std.mem.eql(u8, member.k, "result")) {
                result = member.v;
            } else if (std.mem.eql(u8, member.k, "error")) {
                has_error = true;
            }
        }

        // A message with no method but a result or an error is the client's
        // response to a server-to-client request (MCP basic "Responses").
        // It resolves the pending request, if any, and is never answered.
        if (method == null and (result != null or has_error)) {
            if (has_jsonrpc and !id_invalid and (result != null) != has_error) {
                if (id) |rid| switch (rid) {
                    .int => |i| self.resolveClientResponse(i, result),
                    .str => {}, // the server only issues integer ids
                };
            }
            return null;
        }

        if (!has_jsonrpc or id_invalid) {
            return @as(?[]const u8, try self.makeErrorResponse(id, JsonRpcError.InvalidRequest, "Invalid Request"));
        }

        if (method == null) {
            return @as(?[]const u8, try self.makeErrorResponse(id, JsonRpcError.InvalidRequest, "Missing method"));
        }

        // Observability seam: wrap dispatch in a server-side RPC span.
        // The seam is null-tracer-safe (no panic when otel isn't
        // initialized) and the disabled build collapses to a no-op.
        // The defer is the lifecycle backstop (always ends the span);
        // the success/failure annotations below set status before end.
        var __obs_span = observability.startRpcServerSpan(method.?);
        defer __obs_span.end(null);
        errdefer observability.endRpcServerSpan(__obs_span, false, JsonRpcError.InternalError);

        // GAP-024: track every request while it runs, so tools/call can be
        // cancelled by the client's notifications/cancelled and a second
        // request reusing an in-flight id is rejected instead of replacing
        // the first (SONNY-6643; MCP: a requestor MUST NOT reuse an id).
        var cancel = CancelToken{};
        if (id) |rid| {
            self.registerRequest(rid, &cancel) catch |err| switch (err) {
                error.DuplicateRequestId => {
                    observability.endRpcServerSpan(__obs_span, false, JsonRpcError.InvalidRequest);
                    return @as(?[]const u8, try self.makeErrorResponse(id, JsonRpcError.InvalidRequest, "Duplicate request id"));
                },
                else => |e| return e,
            };
        }
        defer if (id) |rid| self.unregisterRequest(rid);

        // A detail left on this thread outside a dispatch must not be
        // attached to this request's error (SONNY-6585).
        clearErrorDetail();

        // Handle the method
        const method_result = self.handleMethod(method.?, params, &cancel) catch |err| {
            const detail = takeErrorDetail();
            defer if (detail) |d| d.deinit();

            // GAP-031: Use specific error codes based on error type
            const error_code = switch (err) {
                error.ResourceNotFound => JsonRpcError.ResourceNotFound,
                error.ToolNotFound => JsonRpcError.ToolNotFound,
                error.PromptNotFound => JsonRpcError.PromptNotFound,
                error.NotInitialized => JsonRpcError.NotInitialized,
                error.MethodNotFound => JsonRpcError.MethodNotFound,
                error.InvalidParams => JsonRpcError.InvalidParams,
                else => JsonRpcError.InternalError,
            };
            observability.endRpcServerSpan(__obs_span, false, error_code);

            // JSON-RPC 2.0 section 4.1: the server MUST NOT reply to a
            // notification, even when it fails.
            if (id == null) return null;
            // MCP cancellation: no response for a request the client
            // cancelled with notifications/cancelled.
            if (err == error.Cancelled and cancel.isCancelledByPeer()) return null;

            const message = if (detail) |d| d.message else @errorName(err);
            const data = if (detail) |d| d.data_json else null;
            return @as(?[]const u8, try self.makeErrorResponseWithData(id, error_code, message, data));
        };
        // The handler may have set a detail and then succeeded.
        clearErrorDetail();

        // Free the intermediate result if it was dynamically allocated: after
        // the response is built, for a notification (no response), and when
        // building the response fails.
        defer if (method_result.result) |r| {
            if (method_result.owned) self.allocator.free(r);
        };

        // If no id, this is a notification - no response
        if (id == null) {
            observability.endRpcServerSpan(__obs_span, true, 0);
            return null;
        }

        // Build success response. A handler result that is not one JSON
        // value is a handler bug: answer with an Internal error rather than
        // send a malformed response.
        const response = self.makeSuccessResponse(id.?, method_result.result) catch |err| switch (err) {
            error.InvalidHandlerResult => {
                observability.endRpcServerSpan(__obs_span, false, JsonRpcError.InternalError);
                return @as(?[]const u8, try self.makeErrorResponse(id, JsonRpcError.InternalError, "Invalid handler result"));
            },
            else => |e| return e,
        };

        observability.endRpcServerSpan(__obs_span, true, 0);
        return @as(?[]const u8, response);
    }

    /// Result from handleMethod with ownership tracking
    const MethodResult = struct {
        result: ?[]const u8,
        owned: bool, // If true, result must be freed by caller
    };

    fn handleMethod(self: *Server, method: []const u8, params: ?json.Value, cancel: *CancelToken) !MethodResult {
        if (std.mem.eql(u8, method, "initialize")) {
            return .{ .result = try self.handleInitialize(params), .owned = false }; // cached
        } else if (std.mem.eql(u8, method, "ping")) {
            return .{ .result = "{}", .owned = false };
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            self.clientState().initialized.* = true;
            return .{ .result = null, .owned = false };
        }

        // GAP-004: Block non-exempt requests before initialized
        // Allowed before init: initialize, ping, notifications/initialized, logging/*
        if (!self.clientState().initialized.*) {
            if (!std.mem.startsWith(u8, method, "logging/") and
                !std.mem.startsWith(u8, method, "notifications/"))
            {
                return error.NotInitialized;
            }
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            const cursor = self.extractCursor(params);
            // Handler results are server-owned (see Handler "Result Ownership").
            return .{ .result = try self.handler.listTools(self.handler.ctx, cursor), .owned = true };
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const name = self.extractString(params, "name") orelse return error.InvalidParams;

            const args = self.extractObject(params, "arguments");
            var args_json: []const u8 = "{}";
            var args_allocated = false;
            if (args) |a| {
                args_json = try json.stringify(self.allocator, a);
                args_allocated = true;
            }
            defer if (args_allocated) self.allocator.free(args_json);

            // Handler results are server-owned (see Handler "Result Ownership");
            // processJsonValue frees this slice once the response is built.
            return .{ .result = try self.handler.callTool(self.handler.ctx, name, args_json, cancel), .owned = true };
        } else if (std.mem.eql(u8, method, "resources/list")) {
            const cursor = self.extractCursor(params);
            return .{ .result = try self.handler.listResources(self.handler.ctx, cursor), .owned = true };
        } else if (std.mem.eql(u8, method, "resources/read")) {
            const uri = self.extractString(params, "uri") orelse return error.InvalidParams;
            if (!validateUri(uri)) return error.InvalidParams; // GAP-030
            return .{ .result = try self.handler.readResource(self.handler.ctx, uri), .owned = true };
        } else if (std.mem.eql(u8, method, "resources/templates/list")) {
            return .{ .result = try self.handler.listResourceTemplates(self.handler.ctx), .owned = true };
        } else if (std.mem.eql(u8, method, "resources/subscribe")) {
            const uri = self.extractString(params, "uri") orelse return error.InvalidParams;
            if (!validateUri(uri)) return error.InvalidParams; // GAP-030
            try self.handler.subscribeResource(self.handler.ctx, uri);
            return .{ .result = "{}", .owned = false };
        } else if (std.mem.eql(u8, method, "resources/unsubscribe")) {
            // GAP-013: Add resources/unsubscribe support
            const uri = self.extractString(params, "uri") orelse return error.InvalidParams;
            if (!validateUri(uri)) return error.InvalidParams; // GAP-030
            try self.handler.unsubscribeResource(self.handler.ctx, uri);
            return .{ .result = "{}", .owned = false };
        } else if (std.mem.eql(u8, method, "prompts/list")) {
            const cursor = self.extractCursor(params);
            return .{ .result = try self.handler.listPrompts(self.handler.ctx, cursor), .owned = true };
        } else if (std.mem.eql(u8, method, "prompts/get")) {
            const name = self.extractString(params, "name") orelse return error.InvalidParams;
            var args_json: ?[]const u8 = null;
            if (self.extractObject(params, "arguments")) |a| {
                args_json = try json.stringify(self.allocator, a);
            }
            defer if (args_json) |a| self.allocator.free(a);
            return .{ .result = try self.handler.getPrompt(self.handler.ctx, name, args_json), .owned = true };
        } else if (std.mem.eql(u8, method, "completion/complete")) {
            const params_json: ?[]const u8 = if (params) |p| try json.stringify(self.allocator, p) else null;
            defer if (params_json) |p| self.allocator.free(p);
            return .{ .result = try self.handler.complete(self.handler.ctx, params_json orelse "{}"), .owned = true };
        } else if (std.mem.eql(u8, method, "logging/setLevel")) {
            const level = self.extractString(params, "level") orelse return error.InvalidParams;
            try self.handler.setLogLevel(self.handler.ctx, level);
            return .{ .result = "{}", .owned = false };
        } else if (std.mem.eql(u8, method, "notifications/cancelled")) {
            // GAP-024: Handle cancellation by looking up and cancelling the request
            if (params) |p| {
                if (p == .obj) {
                    for (p.obj) |member| {
                        if (std.mem.eql(u8, member.k, "requestId")) {
                            // MCP RequestId is a string or an integer; an
                            // invalid one is ignored (cancellation spec).
                            switch (member.v) {
                                .num => |n| if (std.fmt.parseInt(i64, n.lexeme, 10)) |req_id| {
                                    self.cancelRequest(.{ .int = req_id });
                                } else |_| {},
                                .str => |str| self.cancelRequest(.{ .str = str }),
                                else => {},
                            }
                        }
                    }
                }
            }
            return .{ .result = null, .owned = false };
        } else if (std.mem.eql(u8, method, "notifications/progress")) {
            // Handle progress
            return .{ .result = null, .owned = false };
        } else if (std.mem.eql(u8, method, "notifications/roots/list_changed")) {
            // GAP-021: Handle roots list changed from client
            // Client is notifying us that its roots have changed
            return .{ .result = null, .owned = false };
        } else if (std.mem.eql(u8, method, "tasks/get")) {
            // GAP-036: Get task status
            if (!self.options.tasks_enabled) return error.MethodNotFound;
            const task_id = self.extractString(params, "taskId") orelse return error.InvalidParams;
            return .{ .result = try self.handleTasksGet(task_id), .owned = true };
        } else if (std.mem.eql(u8, method, "tasks/list")) {
            // GAP-037: List tasks
            if (!self.options.tasks_enabled) return error.MethodNotFound;
            return .{ .result = try self.handleTasksList(params), .owned = true };
        } else if (std.mem.eql(u8, method, "tasks/cancel")) {
            // GAP-038: Cancel task
            if (!self.options.tasks_enabled) return error.MethodNotFound;
            const task_id = self.extractString(params, "taskId") orelse return error.InvalidParams;
            return .{ .result = try self.handleTasksCancel(task_id), .owned = true };
        } else if (std.mem.eql(u8, method, "tasks/result")) {
            // GAP-039: Get task result (blocking)
            if (!self.options.tasks_enabled) return error.MethodNotFound;
            const task_id = self.extractString(params, "taskId") orelse return error.InvalidParams;
            return .{ .result = try self.handleTasksResult(task_id), .owned = true };
        } else {
            return error.MethodNotFound;
        }
    }

    fn handleInitialize(self: *Server, params: ?json.Value) ![]const u8 {
        // The state of the client being served (SONNY-6644).
        const state = self.clientState();
        // Parse client capabilities and version (GAP-001, GAP-002)
        if (params) |p| {
            if (p == .obj) {
                for (p.obj) |member| {
                    if (std.mem.eql(u8, member.k, "protocolVersion")) {
                        if (member.v == .str) {
                            // Store a copy of the client's requested version:
                            // member.v.str points into the parsed message,
                            // which is freed when this request completes.
                            const version = try self.allocator.dupe(u8, member.v.str);
                            if (state.protocol_version.*) |old| self.allocator.free(old);
                            state.protocol_version.* = version;
                        }
                    } else if (std.mem.eql(u8, member.k, "capabilities")) {
                        if (member.v == .obj) {
                            for (member.v.obj) |cap| {
                                if (std.mem.eql(u8, cap.k, "roots")) {
                                    state.capabilities.roots = true;
                                    if (cap.v == .obj) {
                                        for (cap.v.obj) |root_cap| {
                                            if (std.mem.eql(u8, root_cap.k, "listChanged")) {
                                                if (root_cap.v == .bool) {
                                                    state.capabilities.roots_list_changed = root_cap.v.bool;
                                                }
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, cap.k, "sampling")) {
                                    state.capabilities.sampling = true;
                                    // GAP-057/058: Parse nested sampling capabilities
                                    if (cap.v == .obj) {
                                        for (cap.v.obj) |samp_cap| {
                                            if (std.mem.eql(u8, samp_cap.k, "tools")) {
                                                if (samp_cap.v == .bool) {
                                                    state.capabilities.sampling_tools = samp_cap.v.bool;
                                                } else {
                                                    state.capabilities.sampling_tools = true;
                                                }
                                            } else if (std.mem.eql(u8, samp_cap.k, "context")) {
                                                if (samp_cap.v == .bool) {
                                                    state.capabilities.sampling_context = samp_cap.v.bool;
                                                } else {
                                                    state.capabilities.sampling_context = true;
                                                }
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, cap.k, "elicitation")) {
                                    // GAP-041: Parse elicitation capability
                                    state.capabilities.elicitation = true;
                                } else if (std.mem.eql(u8, cap.k, "experimental")) {
                                    // GAP-026: Store experimental capabilities as raw JSON
                                    if (cap.v == .obj) {
                                        const experimental = json.stringify(self.allocator, cap.v) catch null;
                                        if (state.capabilities.experimental) |old| self.allocator.free(old);
                                        state.capabilities.experimental = experimental;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Return cached response if available. Connections are served
        // concurrently, so build it at most once.
        self.init_mutex.lockUncancelable(io());
        defer self.init_mutex.unlock(io());
        if (self.cached_init_response) |cached| {
            return cached;
        }

        // Build and cache the response
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"protocolVersion\":\"");
        try buf.appendSlice(self.allocator, ProtocolVersion);
        try buf.appendSlice(self.allocator, "\",\"capabilities\":{\"tools\":{\"listChanged\":true},\"resources\":{\"subscribe\":true,\"listChanged\":true},\"prompts\":{\"listChanged\":true},\"logging\":{},\"completions\":{}");
        // GAP-035: Add tasks capability if enabled
        if (self.options.tasks_enabled) {
            try buf.appendSlice(self.allocator, ",\"tasks\":{\"list\":true,\"cancel\":true,\"requests\":{\"tools\":{\"call\":true}}}");
        }
        try buf.appendSlice(self.allocator, "},\"serverInfo\":{\"name\":\"");
        try buf.appendSlice(self.allocator, self.options.name);
        try buf.appendSlice(self.allocator, "\",\"version\":\"");
        try buf.appendSlice(self.allocator, self.options.version);
        try buf.appendSlice(self.allocator, "\"");
        if (self.options.instructions) |inst| {
            try buf.appendSlice(self.allocator, ",\"instructions\":\"");
            try buf.appendSlice(self.allocator, inst);
            try buf.appendSlice(self.allocator, "\"");
        }
        // GAP-050: description field
        if (self.options.description) |desc| {
            try buf.appendSlice(self.allocator, ",\"description\":\"");
            try buf.appendSlice(self.allocator, desc);
            try buf.appendSlice(self.allocator, "\"");
        }
        // GAP-052: website field
        if (self.options.website) |site| {
            try buf.appendSlice(self.allocator, ",\"website\":\"");
            try buf.appendSlice(self.allocator, site);
            try buf.appendSlice(self.allocator, "\"");
        }
        // GAP-051: icons field (expects JSON array)
        if (self.options.icons) |ic| {
            try buf.appendSlice(self.allocator, ",\"icons\":");
            try buf.appendSlice(self.allocator, ic);
        }
        try buf.appendSlice(self.allocator, "}}");

        self.cached_init_response = try buf.toOwnedSlice(self.allocator);
        return self.cached_init_response.?;
    }

    // ========================================================================
    // Task Methods (GAP-035-040)
    // ========================================================================

    /// Generate a unique task ID
    fn generateTaskId(self: *Server) ![]const u8 {
        const id = self.task_id_counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(self.allocator, "task-{d}", .{id});
    }

    /// Create a new task for async request processing (GAP-040)
    ///
    /// Returns an owned copy of the new task; free it with
    /// `task.deinit(server.allocator)`. It is a snapshot: use `getTask`
    /// for the current state. (It returned a pointer into the task table,
    /// which a later insert could move: SONNY-6644.)
    pub fn createTask(self: *Server, method: []const u8, ttl_ms: ?u32) !Task {
        const task_id = try self.generateTaskId();
        errdefer self.allocator.free(task_id);
        const now = std.Io.Timestamp.now(io(), .real).toMilliseconds();

        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        const owner = if (dispatch_ctx.http) |hs| try self.allocator.dupe(u8, hs.id) else null;
        errdefer if (owner) |o| self.allocator.free(o);

        const task = Task{
            .id = task_id,
            .status = .working,
            .created_at = now,
            .last_updated = now,
            .ttl_ms = ttl_ms orelse self.options.tasks_default_ttl_ms,
            .poll_interval_ms = self.options.tasks_poll_interval_ms,
            .result = null,
            .method = owned_method,
            .owner = owner,
        };

        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());

        const copy = try task.clone(self.allocator);
        errdefer {
            var c = copy;
            c.deinit(self.allocator);
        }
        try self.tasks.put(self.allocator, task_id, task);
        return copy;
    }

    /// Whether the client being served may see `task`: tasks belong to the
    /// HTTP session that created them (SONNY-6644).
    fn taskVisible(task: *const Task) bool {
        const current: ?[]const u8 = if (dispatch_ctx.http) |hs| hs.id else null;
        if (task.owner) |owner| {
            return if (current) |c| std.mem.eql(u8, owner, c) else false;
        }
        return current == null;
    }

    /// The task with `task_id` if the client being served may see it.
    /// Call with `tasks_mutex` held.
    fn visibleTask(self: *Server, task_id: []const u8) ?*Task {
        const task = self.tasks.getPtr(task_id) orelse return null;
        return if (taskVisible(task)) task else null;
    }

    fn freeTask(self: *Server, task: *Task) void {
        task.deinit(self.allocator);
    }

    /// An owned copy of the task with `task_id` (current state), or null;
    /// free it with `task.deinit(server.allocator)`. (It returned a pointer
    /// into the task table after releasing its lock: SONNY-6644.)
    pub fn getTask(self: *Server, task_id: []const u8) !?Task {
        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());
        const task = self.tasks.getPtr(task_id) orelse return null;
        return try task.clone(self.allocator);
    }

    /// Update task status
    pub fn updateTaskStatus(self: *Server, task_id: []const u8, status: TaskState, result: ?[]const u8) void {
        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());

        if (self.tasks.getPtr(task_id)) |task| {
            task.status = status;
            task.last_updated = std.Io.Timestamp.now(io(), .real).toMilliseconds();
            if (result) |r| {
                if (task.result) |old| self.allocator.free(old);
                task.result = self.allocator.dupe(u8, r) catch null;
            }
        }
    }

    /// GAP-036: Handle tasks/get
    fn handleTasksGet(self: *Server, task_id: []const u8) !?[]const u8 {
        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());

        if (self.visibleTask(task_id)) |task| {
            return @as(?[]const u8, try task.toJson(self.allocator));
        }
        return error.InvalidParams; // Task not found
    }

    /// GAP-037: Handle tasks/list
    fn handleTasksList(self: *Server, params: ?json.Value) !?[]const u8 {
        const cursor = self.extractCursor(params);
        var limit: usize = 100;
        if (params) |p| {
            if (p == .obj) {
                for (p.obj) |member| {
                    if (std.mem.eql(u8, member.k, "limit")) {
                        if (member.v == .num) {
                            limit = std.fmt.parseInt(usize, member.v.num.lexeme, 10) catch limit;
                        }
                    }
                }
            }
        }
        if (limit == 0) limit = 1;

        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());

        const TaskEntry = struct {
            id: []const u8,
            created_at: i64,
            task: *const Task,
        };

        var entries = std.ArrayListUnmanaged(TaskEntry).empty;
        defer entries.deinit(self.allocator);

        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            if (!taskVisible(entry.value_ptr)) continue;
            try entries.append(self.allocator, .{
                .id = entry.key_ptr.*,
                .created_at = entry.value_ptr.created_at,
                .task = entry.value_ptr,
            });
        }

        std.mem.sort(TaskEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: TaskEntry, b: TaskEntry) bool {
                if (a.created_at != b.created_at) {
                    return a.created_at < b.created_at;
                }
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lessThan);

        var start_index: usize = 0;
        if (cursor) |c| {
            var found = false;
            for (entries.items, 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.id, c)) {
                    start_index = idx + 1;
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidParams;
        }

        const end_index = @min(entries.items.len, start_index + limit);
        const has_more = end_index < entries.items.len;

        var buf = std.ArrayListUnmanaged(u8).empty;
        try buf.appendSlice(self.allocator, "{\"tasks\":[");

        var first = true;
        var idx = start_index;
        while (idx < end_index) : (idx += 1) {
            const entry = entries.items[idx];
            if (!first) try buf.appendSlice(self.allocator, ",");
            first = false;
            const task_json = try entry.task.toJson(self.allocator);
            defer self.allocator.free(task_json);
            try buf.appendSlice(self.allocator, task_json);
        }

        if (has_more) {
            try buf.appendSlice(self.allocator, "],\"nextCursor\":\"");
            try buf.appendSlice(self.allocator, entries.items[end_index - 1].id);
            try buf.appendSlice(self.allocator, "\"}");
        } else {
            try buf.appendSlice(self.allocator, "]}");
        }
        return @as(?[]const u8, try buf.toOwnedSlice(self.allocator));
    }

    /// GAP-038: Handle tasks/cancel
    fn handleTasksCancel(self: *Server, task_id: []const u8) !?[]const u8 {
        self.tasks_mutex.lockUncancelable(io());
        defer self.tasks_mutex.unlock(io());

        if (self.visibleTask(task_id)) |task| {
            if (!task.status.isTerminal()) {
                task.status = .cancelled;
                task.last_updated = std.Io.Timestamp.now(io(), .real).toMilliseconds();
            }
            return @as(?[]const u8, try task.toJson(self.allocator));
        }
        return error.InvalidParams; // Task not found
    }

    /// GAP-039: Handle tasks/result (blocking until complete)
    fn handleTasksResult(self: *Server, task_id: []const u8) !?[]const u8 {
        // Poll until task is complete (with timeout)
        const start = std.Io.Timestamp.now(io(), .real).toMilliseconds();
        const timeout_ms: i64 = 60000; // 1 minute max wait

        while (true) {
            {
                self.tasks_mutex.lockUncancelable(io());
                defer self.tasks_mutex.unlock(io());

                if (self.visibleTask(task_id)) |task| {
                    if (task.status.isTerminal()) {
                        if (task.result) |result| {
                            return @as(?[]const u8, try self.allocator.dupe(u8, result));
                        }
                        // Return task status if no result stored
                        return @as(?[]const u8, try task.toJson(self.allocator));
                    }
                } else {
                    return error.InvalidParams; // Task not found
                }
            }

            // Check timeout
            if (std.Io.Timestamp.now(io(), .real).toMilliseconds() - start > timeout_ms) {
                return error.InvalidParams; // Timeout waiting for task
            }

            // Sleep briefly before polling again
            io().sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
    }

    fn extractCursor(self: *Server, params: ?json.Value) ?[]const u8 {
        _ = self;
        if (params) |p| {
            if (p == .obj) {
                for (p.obj) |member| {
                    if (std.mem.eql(u8, member.k, "cursor")) {
                        if (member.v == .str) {
                            return member.v.str;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn extractString(self: *Server, params: ?json.Value, key: []const u8) ?[]const u8 {
        _ = self;
        if (params) |p| {
            if (p == .obj) {
                for (p.obj) |member| {
                    if (std.mem.eql(u8, member.k, key)) {
                        if (member.v == .str) {
                            return member.v.str;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn extractObject(self: *Server, params: ?json.Value, key: []const u8) ?json.Value {
        _ = self;
        if (params) |p| {
            if (p == .obj) {
                for (p.obj) |member| {
                    if (std.mem.eql(u8, member.k, key)) {
                        if (member.v == .obj) {
                            return member.v;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn makeSuccessResponse(self: *Server, id: RequestId, result: ?[]const u8) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        switch (id) {
            .int => |i| try buf.print(self.allocator, "{d}", .{i}),
            .str => |s| try appendJsonString(self.allocator, &buf, s),
        }
        try buf.appendSlice(self.allocator, ",\"result\":");
        if (result) |r| {
            try appendCompactJson(self.allocator, &buf, r);
        } else {
            try buf.appendSlice(self.allocator, "null");
        }
        try buf.append(self.allocator, '}');

        // Note: result is NOT freed here; processJsonValue owns it.
        return buf.toOwnedSlice(self.allocator);
    }

    fn makeErrorResponse(self: *Server, id: ?RequestId, code: i32, message: []const u8) ![]const u8 {
        return self.makeErrorResponseWithData(id, code, message, null);
    }

    /// GAP-032: Error response with optional data field. `message` and a
    /// string id are JSON-escaped; `data` must already be one JSON value.
    fn makeErrorResponseWithData(self: *Server, id: ?RequestId, code: i32, message: []const u8, data: ?[]const u8) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |req_id| {
            switch (req_id) {
                .int => |i| try buf.print(self.allocator, "{d}", .{i}),
                .str => |s| try appendJsonString(self.allocator, &buf, s),
            }
        } else {
            try buf.appendSlice(self.allocator, "null");
        }
        try buf.appendSlice(self.allocator, ",\"error\":{\"code\":");
        try buf.print(self.allocator, "{d}", .{code});
        try buf.appendSlice(self.allocator, ",\"message\":");
        try appendJsonString(self.allocator, &buf, message);
        if (data) |d| {
            try buf.appendSlice(self.allocator, ",\"data\":");
            try buf.appendSlice(self.allocator, d);
        }
        try buf.appendSlice(self.allocator, "}}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn sendResponse(self: *Server, response: []const u8) !void {
        // Use buffered writer if available (Zig 0.15 API) for better performance
        if (self.stdout_writer_wrap) |*writer| {
            try writer.interface.writeAll(response);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        } else if (self.stdout_writer) |*writer| {
            // Legacy unbuffered fallback
            try writer.interface.writeAll(response);
            try writer.interface.writeByte('\n');
        }
        self.allocator.free(response);
    }

    /// The state of the client being served: the HTTP session's when
    /// dispatching for one, else the server's own (stdio / processMessage).
    fn clientState(self: *Server) ClientStateRef {
        if (dispatch_ctx.http) |hs| return .{
            .initialized = &hs.client.initialized,
            .capabilities = &hs.client.capabilities,
            .protocol_version = &hs.client.protocol_version,
        };
        return .{
            .initialized = &self.initialized,
            .capabilities = &self.client_capabilities,
            .protocol_version = &self.client_protocol_version,
        };
    }

    /// The server-to-client request session of the client being served.
    fn currentSession(self: *Server) ?*Session {
        if (dispatch_ctx.http) |hs| {
            return if (self.isSessionClosed(hs)) null else &hs.session;
        }
        return if (self.session) |*s| s else null;
    }

    /// Sends one JSON-RPC message to the client being served.
    fn sendToClient(self: *Server, data: []const u8) !void {
        return self.deliver(dispatch_ctx.http, data);
    }

    /// Sends one JSON-RPC message to `target` (an HTTP client), or over
    /// stdio when null. Never broadcasts (SONNY-6644): an HTTP message goes
    /// on the stream of the request being served for that client, else on
    /// that client's GET stream. With no client to send to it fails with
    /// `error.NoSession`.
    fn deliver(self: *Server, target: ?*HttpSession, data: []const u8) !void {
        if (target) |hs| {
            if (self.isSessionClosed(hs)) return error.NoSession;
            if (dispatch_ctx.post) |ps| {
                if (ps.session == hs and ps.accepts_sse) return ps.sendEvent(data);
            }
            return hs.sendOnGetStream(data);
        }
        if (self.stdout_writer_wrap) |*writer| {
            // Send via stdout for stdio transport using buffered writer (Zig 0.15 API)
            try writer.interface.writeAll(data);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        } else if (self.stdout_writer) |*writer| {
            // Legacy unbuffered fallback
            try writer.interface.writeAll(data);
            try writer.interface.writeByte('\n');
        } else {
            return error.NoSession;
        }
    }

    /// A notification meant for every client (list_changed): one copy over
    /// stdio, and one copy on each HTTP client's own GET stream.
    fn sendNotificationToAll(self: *Server, method: []const u8) !void {
        const notification = try buildMessageJson(self.allocator, null, method, null);
        defer self.allocator.free(notification);

        if (self.stdout_writer_wrap != null or self.stdout_writer != null) {
            try self.deliver(null, notification);
        }

        var targets = std.ArrayListUnmanaged(*HttpSession).empty;
        defer targets.deinit(self.allocator);
        {
            self.sessions_mutex.lockUncancelable(io());
            defer self.sessions_mutex.unlock(io());
            var it = self.http_sessions.valueIterator();
            while (it.next()) |hs| {
                if (hs.*.closed) continue;
                try targets.append(self.allocator, hs.*);
                hs.*.refs += 1;
            }
        }
        for (targets.items) |hs| {
            hs.sendOnGetStream(notification) catch {};
            self.releaseHttpSession(hs);
        }
    }
};

// ============================================================================
// Demo Handler for Testing
// ============================================================================

pub const DemoHandler = struct {
    /// Allocator the callbacks use to produce server-owned results, per the
    /// `Handler` "Result Ownership" contract (the dispatcher frees every
    /// returned slice with `Server.allocator`, so this must be the same
    /// allocator the server is built with). Threaded per-instance via
    /// `Handler.ctx` (see `handler()`) rather than a package-level global,
    /// so multiple `DemoHandler` instances (e.g. concurrent tests or servers
    /// in the same process) each carry their own allocator instead of racing
    /// on shared mutable state.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DemoHandler {
        return .{ .allocator = allocator };
    }

    /// Builds the `Handler` vtable bound to this instance via `ctx`.
    /// `self` must outlive every use of the returned `Handler` (the same
    /// requirement as the `ctx` pattern in examples/03_tool_registration.zig).
    pub fn handler(self: *DemoHandler) Handler {
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

    /// Returns a server-owned copy of `text` (results are freed by the
    /// server, so static literals must not be returned directly).
    fn owned(ctx: ?*anyopaque, text: []const u8) ![]const u8 {
        const self: *DemoHandler = @ptrCast(@alignCast(ctx.?));
        return self.allocator.dupe(u8, text);
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx,
            \\{"tools":[{"name":"echo","description":"Replies with a fixed text","inputSchema":{"type":"object"}}]}
        );
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const CancelToken) anyerror![]const u8 {
        if (std.mem.eql(u8, name, "echo")) {
            return owned(ctx,
                \\{"content":[{"type":"text","text":"echo"}]}
            );
        }
        return error.ToolNotFound;
    }

    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"resources\":[]}");
    }

    fn readResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return error.ResourceNotFound;
    }

    fn listResourceTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
        return owned(ctx, "{\"resourceTemplates\":[]}");
    }

    fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return owned(ctx, "{\"prompts\":[]}");
    }

    fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
        return error.PromptNotFound;
    }

    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return owned(ctx, "{\"completion\":{\"values\":[]}}");
    }

    fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
};

// ============================================================================
// Tests
// ============================================================================

test "CancelToken" {
    var token = CancelToken{};
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "Server init and deinit" {
    const allocator = std.testing.allocator;
    var demo_handler = DemoHandler.init(allocator);
    var server = try Server.init(allocator, .{
        .name = "test",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();
}

test "JSON-RPC parse single request" {
    const allocator = std.testing.allocator;
    var demo_handler = DemoHandler.init(allocator);
    var server = try Server.init(allocator, .{
        .name = "test",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"result\":{}") != null);
}

test "JSON-RPC parse batch request" {
    const allocator = std.testing.allocator;
    var demo_handler = DemoHandler.init(allocator);
    var server = try Server.init(allocator, .{
        .name = "test",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const request =
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(response.?[0] == '[');
}

test "Initialize response" {
    const allocator = std.testing.allocator;
    var demo_handler = DemoHandler.init(allocator);
    var server = try Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "test-server") != null);
}
