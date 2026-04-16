//! MCP Protocol Inspector CLI
//!
//! Debug tool to inspect MCP messages in real-time.
//!
//! Usage:
//!   mcp-inspect [options]
//!
//! Options:
//!   --stdin         Read from stdin (default)
//!   --file <path>   Read from file
//!   --format <fmt>  Output format: pretty, json, compact (default: pretty)
//!   --filter <type> Filter by message type: request, response, notification
//!   --help          Show help

const std = @import("std");
const json = @import("json");

/// Zig 0.15 compatible byte reader - takes mutable pointer to interface
fn readOneByte(reader: *std.Io.Reader) !u8 {
    var buf: [1]u8 = undefined;
    const n = reader.readSliceShort(&buf) catch |err| return err;
    if (n == 0) return error.EndOfStream;
    return buf[0];
}

const Config = struct {
    input: Input = .stdin,
    format: Format = .pretty,
    filter: ?Filter = null,
    file_path: ?[]const u8 = null,
};

const Input = enum {
    stdin,
    file,
};

const Format = enum {
    pretty,
    json,
    compact,
};

const Filter = enum {
    request,
    response,
    notification,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(argv) catch {
        printUsage();
        return;
    };

    // Open input source
    var file: ?std.Io.File = null;
    var input_file: std.Io.File = undefined;
    var read_buf: [4096]u8 = undefined;

    switch (config.input) {
        .stdin => {
            input_file = std.Io.File.stdin();
        },
        .file => {
            if (config.file_path) |path| {
                file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
                input_file = file.?;
            } else {
                std.debug.print("Error: --file requires a path\n", .{});
                return;
            }
        },
    }
    defer if (file) |f| f.close(init.io);

    var reader = input_file.reader(init.io, &read_buf);

    std.debug.print("MCP Protocol Inspector\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Waiting for messages...\n\n", .{});

    // Read and process messages line by line
    var line_buf: [65536]u8 = undefined;
    var msg_count: usize = 0;

    while (true) {
        var line_len: usize = 0;
        while (true) {
            const byte = readOneByte(&reader.interface) catch |err| {
                if (err == error.EndOfStream) {
                    if (line_len > 0) break; // Process last line if any
                    std.debug.print("\nProcessed {d} messages\n", .{msg_count});
                    return;
                }
                continue;
            };
            if (byte == '\n') break;
            if (line_len < line_buf.len) {
                line_buf[line_len] = byte;
                line_len += 1;
            }
        }

        const line = line_buf[0..line_len];
        if (line.len == 0) continue;

        msg_count += 1;

        // Parse JSON
        var err_info = json.ParseError.init();
        var doc = json.parse(allocator, line, .{}, &err_info) catch {
            std.debug.print("#{d} [PARSE ERROR] Invalid JSON at line {d}, col {d}\n", .{
                msg_count,
                err_info.line,
                err_info.col,
            });
            continue;
        };
        defer doc.deinit();

        // Determine message type
        const msg_type = classifyMessage(doc.root);

        // Apply filter
        if (config.filter) |f| {
            if (msg_type != f) continue;
        }

        // Output based on format
        switch (config.format) {
            .pretty => outputPretty(msg_count, msg_type, doc.root, allocator),
            .json => outputJson(line),
            .compact => outputCompact(msg_count, msg_type, doc.root),
        }
    }
}

fn classifyMessage(root: json.Value) Filter {
    switch (root) {
        .obj => |members| {
            var has_id = false;
            var has_method = false;
            var has_result = false;
            var has_error = false;

            for (members) |m| {
                if (std.mem.eql(u8, m.k, "id")) has_id = true;
                if (std.mem.eql(u8, m.k, "method")) has_method = true;
                if (std.mem.eql(u8, m.k, "result")) has_result = true;
                if (std.mem.eql(u8, m.k, "error")) has_error = true;
            }

            if (has_id and (has_result or has_error)) return .response;
            if (has_id and has_method) return .request;
            if (has_method and !has_id) return .notification;
            return .request;
        },
        else => return .request,
    }
}

fn outputPretty(num: usize, msg_type: Filter, root: json.Value, allocator: std.mem.Allocator) void {
    _ = allocator;
    const type_str = switch (msg_type) {
        .request => "\x1b[34mREQUEST\x1b[0m",
        .response => "\x1b[32mRESPONSE\x1b[0m",
        .notification => "\x1b[33mNOTIFICATION\x1b[0m",
    };

    std.debug.print("#{d} [{s}]\n", .{ num, type_str });

    switch (root) {
        .obj => |members| {
            for (members) |m| {
                std.debug.print("  {s}: ", .{m.k});
                printValue(m.v, 2);
                std.debug.print("\n", .{});
            }
        },
        else => {
            std.debug.print("  (not an object)\n", .{});
        },
    }
    std.debug.print("\n", .{});
}

