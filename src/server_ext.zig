// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Server Extensions - WebSocket and Metrics Integration
//!
//! Provides integrated WebSocket transport and metrics collection for MCP servers.
//! Extends the base Server with additional capabilities.

const std = @import("std");
const mcp = @import("mcp");
const log = @import("log");
const crypto_backend = @import("crypto_backend");
const Allocator = std.mem.Allocator;

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Read bytes from a network stream.
fn streamRead(stream: std.Io.net.Stream, buf: []u8) !usize {
    return std.posix.read(stream.socket.handle, buf);
}

/// Write all bytes to a network stream.
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

/// Extended server with integrated metrics and WebSocket support
pub const ExtendedServer = struct {
    /// Base MCP server
    server: mcp.Server,
    /// Integrated metrics collector
    metrics: ?*mcp.Metrics = null,
    /// WebSocket listener
    ws_listener: ?std.Io.net.Server = null,
    /// WebSocket thread
    ws_thread: ?std.Thread = null,
    /// Active WebSocket connections
    ws_connections: std.ArrayListUnmanaged(*mcp.WebSocketConnection) = .empty,
    /// WebSocket mutex
    ws_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Shutdown flag
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Logger
    logger: ?*log.Logger = null,

    /// Extended server options
    pub const ExtendedOptions = struct {
        /// Base server options
        server: mcp.ServerOptions,
        /// Enable metrics collection
        enable_metrics: bool = true,
        /// Metrics export path (for HTTP)
        metrics_path: []const u8 = "/metrics",
        /// WebSocket configuration
        websocket: WebSocketConfig = .{},
        /// Logging configuration
        logging: LogConfig = .{},
    };

    pub const WebSocketConfig = struct {
        enabled: bool = false,
        bind_address: []const u8 = "127.0.0.1",
        port: u16 = 0,
        path: []const u8 = "/ws",
        max_connections: u32 = 100,
        ping_interval_ms: u32 = 30000,
        max_message_size: usize = 1024 * 1024,
    };

    pub const LogConfig = struct {
        enabled: bool = true,
        level: log.Level = .info,
        format: log.Format = .text,
        include_timestamps: bool = true,
    };

    /// Initialize extended server
    pub fn init(
        allocator: Allocator,
        options: ExtendedOptions,
        handler: mcp.Handler,
    ) !ExtendedServer {
        // Initialize base server
        const server = try mcp.Server.init(allocator, options.server, handler);

        var ext = ExtendedServer{
            .server = server,
        };

        // Initialize metrics if enabled
        if (options.enable_metrics) {
            const metrics_ptr = try allocator.create(mcp.Metrics);
            metrics_ptr.* = mcp.Metrics.init(allocator);
            ext.metrics = metrics_ptr;
        }

        // Initialize logger if enabled
        if (options.logging.enabled) {
            const logger_ptr = try allocator.create(log.Logger);
            logger_ptr.* = log.Logger.init(allocator, options.server.name, .{
                .level = options.logging.level,
                .format = options.logging.format,
                .timestamps = options.logging.include_timestamps,
            });
            ext.logger = logger_ptr;
        }

        return ext;
    }

    /// Deinitialize extended server
    pub fn deinit(self: *ExtendedServer) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Stop WebSocket listener
        if (self.ws_thread) |thread| {
            thread.join();
        }
        if (self.ws_listener) |*listener| {
            listener.deinit(io());
        }

        // Close all WebSocket connections
        self.ws_mutex.lockUncancelable(io());
        for (self.ws_connections.items) |conn| {
            conn.deinit();
            self.server.allocator.destroy(conn);
        }
        self.ws_connections.deinit(self.server.allocator);
        self.ws_mutex.unlock(io());

        // Free metrics
        if (self.metrics) |m| {
            m.deinit();
            self.server.allocator.destroy(m);
        }

        // Free logger
        if (self.logger) |l| {
            self.server.allocator.destroy(l);
        }

        // Deinit base server
        self.server.deinit();
    }

    /// Serve via stdio with metrics
    pub fn serveStdio(self: *ExtendedServer) !void {
        if (self.logger) |l| {
            l.info("Starting stdio transport", .{});
        }

        if (self.metrics) |m| {
            m.connectionOpened();
        }

        try self.server.serveStdio();

        if (self.metrics) |m| {
            m.connectionClosed();
        }
    }

    /// Serve via HTTP with metrics and WebSocket upgrade support
    pub fn serveHttp(self: *ExtendedServer) !u16 {
        if (self.logger) |l| {
            l.info("Starting HTTP transport on {s}:{d}", .{
                self.server.options.http_bind,
                self.server.options.http_port,
            });
        }

        const port = try self.server.serveHttp();

        if (self.logger) |l| {
            l.info("HTTP server listening on port {d}", .{port});
        }

        return port;
    }

    /// Start WebSocket server
    pub fn serveWebSocket(self: *ExtendedServer, config: WebSocketConfig) !u16 {
        var address = std.Io.net.IpAddress.parseIp4(config.bind_address, config.port) catch
            return error.InvalidAddress;

        self.ws_listener = try std.Io.net.IpAddress.listen(&address, io(), .{
            .reuse_address = true,
        });

        const actual_port = self.ws_listener.?.socket.address.getPort();

        if (self.logger) |l| {
            l.info("WebSocket server listening on {s}:{d}", .{ config.bind_address, actual_port });
        }

        // Start accept thread
        // daemon: WebSocket accept loop. Same rationale as the HTTP accept
        // loop in mcp.zig — long-lived blocking accept.
        self.ws_thread = try std.Thread.spawn(.{}, wsAcceptLoop, .{ self, config });

        return actual_port;
    }

    fn wsAcceptLoop(self: *ExtendedServer, config: WebSocketConfig) void {
        while (!self.shutdown.load(.acquire)) {
            var listener = self.ws_listener orelse break;
            const conn = listener.accept(io()) catch continue;

            // Check connection limit
            self.ws_mutex.lockUncancelable(io());
            if (self.ws_connections.items.len >= config.max_connections) {
                self.ws_mutex.unlock(io());
                streamClose(conn);
                continue;
            }
            self.ws_mutex.unlock(io());

            // Spawn handler thread
            // daemon per WebSocket connection: the handler serves messages on the
            // stream for the connection's lifetime. Long-lived per-client streams
            // are not a pool fit (see grpc-zig/src/server.zig for parallel
            // reasoning).
            _ = std.Thread.spawn(.{}, wsConnectionHandler, .{ self, conn, config }) catch {
                streamClose(conn);
                continue;
            };
        }
    }

    fn wsConnectionHandler(self: *ExtendedServer, stream: std.Io.net.Stream, config: WebSocketConfig) void {
        _ = config;
        // FIPS-0008: the WebSocket handshake requires the SHA-1 accept-key,
        // which is removed under -Dfips=true (generateWebSocketAcceptKey is
        // @compileError'd out). Comptime-elide the whole handler so no fips
        // caller references the SHA-1 path. fips deployments must front MCP
        // with a TLS-terminating proxy or use a non-WebSocket transport.
        if (comptime crypto_backend.fips_enabled) {
            streamClose(stream);
            return;
        }
        // Perform WebSocket handshake
        var buf: [4096]u8 = undefined;
        const n = streamRead(stream, &buf) catch {
            streamClose(stream);
            return;
        };

        const request = buf[0..n];

        // Check for WebSocket upgrade
        if (std.mem.indexOf(u8, request, "Upgrade: websocket") == null) {
            streamClose(stream);
            return;
        }

        // Extract Sec-WebSocket-Key
        const key_start = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse {
            streamClose(stream);
            return;
        };
        const key_value_start = key_start + 19;
        const key_end = std.mem.indexOfPos(u8, request, key_value_start, "\r\n") orelse {
            streamClose(stream);
            return;
        };
        const client_key = request[key_value_start..key_end];

        // Generate accept key
        const accept_key = mcp.generateWebSocketAcceptKey(client_key) catch {
            streamClose(stream);
            return;
        };

        // Send upgrade response
        const response = std.fmt.allocPrint(self.server.allocator,
            \\HTTP/1.1 101 Switching Protocols
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Accept: {s}
            \\
            \\
        , .{accept_key}) catch {
            streamClose(stream);
            return;
        };
        defer self.server.allocator.free(response);

        streamWriteAll(stream, response) catch {
            streamClose(stream);
            return;
        };

        // Create session ID
        var session_id_buf: [36]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(io(), .real).toSeconds()));
        for (&session_id_buf) |*c| {
            c.* = "0123456789abcdef"[prng.random().intRangeLessThan(usize, 0, 16)];
        }

        // Create WebSocket connection
        const ws_conn = self.server.allocator.create(mcp.WebSocketConnection) catch {
            streamClose(stream);
            return;
        };
        ws_conn.* = mcp.WebSocketConnection.init(self.server.allocator, stream, &session_id_buf) catch {
            self.server.allocator.destroy(ws_conn);
            streamClose(stream);
            return;
        };

        // Add to connections list
        self.ws_mutex.lockUncancelable(io());
        self.ws_connections.append(self.server.allocator, ws_conn) catch {
            self.ws_mutex.unlock(io());
            ws_conn.deinit();
            self.server.allocator.destroy(ws_conn);
            return;
        };
        self.ws_mutex.unlock(io());

        if (self.metrics) |m| {
            m.connectionOpened();
        }

        if (self.logger) |l| {
            l.debug("WebSocket connection established", .{});
        }

        // Message handling loop
        var msg_buf: [65536]u8 = undefined;
        while (!self.shutdown.load(.acquire)) {
            const msg_n = streamRead(stream, &msg_buf) catch break;
            if (msg_n == 0) break;

            const timer_start = std.Io.Timestamp.now(io(), .awake);

            // Process message
            const result = ws_conn.receiveMessage(msg_buf[0..msg_n]) catch break;
            if (result) |msg| {
                defer self.server.allocator.free(msg.payload);

                if (msg.opcode == .text) {
                    // Handle as JSON-RPC
                    // In a full implementation, this would call server.handleRequest
                    if (self.metrics) |m| {
                        m.recordBytesReceived(msg.payload.len);
                    }

                    // Echo for now (placeholder for actual request handling)
                    ws_conn.sendText(msg.payload) catch break;

                    if (self.metrics) |m| {
                        const elapsed = timer_start.durationTo(std.Io.Timestamp.now(io(), .awake));
                        const latency: u64 = @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_us));
                        m.recordRequest("websocket", latency);
                        m.recordBytesSent(msg.payload.len);
                    }
                } else if (msg.opcode == .ping) {
                    ws_conn.sendPong(msg.payload) catch break;
                } else if (msg.opcode == .close) {
                    ws_conn.sendClose(.normal_closure) catch {};
                    break;
                }
            }
        }

        // Remove from connections list
        self.ws_mutex.lockUncancelable(io());
        for (self.ws_connections.items, 0..) |conn, i| {
            if (conn == ws_conn) {
                _ = self.ws_connections.orderedRemove(i);
                break;
            }
        }
        self.ws_mutex.unlock(io());

        ws_conn.deinit();
        self.server.allocator.destroy(ws_conn);

        if (self.metrics) |m| {
            m.connectionClosed();
        }

        if (self.logger) |l| {
            l.debug("WebSocket connection closed", .{});
        }
    }

    /// Get metrics in Prometheus format
    pub fn exportMetrics(self: *ExtendedServer) ![]const u8 {
        if (self.metrics) |m| {
            return try m.exportPrometheus(self.server.allocator);
        }
        return "";
    }

    /// Record a request metric
    pub fn recordRequest(self: *ExtendedServer, method: []const u8, latency_us: u64) void {
        if (self.metrics) |m| {
            m.recordRequest(method, latency_us);
        }
    }

    /// Record an error metric
    pub fn recordError(self: *ExtendedServer, error_code: []const u8) void {
        if (self.metrics) |m| {
            m.recordError(error_code);
        }
    }

    /// Broadcast message to all WebSocket connections
    pub fn broadcastWebSocket(self: *ExtendedServer, message: []const u8) void {
        self.ws_mutex.lockUncancelable(io());
        defer self.ws_mutex.unlock(io());

        for (self.ws_connections.items) |conn| {
            conn.sendText(message) catch continue;
        }
    }

    /// Get number of active connections
    pub fn getConnectionCount(self: *ExtendedServer) usize {
        self.ws_mutex.lockUncancelable(io());
        defer self.ws_mutex.unlock(io());
        return self.ws_connections.items.len;
    }

    /// Send notification to all connections
    pub fn notify(self: *ExtendedServer, method: []const u8, params: []const u8) !void {
        // Build notification JSON
        const notification = try std.fmt.allocPrint(self.server.allocator,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s}}}
        , .{ method, params });
        defer self.server.allocator.free(notification);

        // Send via base server (SSE connections)
        try self.server.notify(method, params);

        // Also broadcast to WebSocket connections
        self.broadcastWebSocket(notification);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "extended server initialization" {
    const allocator = std.testing.allocator;

    const handler = mcp.DemoHandler.create();
    var server = try ExtendedServer.init(allocator, .{
        .server = .{
            .name = "test-server",
            .version = "1.0.0",
        },
        .enable_metrics = true,
    }, handler);
    defer server.deinit();

    try std.testing.expect(server.metrics != null);
}

test "extended server metrics recording" {
    const allocator = std.testing.allocator;

    const handler = mcp.DemoHandler.create();
    var server = try ExtendedServer.init(allocator, .{
        .server = .{
            .name = "test-server",
            .version = "1.0.0",
        },
        .enable_metrics = true,
    }, handler);
    defer server.deinit();

    server.recordRequest("tools/call", 1000);
    server.recordError("-32600");

    const metrics = try server.exportMetrics();
    defer allocator.free(metrics);

    try std.testing.expect(metrics.len > 0);
}
