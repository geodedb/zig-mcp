//! Authentication Example
//!
//! This example demonstrates the authentication options available in MCP:
//! - Bearer token authentication
//! - Basic authentication
//! - OAuth 2.1 support
//!
//! To run this example:
//!   zig build run-example-auth
//!
//! Test with curl:
//!   # Without auth (will fail with 401)
//!   curl -X POST http://localhost:8080/mcp \
//!     -H "Content-Type: application/json" \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
//!
//!   # With Bearer token
//!   curl -X POST http://localhost:8080/mcp \
//!     -H "Content-Type: application/json" \
//!     -H "Authorization: Bearer my-secret-token-12345" \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
//!
//!   # With Basic auth
//!   curl -X POST http://localhost:8080/mcp \
//!     -H "Content-Type: application/json" \
//!     -u admin:secretpassword \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'

const std = @import("std");
const mcp = @import("mcp");

/// The server frees every slice a handler callback returns, using the
/// allocator the server was built with (see "Result Ownership" on
/// `mcp.Handler`). Callbacks therefore return copies made with that same
/// allocator, never string literals. `main` sets this before serving.
var result_allocator: std.mem.Allocator = undefined;

/// Returns a server-owned copy of `text`.
fn owned(text: []const u8) ![]const u8 {
    return result_allocator.dupe(u8, text);
}

/// Example 1: Bearer Token Authentication
/// The simplest form of authentication - client sends a token in the Authorization header
fn runBearerServer(allocator: std.mem.Allocator) !void {
    const handler = createMinimalHandler();

    var server = try mcp.Server.init(allocator, .{
        .name = "bearer-auth-server",
        .version = "1.0.0",

        // Enable bearer token authentication
        .auth_mode = .bearer,

        // The token that clients must provide
        // In production, use a secure, randomly generated token
        .bearer_token = "my-secret-token-12345",

        // HTTP configuration
        .http_port = 8080,
    }, handler);
    defer server.deinit();

    const port = try server.serveHttp();
    std.debug.print("Bearer Auth Server running on port {d}\n", .{port});
    std.debug.print("Use header: Authorization: Bearer my-secret-token-12345\n\n", .{});

    // Keep running
    while (true) {
        std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
}

/// Example 2: Basic Authentication
/// Uses username:password encoded in the Authorization header
fn runBasicServer(allocator: std.mem.Allocator) !void {
    const handler = createMinimalHandler();

    var server = try mcp.Server.init(allocator, .{
        .name = "basic-auth-server",
        .version = "1.0.0",

        // Enable basic authentication
        .auth_mode = .basic,

        // Credentials that clients must provide
        .basic_user = "admin",
        .basic_pass = "secretpassword",

        .http_port = 8081,
    }, handler);
    defer server.deinit();

    const port = try server.serveHttp();
    std.debug.print("Basic Auth Server running on port {d}\n", .{port});
    std.debug.print("Username: admin, Password: secretpassword\n\n", .{});

    while (true) {
        std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
}

/// Example 3: OAuth 2.1 Authentication
/// Full OAuth 2.1 flow with automatic discovery endpoints
fn runOAuthServer(allocator: std.mem.Allocator) !void {
    const handler = createMinimalHandler();

    var server = try mcp.Server.init(allocator, .{
        .name = "oauth-auth-server",
        .version = "1.0.0",

        // Enable OAuth 2.1 authentication
        .auth_mode = .oauth2,

        // OAuth configuration
        .oauth_dynamic_registration = true, // Enable dynamic client registration
        .oauth_resource_uri = "urn:example:mcp-server", // RFC 8707 resource indicator

        .http_port = 8082,
    }, handler);
    defer server.deinit();

    const port = try server.serveHttp();
    std.debug.print("OAuth 2.1 Server running on port {d}\n", .{port});
    std.debug.print("\nOAuth Endpoints:\n", .{});
    std.debug.print("  Discovery: http://localhost:{d}/.well-known/oauth-authorization-server\n", .{port});
    std.debug.print("  Authorize: http://localhost:{d}/mcp/authorize\n", .{port});
    std.debug.print("  Token:     http://localhost:{d}/mcp/token\n", .{port});
    std.debug.print("  Register:  http://localhost:{d}/mcp/register\n\n", .{port});

    while (true) {
        std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    result_allocator = allocator;

    // Parse command line to determine which auth mode to demo
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const mode: []const u8 = if (argv.len > 1) argv[1] else "bearer";

    std.debug.print("\n=== MCP Authentication Example ===\n\n", .{});

    if (std.mem.eql(u8, mode, "bearer")) {
        std.debug.print("Starting Bearer Token authentication server...\n\n", .{});
        try runBearerServer(allocator);
    } else if (std.mem.eql(u8, mode, "basic")) {
        std.debug.print("Starting Basic authentication server...\n\n", .{});
        try runBasicServer(allocator);
    } else if (std.mem.eql(u8, mode, "oauth")) {
        std.debug.print("Starting OAuth 2.1 authentication server...\n\n", .{});
        try runOAuthServer(allocator);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: 05_authentication [mode]
        \\
        \\Modes:
        \\  bearer   Start server with bearer token auth (default)
        \\  basic    Start server with basic auth
        \\  oauth    Start server with OAuth 2.1 auth
        \\
        \\Examples:
        \\  ./05_authentication bearer
        \\  ./05_authentication basic
        \\  ./05_authentication oauth
        \\
    , .{});
}

// ============================================================================
// Minimal Handler
// ============================================================================

fn createMinimalHandler() mcp.Handler {
    return .{
        .ctx = null,
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

fn listTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned(
        \\{"tools":[{"name":"whoami","description":"Returns information about the authenticated session","inputSchema":{"type":"object","properties":{}}}]}
    );
}

fn callTool(_: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
    if (std.mem.eql(u8, name, "whoami")) {
        return owned(
            \\{"content":[{"type":"text","text":"You are authenticated! Session info would appear here."}]}
        );
    }
    return error.ToolNotFound;
}

fn listResources(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned("{\"resources\":[]}");
}

fn readResource(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return error.ResourceNotFound;
}

fn listResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    return owned("{\"resourceTemplates\":[]}");
}

fn subscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn unsubscribeResource(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn listPrompts(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned("{\"prompts\":[]}");
}

fn getPrompt(_: ?*anyopaque, _: []const u8, _: ?[]const u8) anyerror![]const u8 {
    return error.PromptNotFound;
}

fn complete(_: ?*anyopaque, _: []const u8) anyerror![]const u8 {
    return owned("{\"completion\":{\"values\":[]}}");
}

fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
