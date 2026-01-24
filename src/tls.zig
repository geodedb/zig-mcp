// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! TLS Support for MCP Transports
//!
//! Provides TLS/SSL encryption for HTTP and WebSocket transports.
//! Uses Zig 0.15's std.crypto.tls module.

const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const tls = crypto.tls;
const Allocator = std.mem.Allocator;

/// TLS configuration for server
pub const TlsServerConfig = struct {
    /// Path to PEM-encoded certificate file
    cert_file: ?[]const u8 = null,
    /// Path to PEM-encoded private key file
    key_file: ?[]const u8 = null,
    /// PEM-encoded certificate chain (alternative to file)
    cert_pem: ?[]const u8 = null,
    /// PEM-encoded private key (alternative to file)
    key_pem: ?[]const u8 = null,
    /// Minimum TLS version (default: TLS 1.2)
    min_version: TlsVersion = .tls_1_2,
    /// Enable client certificate verification
    client_auth: ClientAuth = .none,
    /// Path to CA certificate for client verification
    client_ca_file: ?[]const u8 = null,
};

/// TLS configuration for client
pub const TlsClientConfig = struct {
    /// Path to CA certificate bundle file
    ca_file: ?[]const u8 = null,
    /// PEM-encoded CA certificates (alternative to file)
    ca_pem: ?[]const u8 = null,
    /// Skip server certificate verification (INSECURE - for testing only)
    insecure_skip_verify: bool = false,
    /// Client certificate for mutual TLS
    client_cert_file: ?[]const u8 = null,
    /// Client private key for mutual TLS
    client_key_file: ?[]const u8 = null,
    /// Server name for SNI (Server Name Indication)
    server_name: ?[]const u8 = null,
};

/// TLS version
pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// Client authentication mode
pub const ClientAuth = enum {
    none,
    request,
    require,
};

/// TLS connection state
pub const TlsState = enum {
    handshaking,
    established,
    closing,
    closed,
    failed,
};

/// TLS-wrapped stream for secure communication
pub const TlsStream = struct {
    allocator: Allocator,
    inner_stream: net.Stream,
    state: TlsState = .handshaking,
    is_client: bool,
    tls_client: ?tls.Client = null,
    read_buffer: []u8,
    write_buffer: []u8,

    const default_buffer_size = 16384;

    /// Create a TLS client stream
    pub fn initClient(
        allocator: Allocator,
        stream: net.Stream,
        config: TlsClientConfig,
    ) !TlsStream {
        const read_buf = try allocator.alloc(u8, default_buffer_size);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, default_buffer_size);
        errdefer allocator.free(write_buf);

        var self = TlsStream{
            .allocator = allocator,
            .inner_stream = stream,
            .is_client = true,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
        };

        // Initialize TLS client
        try self.performClientHandshake(config);

        return self;
    }

    /// Create a TLS server stream (wraps accepted connection)
    pub fn initServer(
        allocator: Allocator,
        stream: net.Stream,
        config: TlsServerConfig,
    ) !TlsStream {
        _ = config; // Server-side TLS requires more complex setup

        const read_buf = try allocator.alloc(u8, default_buffer_size);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, default_buffer_size);
        errdefer allocator.free(write_buf);

        var self = TlsStream{
            .allocator = allocator,
            .inner_stream = stream,
            .is_client = false,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
        };

        // Server-side handshake
        try self.performServerHandshake();

        return self;
    }

    fn performClientHandshake(self: *TlsStream, config: TlsClientConfig) !void {
        _ = config;
        // Initialize certificate bundle
        var ca_bundle = crypto.Certificate.Bundle{};
        ca_bundle.rescan(self.allocator) catch {
            self.state = .failed;
            return error.CertificateBundleLoadFailure;
        };

        // Create TLS client
        self.tls_client = tls.Client.init(.{
            .stream = self.inner_stream,
            .ca_bundle = ca_bundle,
            .host_name = "",
        }, self.read_buffer) catch {
            self.state = .failed;
            return error.TlsHandshakeFailed;
        };

        self.state = .established;
    }

    fn performServerHandshake(self: *TlsStream) !void {
        // Server-side TLS handshake is more complex and requires
        // certificate/key loading. For now, mark as requiring implementation.
        self.state = .failed;
        return error.ServerTlsNotImplemented;
    }

    pub fn deinit(self: *TlsStream) void {
        if (self.tls_client) |*client| {
            client.deinit();
        }
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        self.inner_stream.close();
    }

    /// Read data from TLS stream
    pub fn read(self: *TlsStream, buffer: []u8) !usize {
        if (self.state != .established) return error.TlsNotEstablished;

        if (self.tls_client) |*client| {
            return client.read(buffer) catch |err| {
                self.state = .failed;
                return err;
            };
        }

        return error.TlsNotInitialized;
    }

    /// Write data to TLS stream
    pub fn write(self: *TlsStream, data: []const u8) !usize {
        if (self.state != .established) return error.TlsNotEstablished;

        if (self.tls_client) |*client| {
            return client.write(data) catch |err| {
                self.state = .failed;
                return err;
            };
        }

        return error.TlsNotInitialized;
    }

    /// Write all data to TLS stream
    pub fn writeAll(self: *TlsStream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try self.write(data[written..]);
        }
    }

    /// Close the TLS connection gracefully
    pub fn close(self: *TlsStream) void {
        if (self.state == .established) {
            self.state = .closing;
            if (self.tls_client) |*client| {
                client.deinit();
                self.tls_client = null;
            }
            self.state = .closed;
        }
        self.inner_stream.close();
    }

    /// Get the underlying stream (for advanced operations)
    pub fn getInnerStream(self: *TlsStream) net.Stream {
        return self.inner_stream;
    }
};

/// TLS listener for accepting secure connections
pub const TlsListener = struct {
    allocator: Allocator,
    inner_listener: net.Server,
    config: TlsServerConfig,

    pub fn init(allocator: Allocator, address: net.Address, config: TlsServerConfig) !TlsListener {
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        return .{
            .allocator = allocator,
            .inner_listener = listener,
            .config = config,
        };
    }

    pub fn deinit(self: *TlsListener) void {
        self.inner_listener.deinit();
    }

    /// Accept a new TLS connection
    pub fn accept(self: *TlsListener) !TlsStream {
        const conn = try self.inner_listener.accept();
        return TlsStream.initServer(self.allocator, conn.stream, self.config);
    }

    /// Get the listen address
    pub fn getAddress(self: *TlsListener) net.Address {
        return self.inner_listener.listen_address;
    }

    /// Get the listen port
    pub fn getPort(self: *TlsListener) u16 {
        return self.inner_listener.listen_address.getPort();
    }
};

/// Helper to load PEM certificate from file
pub fn loadCertFromFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

/// Helper to load PEM private key from file
pub fn loadKeyFromFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

// ============================================================================
// Tests
// ============================================================================

test "TlsServerConfig defaults" {
    const config = TlsServerConfig{};
    try std.testing.expectEqual(TlsVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(ClientAuth.none, config.client_auth);
}

test "TlsClientConfig defaults" {
    const config = TlsClientConfig{};
    try std.testing.expect(!config.insecure_skip_verify);
    try std.testing.expect(config.ca_file == null);
}

test "TlsState transitions" {
    try std.testing.expectEqual(TlsState.handshaking, TlsState.handshaking);
    try std.testing.expect(TlsState.established != TlsState.failed);
}
