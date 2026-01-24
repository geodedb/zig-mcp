//! MCP Test Client CLI
//!
//! CLI client for testing MCP servers interactively.
//!
//! Usage:
//!   mcp-client [options] [command]
//!
//! Options:
//!   --stdio           Connect via stdio (spawn process)
//!   --http <url>      Connect via HTTP
//!   --command <cmd>   Command to spawn (with --stdio)
//!   --help            Show help
//!
//! Commands:
//!   init              Send initialize request
//!   tools             List available tools
//!   call <name>       Call a tool
//!   resources         List resources
//!   prompts           List prompts
//!   ping              Send ping request

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
    transport: Transport = .stdio,
    http_url: ?[]const u8 = null,
    spawn_command: ?[]const u8 = null,
};

const Transport = enum {
    stdio,
    http,
};

var next_id: i64 = 1;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // Skip program name

    var config = Config{};
    var command: ?[]const u8 = null;
    var extra_args = std.ArrayListUnmanaged([]const u8){};
    defer extra_args.deinit(allocator);

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            config.transport = .stdio;
        } else if (std.mem.eql(u8, arg, "--http")) {
            config.transport = .http;
            config.http_url = args.next();
        } else if (std.mem.eql(u8, arg, "--command")) {
            config.spawn_command = args.next();
        } else if (arg[0] != '-') {
            if (command == null) {
                command = arg;
            } else {
                try extra_args.append(allocator, arg);
            }
        }
    }

    std.debug.print("MCP Test Client\n", .{});
    std.debug.print("===============\n\n", .{});

    // If a command was specified, execute it
    if (command) |cmd| {
        try executeCommand(allocator, cmd, extra_args.items);
        return;
    }

    // Interactive mode
    std.debug.print("Interactive mode. Type 'help' for commands, 'quit' to exit.\n\n", .{});

    const stdin_file = std.fs.File.stdin();
    var line_buf: [4096]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = stdin_file.reader(&read_buf);

    while (true) {
        std.debug.print("> ", .{});

        var line_len: usize = 0;
        while (true) {
            const byte = readOneByte(&reader.interface) catch |err| {
                if (err == error.EndOfStream) {
                    std.debug.print("\nGoodbye!\n", .{});
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

        // Parse command
        var parts = std.mem.splitScalar(u8, line, ' ');
        const cmd = parts.next() orelse continue;
        var cmd_args = std.ArrayListUnmanaged([]const u8){};
        defer cmd_args.deinit(allocator);
        while (parts.next()) |part| {
            try cmd_args.append(allocator, part);
        }

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit")) {
            break;
        }

        if (std.mem.eql(u8, cmd, "help")) {
            printInteractiveHelp();
            continue;
        }

        executeCommand(allocator, cmd, cmd_args.items) catch |err| {
            std.debug.print("Error: {}\n", .{err});
        };
    }

    std.debug.print("\nGoodbye!\n", .{});
}

fn executeCommand(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    args: []const []const u8,
) !void {
    if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator);
    } else if (std.mem.eql(u8, cmd, "ping")) {
        try cmdPing(allocator);
    } else if (std.mem.eql(u8, cmd, "tools")) {
        try cmdListTools(allocator);
    } else if (std.mem.eql(u8, cmd, "resources")) {
        try cmdListResources(allocator);
    } else if (std.mem.eql(u8, cmd, "prompts")) {
        try cmdListPrompts(allocator);
    } else if (std.mem.eql(u8, cmd, "call")) {
        if (args.len < 1) {
            std.debug.print("Usage: call <tool-name> [args-json]\n", .{});
            return;
        }
        const tool_name = args[0];
        const tool_args = if (args.len > 1) args[1] else "{}";
        try cmdCallTool(allocator, tool_name, tool_args);
    } else if (std.mem.eql(u8, cmd, "raw")) {
        if (args.len < 1) {
            std.debug.print("Usage: raw <json-rpc-request>\n", .{});
            return;
        }
        cmdRaw(args[0]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
        std.debug.print("Type 'help' for available commands.\n", .{});
    }
}

fn cmdInit(allocator: std.mem.Allocator) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"protocolVersion":"2025-11-25","capabilities":{{}},"clientInfo":{{"name":"mcp-client","version":"1.0.0"}}}}}}
    , .{id});
    defer allocator.free(request);

    std.debug.print("Sending initialize request...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
    std.debug.print("\n(Note: In a real implementation, this would be sent to the server)\n", .{});
}

fn cmdPing(allocator: std.mem.Allocator) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"ping"}}
    , .{id});
    defer allocator.free(request);

    std.debug.print("Sending ping...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
}

fn cmdListTools(allocator: std.mem.Allocator) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/list"}}
    , .{id});
    defer allocator.free(request);

    std.debug.print("Listing tools...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
}

fn cmdListResources(allocator: std.mem.Allocator) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"resources/list"}}
    , .{id});
    defer allocator.free(request);

    std.debug.print("Listing resources...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
}

fn cmdListPrompts(allocator: std.mem.Allocator) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/list"}}
    , .{id});
    defer allocator.free(request);

    std.debug.print("Listing prompts...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
}

fn cmdCallTool(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) !void {
    const id = getNextId();
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ id, name, args_json });
    defer allocator.free(request);

    std.debug.print("Calling tool '{s}'...\n", .{name});
    std.debug.print("Request: {s}\n", .{request});
}

fn cmdRaw(request: []const u8) void {
    std.debug.print("Sending raw request...\n", .{});
    std.debug.print("Request: {s}\n", .{request});
}

fn getNextId() i64 {
    const id = next_id;
    next_id += 1;
    return id;
}

fn printUsage() void {
    const usage =
        \\MCP Test Client
        \\
        \\Usage: mcp-client [options] [command]
        \\
        \\Options:
        \\  --stdio           Connect via stdio (spawn process)
        \\  --http <url>      Connect via HTTP
        \\  --command <cmd>   Command to spawn (with --stdio)
        \\  --help, -h        Show this help
        \\
        \\Commands:
        \\  init              Send initialize request
        \\  ping              Send ping request
        \\  tools             List available tools
        \\  call <name> [args] Call a tool
        \\  resources         List resources
        \\  prompts           List prompts
        \\  raw <json>        Send raw JSON-RPC request
        \\
        \\Without a command, enters interactive mode.
        \\
        \\Examples:
        \\  mcp-client init
        \\  mcp-client tools
        \\  mcp-client call echo '{"message":"hello"}'
        \\  mcp-client --http http://localhost:8080/mcp
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printInteractiveHelp() void {
    const help =
        \\Available commands:
        \\  init              Send initialize request
        \\  ping              Send ping request
        \\  tools             List available tools
        \\  call <name> [args] Call a tool
        \\  resources         List resources
        \\  prompts           List prompts
        \\  raw <json>        Send raw JSON-RPC request
        \\  help              Show this help
        \\  quit/exit         Exit the client
        \\
    ;
    std.debug.print("{s}", .{help});
}