fn printValue(value: json.Value, indent: usize) void {
    _ = indent;
    switch (value) {
        .null => std.debug.print("null", .{}),
        .bool => |b| std.debug.print("{}", .{b}),
        .num => |n| std.debug.print("{s}", .{n.lexeme}),
        .str => |s| {
            if (s.len > 80) {
                std.debug.print("\"{s}...\" ({d} chars)", .{ s[0..77], s.len });
            } else {
                std.debug.print("\"{s}\"", .{s});
            }
        },
        .arr => |arr| {
            if (arr.len == 0) {
                std.debug.print("[]", .{});
            } else if (arr.len <= 3) {
                std.debug.print("[", .{});
                for (arr, 0..) |elem, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    printValue(elem, 0);
                }
                std.debug.print("]", .{});
            } else {
                std.debug.print("[...] ({d} items)", .{arr.len});
            }
        },
        .obj => |members| {
            if (members.len == 0) {
                std.debug.print("{{}}", .{});
            } else if (members.len <= 2) {
                std.debug.print("{{", .{});
                for (members, 0..) |m, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}: ", .{m.k});
                    printValue(m.v, 0);
                }
                std.debug.print("}}", .{});
            } else {
                std.debug.print("{{...}} ({d} keys)", .{members.len});
            }
        },
    }
}

fn outputJson(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}

fn outputCompact(num: usize, msg_type: Filter, root: json.Value) void {
    const type_char: u8 = switch (msg_type) {
        .request => 'Q',
        .response => 'R',
        .notification => 'N',
    };

    std.debug.print("{d} {c} ", .{ num, type_char });

    // Extract key fields
    switch (root) {
        .obj => |members| {
            for (members) |m| {
                if (std.mem.eql(u8, m.k, "id")) {
                    switch (m.v) {
                        .num => |n| std.debug.print("id={s} ", .{n.lexeme}),
                        .str => |s| std.debug.print("id={s} ", .{s}),
                        else => {},
                    }
                } else if (std.mem.eql(u8, m.k, "method")) {
                    if (m.v == .str) {
                        std.debug.print("method={s} ", .{m.v.str});
                    }
                } else if (std.mem.eql(u8, m.k, "error")) {
                    std.debug.print("ERROR ", .{});
                }
            }
        },
        else => {},
    }

    std.debug.print("\n", .{});
}

fn parseArgs(argv: []const [:0]const u8) !Config {
    var config = Config{};
    var arg_idx: usize = 1; // skip program name

    while (arg_idx < argv.len) : (arg_idx += 1) {
        const arg = argv[arg_idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            config.input = .stdin;
        } else if (std.mem.eql(u8, arg, "--file")) {
            config.input = .file;
            arg_idx += 1;
            if (arg_idx < argv.len) config.file_path = argv[arg_idx];
        } else if (std.mem.eql(u8, arg, "--format")) {
            arg_idx += 1;
            if (arg_idx < argv.len) {
                const fmt = argv[arg_idx];
                if (std.mem.eql(u8, fmt, "pretty")) {
                    config.format = .pretty;
                } else if (std.mem.eql(u8, fmt, "json")) {
                    config.format = .json;
                } else if (std.mem.eql(u8, fmt, "compact")) {
                    config.format = .compact;
                }
            }
        } else if (std.mem.eql(u8, arg, "--filter")) {
            arg_idx += 1;
            if (arg_idx < argv.len) {
                const f = argv[arg_idx];
                if (std.mem.eql(u8, f, "request")) {
                    config.filter = .request;
                } else if (std.mem.eql(u8, f, "response")) {
                    config.filter = .response;
                } else if (std.mem.eql(u8, f, "notification")) {
                    config.filter = .notification;
                }
            }
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\MCP Protocol Inspector
        \\
        \\Usage: mcp-inspect [options]
        \\
        \\Options:
        \\  --stdin           Read from stdin (default)
        \\  --file <path>     Read from file
        \\  --format <fmt>    Output format: pretty, json, compact (default: pretty)
        \\  --filter <type>   Filter: request, response, notification
        \\  --help, -h        Show this help
        \\
        \\Examples:
        \\  cat messages.jsonl | mcp-inspect
        \\  mcp-inspect --file log.jsonl --format compact
        \\  mcp-inspect --filter notification
        \\
    ;
    std.debug.print("{s}", .{usage});
}
