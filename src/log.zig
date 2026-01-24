// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Debug Logging with Levels
//!
//! Structured logging for MCP server debugging and observability.
//! Supports multiple log levels and output formats.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Log levels in order of severity
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn toMcpLevel(self: Level) []const u8 {
        return switch (self) {
            .trace, .debug => "debug",
            .info => "info",
            .warn => "warning",
            .err, .fatal => "error",
        };
    }

    /// Convert to RFC 5424 syslog severity level name
    /// RFC 5424 defines: emergency, alert, critical, error, warning, notice, info, debug
    pub fn toRfc5424(self: Level) []const u8 {
        return switch (self) {
            .trace => "debug",
            .debug => "debug",
            .info => "info",
            .warn => "warning",
            .err => "error",
            .fatal => "critical",
        };
    }

    /// Convert to RFC 5424 numeric severity level (0-7)
    /// 0=Emergency, 1=Alert, 2=Critical, 3=Error, 4=Warning, 5=Notice, 6=Info, 7=Debug
    pub fn toRfc5424Numeric(self: Level) u3 {
        return switch (self) {
            .trace => 7, // Debug
            .debug => 7, // Debug
            .info => 6, // Informational
            .warn => 4, // Warning
            .err => 3, // Error
            .fatal => 2, // Critical
        };
    }

    /// Parse from RFC 5424 level name (case-insensitive matching)
    pub fn fromRfc5424(name: []const u8) ?Level {
        if (std.ascii.eqlIgnoreCase(name, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(name, "info") or std.ascii.eqlIgnoreCase(name, "informational")) return .info;
        if (std.ascii.eqlIgnoreCase(name, "notice")) return .info; // Map notice to info
        if (std.ascii.eqlIgnoreCase(name, "warning") or std.ascii.eqlIgnoreCase(name, "warn")) return .warn;
        if (std.ascii.eqlIgnoreCase(name, "error") or std.ascii.eqlIgnoreCase(name, "err")) return .err;
        if (std.ascii.eqlIgnoreCase(name, "critical") or std.ascii.eqlIgnoreCase(name, "crit")) return .fatal;
        if (std.ascii.eqlIgnoreCase(name, "alert")) return .fatal; // Map alert to fatal
        if (std.ascii.eqlIgnoreCase(name, "emergency") or std.ascii.eqlIgnoreCase(name, "emerg")) return .fatal;
        return null;
    }
};

/// Log output format
pub const Format = enum {
    /// Human-readable plain text
    text,
    /// JSON structured logs
    json,
    /// Compact single-line format
    compact,
};

/// Log field for structured logging
pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        boolean: bool,
    };
};

/// Logger configuration
pub const Config = struct {
    /// Minimum log level to output
    level: Level = .info,
    /// Output format
    format: Format = .text,
    /// Include timestamps
    timestamps: bool = true,
    /// Include source location
    source_location: bool = false,
    /// Output writer (null = stderr)
    writer: ?std.io.AnyWriter = null,
    /// Color output (for text format)
    color: bool = true,
};

// Static buffer for stderr logging (used when no writer is configured)
var stderr_buffer: [8192]u8 = undefined;

