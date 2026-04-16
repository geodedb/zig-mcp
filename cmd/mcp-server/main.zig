//! MCP Server Runner CLI
//!
//! Standalone executable to run MCP servers with various configurations.
//!
//! Usage:
//!   mcp-server [options]
//!
//! Options:
//!   --stdio         Use stdio transport (default)
//!   --http          Use HTTP/SSE transport
//!   --port <port>   HTTP port (default: 8080)
//!   --host <host>   HTTP host (default: 127.0.0.1)
//!   --name <name>   Server name
//!   --version <ver> Server version
//!   --help          Show help
//!   --verbose       Enable verbose logging

const std = @import("std");
const mcp = @import("mcp");
const log = @import("log");

const Config = struct {
    transport: Transport = .stdio,
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    name: []const u8 = "mcp-server",
    version: []const u8 = "1.0.0",
    verbose: bool = false,
};

const Transport = enum {
    stdio,
    http,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse command line arguments
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(argv) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        printUsage();
        return;
    };

    // Initialize logger
    log.initGlobal(allocator, "mcp-server", .{
        .level = if (config.verbose) .debug else .info,
        .format = .text,
        .color = true,
    });

    log.info("Starting MCP server: {s} v{s}", .{ config.name, config.version });

    // Create handler (demo implementation)
    const handler = createDemoHandler();

    // Create server
    var server = try mcp.Server.init(allocator, .{
        .name = config.name,
        .version = config.version,
        .http_bind = config.host,
        .http_port = config.port,
    }, handler);
    defer server.deinit();

    // Start appropriate transport
    switch (config.transport) {
        .stdio => {
            log.info("Using stdio transport", .{});
            try server.serveStdio();
        },
        .http => {
            const actual_port = try server.serveHttp();
            log.info("HTTP server listening on {s}:{d}", .{ config.host, actual_port });

            // Wait for interrupt
            std.debug.print("Press Ctrl+C to stop\n", .{});
            while (true) {
                std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            }
        },
    }
}

fn parseArgs(argv: []const [:0]const u8) !Config {
    var config = Config{};

    var arg_idx: usize = 1; // skip program name
    while (arg_idx < argv.len) : (arg_idx += 1) {
        const arg = argv[arg_idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            config.transport = .stdio;
        } else if (std.mem.eql(u8, arg, "--http")) {
            config.transport = .http;
        } else if (std.mem.eql(u8, arg, "--port")) {
            {
                arg_idx += 1;
                if (arg_idx < argv.len) config.port = std.fmt.parseInt(u16, argv[arg_idx], 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            {
                arg_idx += 1;
                if (arg_idx < argv.len) config.host = argv[arg_idx];
            }
        } else if (std.mem.eql(u8, arg, "--name")) {
            {
                arg_idx += 1;
                if (arg_idx < argv.len) config.name = argv[arg_idx];
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            {
                arg_idx += 1;
                if (arg_idx < argv.len) config.version = argv[arg_idx];
            }
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\MCP Server Runner
        \\
        \\Usage: mcp-server [options]
        \\
        \\Options:
        \\  --stdio         Use stdio transport (default)
        \\  --http          Use HTTP/SSE transport
        \\  --port <port>   HTTP port (default: 8080)
        \\  --host <host>   HTTP host (default: 127.0.0.1)
        \\  --name <name>   Server name (default: mcp-server)
        \\  --version <ver> Server version (default: 1.0.0)
        \\  --verbose, -v   Enable verbose logging
        \\  --help, -h      Show this help
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn createDemoHandler() mcp.Handler {
    return .{
        .listTools = demoListTools,
        .callTool = demoCallTool,
        .listResources = demoListResources,
        .readResource = demoReadResource,
        .listResourceTemplates = demoListResourceTemplates,
        .subscribeResource = demoSubscribeResource,
        .unsubscribeResource = demoUnsubscribeResource,
        .listPrompts = demoListPrompts,
        .getPrompt = demoGetPrompt,
        .complete = demoComplete,
        .setLogLevel = demoSetLogLevel,
    };
}

fn demoListTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo the input\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}}}}]}";
}

fn demoCallTool(_: ?*anyopaque, name: []const u8, args: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
    _ = name;
    _ = args;
    return "{\"content\":[{\"type\":\"text\",\"text\":\"Echo: demo response\"}]}";
}

fn demoListResources(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"resources\":[]}";
}

fn demoReadResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return "{\"contents\":[{\"type\":\"text\",\"text\":\"Resource content\"}]}";
}

fn demoListResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    return "{\"resourceTemplates\":[]}";
}

fn demoSubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn demoUnsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn demoListPrompts(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return "{\"prompts\":[]}";
}

fn demoGetPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return "{\"messages\":[]}";
}

fn demoComplete(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return "{\"completion\":{\"values\":[]}}";
}

fn demoSetLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