/// Logger instance
pub const Logger = struct {
    config: Config,
    allocator: Allocator,
    name: []const u8,

    /// Create a new logger
    pub fn init(allocator: Allocator, name: []const u8, config: Config) Logger {
        return .{
            .config = config,
            .allocator = allocator,
            .name = name,
        };
    }

    /// Create a child logger with a sub-name
    pub fn child(self: *const Logger, sub_name: []const u8) Logger {
        var new_name_buf: [256]u8 = undefined;
        const new_name = std.fmt.bufPrint(&new_name_buf, "{s}.{s}", .{ self.name, sub_name }) catch self.name;
        return .{
            .config = self.config,
            .allocator = self.allocator,
            .name = new_name,
        };
    }

    /// Log at trace level
    pub fn trace(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args, &.{});
    }

    /// Log at debug level
    pub fn debug(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args, &.{});
    }

    /// Log at info level
    pub fn info(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args, &.{});
    }

    /// Log at warn level
    pub fn warn(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args, &.{});
    }

    /// Log at error level
    pub fn err(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args, &.{});
    }

    /// Log at fatal level
    pub fn fatal(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args, &.{});
    }

    /// Log with structured fields
    pub fn logWithFields(
        self: *const Logger,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        self.log(level, fmt, args, fields);
    }

    fn log(
        self: *const Logger,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        // Check if level is enabled
        if (@intFromEnum(level) < @intFromEnum(self.config.level)) return;

        // Write to configured writer or stderr
        if (self.config.writer) |writer| {
            switch (self.config.format) {
                .text => self.writeText(writer, level, fmt, args, fields),
                .json => self.writeJson(writer, level, fmt, args, fields),
                .compact => self.writeCompact(writer, level, fmt, args, fields),
            }
        } else {
            // Fall back to std.debug.print for stderr
            self.writeToDebug(level, fmt, args, fields);
        }
    }

    fn writeToDebug(
        self: *const Logger,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        // Timestamp
        if (self.config.timestamps) {
            const ts = std.time.timestamp();
            std.debug.print("{d} ", .{ts});
        }

        // Level with optional color
        if (self.config.color) {
            const color = switch (level) {
                .trace => "\x1b[90m",
                .debug => "\x1b[36m",
                .info => "\x1b[32m",
                .warn => "\x1b[33m",
                .err => "\x1b[31m",
                .fatal => "\x1b[35m",
            };
            std.debug.print("{s}[{s}]\x1b[0m ", .{ color, level.toString() });
        } else {
            std.debug.print("[{s}] ", .{level.toString()});
        }

        // Logger name
        std.debug.print("{s}: ", .{self.name});

        // Message
        std.debug.print(fmt, args);

        // Fields
        for (fields) |field| {
            std.debug.print(" {s}=", .{field.key});
            switch (field.value) {
                .string => |s| std.debug.print("\"{s}\"", .{s}),
                .int => |i| std.debug.print("{d}", .{i}),
                .uint => |u| std.debug.print("{d}", .{u}),
                .float => |f| std.debug.print("{d}", .{f}),
                .boolean => |b| std.debug.print("{}", .{b}),
            }
        }

        std.debug.print("\n", .{});
    }

    fn writeText(
        self: *const Logger,
        writer: std.io.AnyWriter,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        // Timestamp
        if (self.config.timestamps) {
            const ts = std.time.timestamp();
            writer.print("{d} ", .{ts}) catch return;
        }

        // Level with optional color
        if (self.config.color) {
            const color = switch (level) {
                .trace => "\x1b[90m", // gray
                .debug => "\x1b[36m", // cyan
                .info => "\x1b[32m", // green
                .warn => "\x1b[33m", // yellow
                .err => "\x1b[31m", // red
                .fatal => "\x1b[35m", // magenta
            };
            writer.print("{s}[{s}]\x1b[0m ", .{ color, level.toString() }) catch return;
        } else {
            writer.print("[{s}] ", .{level.toString()}) catch return;
        }

        // Logger name
        writer.print("{s}: ", .{self.name}) catch return;

        // Message
        writer.print(fmt, args) catch return;

        // Fields
        for (fields) |field| {
            writer.print(" {s}=", .{field.key}) catch return;
            switch (field.value) {
                .string => |s| writer.print("\"{s}\"", .{s}) catch return,
                .int => |i| writer.print("{d}", .{i}) catch return,
                .uint => |u| writer.print("{d}", .{u}) catch return,
                .float => |f| writer.print("{d}", .{f}) catch return,
                .boolean => |b| writer.print("{}", .{b}) catch return,
            }
        }

        writer.writeByte('\n') catch return;
    }

    fn writeJson(
        self: *const Logger,
        writer: std.io.AnyWriter,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        writer.writeAll("{") catch return;

        // Timestamp
        if (self.config.timestamps) {
            const ts = std.time.timestamp();
            writer.print("\"ts\":{d},", .{ts}) catch return;
        }

        // Level and logger
        writer.print("\"level\":\"{s}\",\"logger\":\"{s}\",\"msg\":\"", .{
            level.toString(),
            self.name,
        }) catch return;

        // Message (escaped for JSON)
        var msg_buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch fmt;
        for (msg) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return,
                '\\' => writer.writeAll("\\\\") catch return,
                '\n' => writer.writeAll("\\n") catch return,
                '\r' => writer.writeAll("\\r") catch return,
                '\t' => writer.writeAll("\\t") catch return,
                else => writer.writeByte(c) catch return,
            }
        }
        writer.writeByte('"') catch return;

        // Fields
        for (fields) |field| {
            writer.print(",\"{s}\":", .{field.key}) catch return;
            switch (field.value) {
                .string => |s| {
                    writer.writeByte('"') catch return;
                    for (s) |c| {
                        switch (c) {
                            '"' => writer.writeAll("\\\"") catch return,
                            '\\' => writer.writeAll("\\\\") catch return,
                            '\n' => writer.writeAll("\\n") catch return,
                            else => writer.writeByte(c) catch return,
                        }
                    }
                    writer.writeByte('"') catch return;
                },
                .int => |i| writer.print("{d}", .{i}) catch return,
                .uint => |u| writer.print("{d}", .{u}) catch return,
                .float => |f| writer.print("{d}", .{f}) catch return,
                .boolean => |b| writer.print("{}", .{b}) catch return,
            }
        }

        writer.writeAll("}\n") catch return;
    }

    fn writeCompact(
        self: *const Logger,
        writer: std.io.AnyWriter,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
        fields: []const Field,
    ) void {
        // Simple format: LEVEL name msg field=value ...
        writer.print("{s} {s} ", .{ level.toString()[0..1], self.name }) catch return;
        writer.print(fmt, args) catch return;
        for (fields) |field| {
            writer.print(" {s}=", .{field.key}) catch return;
            switch (field.value) {
                .string => |s| writer.print("{s}", .{s}) catch return,
                .int => |i| writer.print("{d}", .{i}) catch return,
                .uint => |u| writer.print("{d}", .{u}) catch return,
                .float => |f| writer.print("{d}", .{f}) catch return,
                .boolean => |b| writer.print("{}", .{b}) catch return,
            }
        }
        writer.writeByte('\n') catch return;
    }
};

/// Global default logger
var global_logger: ?Logger = null;

/// Initialize global logger
pub fn initGlobal(allocator: Allocator, name: []const u8, config: Config) void {
    global_logger = Logger.init(allocator, name, config);
}

/// Get global logger
pub fn getGlobal() ?*Logger {
    if (global_logger) |*logger| {
        return logger;
    }
    return null;
}

/// Convenience functions using global logger
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.trace(fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.err(fmt, args);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    if (getGlobal()) |logger| logger.fatal(fmt, args);
}

/// Helper to create string field
pub fn str(key: []const u8, value: []const u8) Field {
    return .{ .key = key, .value = .{ .string = value } };
}

/// Helper to create int field
pub fn int(key: []const u8, value: i64) Field {
    return .{ .key = key, .value = .{ .int = value } };
}

/// Helper to create uint field
pub fn uint(key: []const u8, value: u64) Field {
    return .{ .key = key, .value = .{ .uint = value } };
}

/// Helper to create float field
pub fn float(key: []const u8, value: f64) Field {
    return .{ .key = key, .value = .{ .float = value } };
}

/// Helper to create boolean field
pub fn boolean(key: []const u8, value: bool) Field {
    return .{ .key = key, .value = .{ .boolean = value } };
}

// ============================================================================
// Tests
// ============================================================================

test "logger level filtering" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(std.testing.allocator, "test", .{
        .level = .warn,
        .format = .compact,
        .timestamps = false,
        .writer = fbs.writer().any(),
    });

    logger.debug("debug message", .{});
    logger.warn("warn message", .{});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "debug") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "warn") != null);
}

test "logger json format" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(std.testing.allocator, "test", .{
        .level = .info,
        .format = .json,
        .timestamps = false,
        .writer = fbs.writer().any(),
    });

    logger.info("test message", .{});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"INFO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"test message\"") != null);
}

test "logger with fields" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(std.testing.allocator, "test", .{
        .level = .info,
        .format = .text,
        .timestamps = false,
        .color = false,
        .writer = fbs.writer().any(),
    });

    logger.logWithFields(.info, "request", .{}, &.{
        str("method", "GET"),
        int("status", 200),
    });

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "method=\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "status=200") != null);
}

test "RFC 5424 level conversion" {
    // Test toRfc5424 string conversion
    try std.testing.expectEqualStrings("debug", Level.trace.toRfc5424());
    try std.testing.expectEqualStrings("debug", Level.debug.toRfc5424());
    try std.testing.expectEqualStrings("info", Level.info.toRfc5424());
    try std.testing.expectEqualStrings("warning", Level.warn.toRfc5424());
    try std.testing.expectEqualStrings("error", Level.err.toRfc5424());
    try std.testing.expectEqualStrings("critical", Level.fatal.toRfc5424());

    // Test toRfc5424Numeric
    try std.testing.expectEqual(@as(u3, 7), Level.trace.toRfc5424Numeric());
    try std.testing.expectEqual(@as(u3, 7), Level.debug.toRfc5424Numeric());
    try std.testing.expectEqual(@as(u3, 6), Level.info.toRfc5424Numeric());
    try std.testing.expectEqual(@as(u3, 4), Level.warn.toRfc5424Numeric());
    try std.testing.expectEqual(@as(u3, 3), Level.err.toRfc5424Numeric());
    try std.testing.expectEqual(@as(u3, 2), Level.fatal.toRfc5424Numeric());

    // Test fromRfc5424 parsing
    try std.testing.expectEqual(Level.debug, Level.fromRfc5424("debug").?);
    try std.testing.expectEqual(Level.info, Level.fromRfc5424("info").?);
    try std.testing.expectEqual(Level.info, Level.fromRfc5424("informational").?);
    try std.testing.expectEqual(Level.info, Level.fromRfc5424("notice").?);
    try std.testing.expectEqual(Level.warn, Level.fromRfc5424("warning").?);
    try std.testing.expectEqual(Level.warn, Level.fromRfc5424("warn").?);
    try std.testing.expectEqual(Level.err, Level.fromRfc5424("error").?);
    try std.testing.expectEqual(Level.fatal, Level.fromRfc5424("critical").?);
    try std.testing.expectEqual(Level.fatal, Level.fromRfc5424("alert").?);
    try std.testing.expectEqual(Level.fatal, Level.fromRfc5424("emergency").?);

    // Test case-insensitive matching
    try std.testing.expectEqual(Level.debug, Level.fromRfc5424("DEBUG").?);
    try std.testing.expectEqual(Level.warn, Level.fromRfc5424("WARNING").?);

    // Test unknown level
    try std.testing.expect(Level.fromRfc5424("unknown") == null);
}
