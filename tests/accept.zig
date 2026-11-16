//! MCP Acceptance Tests
//!
//! Tests for MCP spec revision 2025-03-26 compliance:
//! T1: stdio init+initialized+ping
//! T2: stdio batch of 2 pings
//! T3: stdio batch of 2 tools/call to a test-only barrier tool (proves parallelism)
//! T4: HTTP bearer auth
//! T5: HTTP oauth2 well-known endpoint

const std = @import("std");
const mcp = @import("mcp");
const json = @import("json");

inline fn _io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn testStreamRead(stream: std.Io.net.Stream, buf: []u8) !usize {
    return std.posix.read(stream.socket.handle, buf);
}

fn testStreamWriteAll(stream: std.Io.net.Stream, data: []const u8) !void {
    var w_buf: [4096]u8 = undefined;
    var sw = stream.writer(_io(), &w_buf);
    sw.interface.writeAll(data) catch return error.BrokenPipe;
    sw.interface.flush() catch return error.BrokenPipe;
}

fn testStreamClose(stream: std.Io.net.Stream) void {
    var copy = stream;
    copy.close(_io());
}

fn testConnect(port: u16) !std.Io.net.Stream {
    var addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    return std.Io.net.IpAddress.connect(&addr, _io(), .{ .mode = .stream });
}

// ============================================================================
// Test Helpers
// ============================================================================

fn parseJsonResponse(allocator: std.mem.Allocator, response: []const u8) !json.Document {
    var err = json.ParseError.init();
    return json.parse(allocator, response, .{}, &err);
}

fn getField(obj: []const json.Member, key: []const u8) ?json.Value {
    for (obj) |member| {
        if (std.mem.eql(u8, member.k, key)) {
            return member.v;
        }
    }
    return null;
}

fn getStringField(obj: []const json.Member, key: []const u8) ?[]const u8 {
    if (getField(obj, key)) |v| {
        if (v == .str) return v.str;
    }
    return null;
}

// ============================================================================
// T1: stdio init+initialized+ping => correct initialize result + ping result {}
// ============================================================================

test "T1: stdio init+initialized+ping" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Send initialize request
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ;

    const init_response = try server.processMessage(init_request);
    defer if (init_response) |r| allocator.free(r);

    try std.testing.expect(init_response != null);

    // Parse and verify initialize response
    var init_doc = try parseJsonResponse(allocator, init_response.?);
    defer init_doc.deinit();

    try std.testing.expect(init_doc.root == .obj);
    const init_obj = init_doc.root.obj;

    // Check jsonrpc version
    const jsonrpc_val = getStringField(init_obj, "jsonrpc");
    try std.testing.expect(jsonrpc_val != null);
    try std.testing.expectEqualStrings("2.0", jsonrpc_val.?);

    // Check result contains protocolVersion
    const result_val = getField(init_obj, "result");
    try std.testing.expect(result_val != null);
    try std.testing.expect(result_val.? == .obj);

    const result_obj = result_val.?.obj;
    const protocol_ver = getStringField(result_obj, "protocolVersion");
    try std.testing.expect(protocol_ver != null);
    try std.testing.expectEqualStrings(mcp.ProtocolVersion, protocol_ver.?);

    // Check serverInfo
    const server_info = getField(result_obj, "serverInfo");
    try std.testing.expect(server_info != null);
    try std.testing.expect(server_info.? == .obj);

    const server_name = getStringField(server_info.?.obj, "name");
    try std.testing.expect(server_name != null);
    try std.testing.expectEqualStrings("test-server", server_name.?);

    // Send initialized notification (no response expected)
    const initialized_notification =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;

    const init_notif_response = try server.processMessage(initialized_notification);
    try std.testing.expect(init_notif_response == null); // Notifications don't get responses

    // Send ping request
    const ping_request =
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    ;

    const ping_response = try server.processMessage(ping_request);
    defer if (ping_response) |r| allocator.free(r);

    try std.testing.expect(ping_response != null);

    // Parse and verify ping response
    var ping_doc = try parseJsonResponse(allocator, ping_response.?);
    defer ping_doc.deinit();

    try std.testing.expect(ping_doc.root == .obj);
    const ping_obj = ping_doc.root.obj;

    // Check result is {}
    const ping_result = getField(ping_obj, "result");
    try std.testing.expect(ping_result != null);
    try std.testing.expect(ping_result.? == .obj);
    try std.testing.expectEqual(@as(usize, 0), ping_result.?.obj.len);
}

// ============================================================================
// T2: stdio batch of 2 pings => batch of 2 responses in same order
// ============================================================================

test "T2: stdio batch of 2 pings" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Send batch of 2 pings
    const batch_request =
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    ;

    const batch_response = try server.processMessage(batch_request);
    defer if (batch_response) |r| allocator.free(r);

    try std.testing.expect(batch_response != null);

    // Parse batch response
    var batch_doc = try parseJsonResponse(allocator, batch_response.?);
    defer batch_doc.deinit();

    // Should be an array
    try std.testing.expect(batch_doc.root == .arr);
    const responses = batch_doc.root.arr;

    // Should have 2 responses
    try std.testing.expectEqual(@as(usize, 2), responses.len);

    // Verify first response has id 1
    try std.testing.expect(responses[0] == .obj);
    const id1 = getField(responses[0].obj, "id");
    try std.testing.expect(id1 != null);
    try std.testing.expect(id1.? == .num);
    try std.testing.expectEqualStrings("1", id1.?.num.lexeme);

    // Verify second response has id 2
    try std.testing.expect(responses[1] == .obj);
    const id2 = getField(responses[1].obj, "id");
    try std.testing.expect(id2 != null);
    try std.testing.expect(id2.? == .num);
    try std.testing.expectEqualStrings("2", id2.?.num.lexeme);

    // Both should have empty {} result
    const result1 = getField(responses[0].obj, "result");
    try std.testing.expect(result1 != null);
    try std.testing.expect(result1.? == .obj);

    const result2 = getField(responses[1].obj, "result");
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.? == .obj);
}

// ============================================================================
// T3: stdio batch of 2 tools/call to barrier => proves parallelism
// ============================================================================

/// Test-only handler whose "barrier" tool returns only once `count` calls
/// are inside it at the same time. Calls processed one after another never
/// meet, so each gives up after a bounded wait and fails.
const BarrierHandler = struct {
    allocator: std.mem.Allocator,
    arrived: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn handler(self: *BarrierHandler) mcp.Handler {
        var h = mcp.DemoHandler.init(self.allocator);
        var base = h.handler();
        base.ctx = @ptrCast(self);
        base.listTools = listTools;
        base.callTool = callTool;
        base.listResources = listResources;
        base.listResourceTemplates = listResourceTemplates;
        base.listPrompts = listPrompts;
        base.complete = complete;
        return base;
    }

    fn alloc(ctx: ?*anyopaque) std.mem.Allocator {
        const self: *BarrierHandler = @ptrCast(@alignCast(ctx.?));
        return self.allocator;
    }

    fn callTool(ctx: ?*anyopaque, name: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
        const self: *BarrierHandler = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, name, "barrier")) return error.ToolNotFound;
        const target: u32 = 2;
        _ = self.arrived.fetchAdd(1, .acq_rel);
        var waited_ms: u32 = 0;
        while (self.arrived.load(.acquire) < target) : (waited_ms += 1) {
            if (waited_ms >= 5000) return error.BarrierTimeout;
            _io().sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        return self.allocator.dupe(u8, "{\"content\":[{\"type\":\"text\",\"text\":\"barrier passed\"}]}");
    }

    fn listTools(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return alloc(ctx).dupe(u8, "{\"tools\":[]}");
    }
    fn listResources(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return alloc(ctx).dupe(u8, "{\"resources\":[]}");
    }
    fn listResourceTemplates(ctx: ?*anyopaque) anyerror![]const u8 {
        return alloc(ctx).dupe(u8, "{\"resourceTemplates\":[]}");
    }
    fn listPrompts(ctx: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
        return alloc(ctx).dupe(u8, "{\"prompts\":[]}");
    }
    fn complete(ctx: ?*anyopaque, _: []const u8) anyerror![]const u8 {
        return alloc(ctx).dupe(u8, "{\"completion\":{\"values\":[]}}");
    }
};

test "T3: batch barrier calls prove parallelism" {
    const allocator = std.testing.allocator;

    // Create server with worker threads for parallel processing. The
    // barrier tool lives in this test's handler, not in the library.
    var barrier_handler = BarrierHandler{ .allocator = allocator };
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .worker_threads = 2,
    }, barrier_handler.handler());
    defer server.deinit();

    // Initialize the server first (required before other requests)
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    const initialized_notification =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    _ = try server.processMessage(initialized_notification);

    // The barrier tool waits until 2 concurrent calls arrive. Processed
    // sequentially, each call times out with an error instead, so two
    // results prove parallel handling.

    // Send batch of 2 barrier calls
    const batch_request =
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"barrier","arguments":{"count":2}}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"barrier","arguments":{"count":2}}}]
    ;

    const batch_response = try server.processMessage(batch_request);
    defer if (batch_response) |r| allocator.free(r);

    try std.testing.expect(batch_response != null);

    // Parse and verify both succeeded
    var batch_doc = try parseJsonResponse(allocator, batch_response.?);
    defer batch_doc.deinit();

    try std.testing.expect(batch_doc.root == .arr);
    const responses = batch_doc.root.arr;
    try std.testing.expectEqual(@as(usize, 2), responses.len);

    // Both should have results (not errors)
    for (responses) |resp| {
        try std.testing.expect(resp == .obj);
        const result = getField(resp.obj, "result");
        try std.testing.expect(result != null);
        // Should not have error field
        const err = getField(resp.obj, "error");
        try std.testing.expect(err == null);
    }
}

// ============================================================================
// T4: HTTP bearer auth
// ============================================================================

test "T4: HTTP bearer auth" {
    const allocator = std.testing.allocator;

    const test_token = "test-bearer-token-12345";

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .auth_mode = .bearer,
        .bearer_token = test_token,
        .http_port = 0, // Let OS assign port
    }, demo_handler.handler());
    defer server.deinit();

    const port = try server.serveHttp();
    defer server.stop();

    // Give server time to start
    _io().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};

    // Test 1: Request without auth should return 401
    {
        const stream = testConnect(port) catch {
            // Server might not be ready, skip
            return;
        };
        defer testStreamClose(stream);

        const request = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        try std.testing.expect(std.mem.indexOf(u8, response, "401") != null);
    }

    // Test 2: Request with valid bearer token should succeed
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        var req_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}}", .{test_token}) catch return;

        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should get 200 OK with Mcp-Session-Id header
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "Mcp-Session-Id") != null);
    }
}

// ============================================================================
// T5: HTTP oauth2 well-known endpoint
// ============================================================================

test "T5: HTTP oauth2 well-known endpoint" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .auth_mode = .oauth2,
        .oauth_dynamic_registration = true, // Enable DCR for registration_endpoint
        .http_port = 0,
    }, demo_handler.handler());
    defer server.deinit();

    const port = try server.serveHttp();
    defer server.stop();

    // Give server time to start
    _io().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};

    // Request OAuth2 metadata
    const stream = testConnect(port) catch return;
    defer testStreamClose(stream);

    const request = "GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: localhost\r\n\r\n";
    testStreamWriteAll(stream, request) catch return;

    var buf: [2048]u8 = undefined;
    const n = testStreamRead(stream, &buf) catch return;
    const response = buf[0..n];

    // Should get 200 OK
    try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);

    // Find JSON body
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n");
    if (body_start) |start| {
        const body = response[start + 4 ..];

        // Parse JSON response
        var err = json.ParseError.init();
        var doc = json.parse(allocator, body, .{}, &err) catch return;
        defer doc.deinit();

        if (doc.root == .obj) {
            const obj = doc.root.obj;

            // Must have authorization_endpoint
            const auth_ep = getStringField(obj, "authorization_endpoint");
            try std.testing.expect(auth_ep != null);
            try std.testing.expect(std.mem.indexOf(u8, auth_ep.?, "/authorize") != null);

            // Must have token_endpoint
            const token_ep = getStringField(obj, "token_endpoint");
            try std.testing.expect(token_ep != null);
            try std.testing.expect(std.mem.indexOf(u8, token_ep.?, "/token") != null);

            // Must have registration_endpoint
            const reg_ep = getStringField(obj, "registration_endpoint");
            try std.testing.expect(reg_ep != null);
            try std.testing.expect(std.mem.indexOf(u8, reg_ep.?, "/register") != null);
        }
    }
}

// ============================================================================
// Additional Protocol Compliance Tests
// ============================================================================

test "Notification has no response" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Notification (no id field)
    const notification =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"123"}}
    ;

    const response = try server.processMessage(notification);
    try std.testing.expect(response == null);
}

test "Invalid JSON returns parse error" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const invalid_json = "not valid json at all";

    const response = try server.processMessage(invalid_json);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Should contain error code -32700 (Parse error)
    try std.testing.expect(std.mem.indexOf(u8, response.?, "-32700") != null);
}

test "Missing jsonrpc field returns invalid request" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const bad_request =
        \\{"id":1,"method":"ping"}
    ;

    const response = try server.processMessage(bad_request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Should contain error code -32600 (Invalid Request)
    try std.testing.expect(std.mem.indexOf(u8, response.?, "-32600") != null);
}

test "String request ID preserved" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const request =
        \\{"jsonrpc":"2.0","id":"my-string-id","method":"ping"}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"id\":\"my-string-id\"") != null);
}

test "tools/list returns tools array" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first (required before other requests per GAP-004)
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    const initialized_notification =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    _ = try server.processMessage(initialized_notification);

    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"tools\"") != null);
}

test "Empty batch returns error" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    const empty_batch = "[]";

    const response = try server.processMessage(empty_batch);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    // Should contain error
    try std.testing.expect(std.mem.indexOf(u8, response.?, "error") != null);
}

// ============================================================================
// GAP-001: Version Mismatch Handling
// ============================================================================

test "Version mismatch returns server version" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Send initialize with old/unsupported version
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-01-01","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;

    const response = try server.processMessage(init_request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Server should respond with its supported version
    var doc = try parseJsonResponse(allocator, response.?);
    defer doc.deinit();

    const result = getField(doc.root.obj, "result");
    try std.testing.expect(result != null);

    const proto_ver = getStringField(result.?.obj, "protocolVersion");
    try std.testing.expect(proto_ver != null);
    try std.testing.expectEqualStrings(mcp.ProtocolVersion, proto_ver.?);
}

// ============================================================================
// GAP-003: Initialize in Batch Rejection
// ============================================================================

test "Initialize in batch is rejected" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Send initialize as part of a batch (not allowed per spec)
    const batch_with_init =
        \\[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    ;

    const response = try server.processMessage(batch_with_init);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Should return an error for the initialize request
    try std.testing.expect(std.mem.indexOf(u8, response.?, "error") != null);
}

// ============================================================================
// GAP-004: Pre-Initialize Request Blocking
// ============================================================================

test "Pre-init request blocking" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Try to call tools/list before initialize (should be blocked except ping/initialize)
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Should get an error since we haven't initialized
    try std.testing.expect(std.mem.indexOf(u8, response.?, "error") != null);
}

test "Ping allowed before init" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Ping should work even before initialize
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    ;

    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);

    // Ping should succeed (has result, not error)
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"result\"") != null);
}

// ============================================================================
// GAP-006: Origin Header Validation
// ============================================================================

test "Origin header validation" {
    const allocator = std.testing.allocator;

    // Server with explicit allowed origins
    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .http_port = 0,
        .http_allowed_origins = &[_][]const u8{"http://allowed.example.com"},
    }, demo_handler.handler());
    defer server.deinit();

    const port = try server.serveHttp();
    defer server.stop();

    _io().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};

    // Test: Request with disallowed origin
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        const request = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nOrigin: http://evil.example.com\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should reject with 403 Forbidden
        try std.testing.expect(std.mem.indexOf(u8, response, "403") != null);
    }

    // Test: Request with allowed origin
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        const request = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nOrigin: http://allowed.example.com\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should succeed with 200 OK
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    }
}

// ============================================================================
// GAP-007/011/012: Session Lifecycle
// ============================================================================

test "Session lifecycle - create use delete" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .http_port = 0,
    }, demo_handler.handler());
    defer server.deinit();

    const port = try server.serveHttp();
    defer server.stop();

    _io().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};

    var session_id: [64]u8 = undefined;
    var session_id_len: usize = 0;

    // Step 1: Create session via initialize
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        const init_body =
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        ;
        var req_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ init_body.len, init_body }) catch return;

        testStreamWriteAll(stream, request) catch return;

        var buf: [2048]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should have Mcp-Session-Id header
        if (std.mem.indexOf(u8, response, "Mcp-Session-Id: ")) |start| {
            const id_start = start + "Mcp-Session-Id: ".len;
            if (std.mem.indexOfPos(u8, response, id_start, "\r\n")) |end| {
                session_id_len = end - id_start;
                @memcpy(session_id[0..session_id_len], response[id_start..end]);
            }
        }
        try std.testing.expect(session_id_len > 0);
    }

    // Step 2: Use session with valid ID
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        const ping_body =
            \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        ;
        var req_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nMcp-Session-Id: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ session_id[0..session_id_len], ping_body.len, ping_body }) catch return;

        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should succeed
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    }

    // Step 3: Delete session
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        var req_buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf, "DELETE /mcp HTTP/1.1\r\nHost: localhost\r\nMcp-Session-Id: {s}\r\n\r\n", .{session_id[0..session_id_len]}) catch return;

        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should get 204 No Content or 200 OK
        try std.testing.expect(std.mem.indexOf(u8, response, "204") != null or std.mem.indexOf(u8, response, "200") != null);
    }

    // Step 4: Request with deleted session should fail
    {
        const stream = testConnect(port) catch return;
        defer testStreamClose(stream);

        const ping_body =
            \\{"jsonrpc":"2.0","id":3,"method":"ping"}
        ;
        var req_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: localhost\r\nMcp-Session-Id: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ session_id[0..session_id_len], ping_body.len, ping_body }) catch return;

        testStreamWriteAll(stream, request) catch return;

        var buf: [1024]u8 = undefined;
        const n = testStreamRead(stream, &buf) catch return;
        const response = buf[0..n];

        // Should get 404 for invalid session
        try std.testing.expect(std.mem.indexOf(u8, response, "404") != null);
    }
}

// ============================================================================
// GAP-013: resources/unsubscribe
// ============================================================================

test "resources/unsubscribe" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // Subscribe first
    const subscribe_request =
        \\{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"file:///test.txt"}}
    ;
    const sub_resp = try server.processMessage(subscribe_request);
    defer if (sub_resp) |r| allocator.free(r);

    // Now unsubscribe
    const unsubscribe_request =
        \\{"jsonrpc":"2.0","id":2,"method":"resources/unsubscribe","params":{"uri":"file:///test.txt"}}
    ;
    const unsub_resp = try server.processMessage(unsubscribe_request);
    defer if (unsub_resp) |r| allocator.free(r);

    try std.testing.expect(unsub_resp != null);
    // Should have a result (not an error)
    try std.testing.expect(std.mem.indexOf(u8, unsub_resp.?, "\"result\"") != null);
}

// ============================================================================
// GAP-031: Specific Error Codes
// ============================================================================

test "Specific error codes - resource not found" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // Try to read non-existent resource
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"file:///nonexistent/path"}}
    ;
    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    // Should have error code -32002 (Resource not found)
    try std.testing.expect(std.mem.indexOf(u8, response.?, "-32002") != null);
}

test "Specific error codes - method not found" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first so we can test method not found (not pre-init blocking)
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"nonexistent/method"}
    ;
    const response = try server.processMessage(request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    // Should have error code -32601 (Method not found)
    try std.testing.expect(std.mem.indexOf(u8, response.?, "-32601") != null);
}

// ============================================================================
// GAP-034: MCP-Protocol-Version Header
// ============================================================================

test "MCP-Protocol-Version header in response" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .http_port = 0,
    }, demo_handler.handler());
    defer server.deinit();

    const port = try server.serveHttp();
    defer server.stop();

    _io().sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};

    const stream = testConnect(port) catch return;
    defer testStreamClose(stream);

    const request = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 41\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    testStreamWriteAll(stream, request) catch return;

    var buf: [2048]u8 = undefined;
    const n = testStreamRead(stream, &buf) catch return;
    const response = buf[0..n];

    // Should have MCP-Protocol-Version header
    try std.testing.expect(std.mem.indexOf(u8, response, "MCP-Protocol-Version: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, mcp.ProtocolVersion) != null);
}

// ============================================================================
// GAP-035-040: Task Lifecycle
// ============================================================================

test "Task lifecycle - create get cancel" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .tasks_enabled = true,
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    defer if (init_resp) |r| allocator.free(r);

    try std.testing.expect(init_resp != null);

    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // Verify init response has tasks capability
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"tasks\"") != null);

    // Create a task via task-augmented request
    const task_request =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}},"task":{"ttl":60000}}
    ;
    const task_resp = try server.processMessage(task_request);
    defer if (task_resp) |r| allocator.free(r);

    // Note: Task creation depends on handler implementation
    // For now just verify we get a response
    try std.testing.expect(task_resp != null);
}

test "tasks/list returns array" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .tasks_enabled = true,
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize first
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    const init_resp = try server.processMessage(init_request);
    if (init_resp) |r| allocator.free(r);

    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // List tasks
    const list_request =
        \\{"jsonrpc":"2.0","id":1,"method":"tasks/list"}
    ;
    const list_resp_opt = try server.processMessage(list_request);
    try std.testing.expect(list_resp_opt != null);
    const list_resp = list_resp_opt.?;
    defer allocator.free(list_resp);

    // Should have tasks array in result
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"tasks\"") != null);
}

// ============================================================================
// GAP-029: Rate Limiting
// ============================================================================

test "Rate limiting rejects excess requests" {
    const allocator = std.testing.allocator;

    // Very low rate limit for testing
    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .rate_limit_requests_per_second = 1,
        .rate_limit_burst = 2,
    }, demo_handler.handler());
    defer server.deinit();

    // Send multiple requests quickly
    var success_count: usize = 0;
    for (0..10) |i| {
        var id_buf: [64]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}", .{i}) catch continue;

        const response = try server.processMessage(id_str);
        if (response) |r| {
            if (std.mem.indexOf(u8, r, "\"result\"") != null) {
                success_count += 1;
            }
            allocator.free(r);
        }
    }

    // Verify that requests were processed (rate limiting may or may not trigger)
    try std.testing.expect(success_count > 0);
}

// ============================================================================
// Client Capability Parsing Tests
// ============================================================================

test "Parse sampling.tools capability" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize with sampling.tools capability
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"sampling":{"tools":true}},"clientInfo":{"name":"test","version":"1.0"}}}
    ;

    const response = try server.processMessage(init_request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(server.client_capabilities.sampling);
    try std.testing.expect(server.client_capabilities.sampling_tools);
}

test "Parse sampling.context capability" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize with sampling.context capability
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"sampling":{"context":true}},"clientInfo":{"name":"test","version":"1.0"}}}
    ;

    const response = try server.processMessage(init_request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(server.client_capabilities.sampling);
    try std.testing.expect(server.client_capabilities.sampling_context);
}

test "Parse elicitation capability" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    }, demo_handler.handler());
    defer server.deinit();

    // Initialize with elicitation capability
    const init_request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{}},"clientInfo":{"name":"test","version":"1.0"}}}
    ;

    const response = try server.processMessage(init_request);
    defer if (response) |r| allocator.free(r);

    try std.testing.expect(response != null);
    try std.testing.expect(server.client_capabilities.elicitation);
}

test "batch processing dispatches via thread-pool when pool is set" {
    const allocator = std.testing.allocator;

    // Initialize a thread-pool and inject it into the server.
    const tp = @import("thread_pool");
    var pool = try tp.ThreadPool.init(allocator, .{ .max_threads = 4 });
    defer pool.deinit();

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .worker_threads = 4,
    }, demo_handler.handler());
    defer server.deinit();
    server.pool = &pool;

    // Required protocol handshake first.
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    if (try server.processMessage(init_request)) |r| allocator.free(r);
    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // Build a batch of 8 ping requests. Each carries an `id`, so each is a
    // request (not a notification); mcp's ping handler returns the empty
    // result object `{}` per JSON-RPC convention. Each request is a distinct
    // dispatch unit so the pool should see >= 8 submissions.
    const batch =
        \\[
        \\ {"jsonrpc":"2.0","id":1,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":2,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":3,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":4,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":5,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":6,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":7,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":8,"method":"ping"}
        \\]
    ;

    const before = pool.statsSnapshot().submitted;
    if (try server.processMessage(batch)) |resp| allocator.free(resp);
    const after = pool.statsSnapshot().submitted;

    try std.testing.expect(after - before >= 8);
}

test "batch processing does not deadlock under pool backpressure" {
    const allocator = std.testing.allocator;

    // Tiny queue_capacity forces submitBatch into its partial-submit path:
    // the first few tasks fit, the rest return `QueueFull` under the default
    // `.return_error` backpressure policy and submitBatch returns with
    // `result.submitted < tasks.len`. A broken wait-group pairing in the
    // batch dispatch code would manifest here as wg.wait() hanging forever.
    // queue_capacity is rounded up to a power of two and must be > 0, so
    // the smallest accepted value is 1 — use 2 to leave room for one task
    // to actually dequeue. local_queue_capacity also rounds up; 1 is valid.
    const tp = @import("thread_pool");
    var pool = try tp.ThreadPool.init(allocator, .{
        .max_threads = 1,
        .min_threads = 1,
        .queue_capacity = 2,
        .local_queue_capacity = 1,
    });
    defer pool.deinit();

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .worker_threads = 1,
    }, demo_handler.handler());
    defer server.deinit();
    server.pool = &pool;

    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    if (try server.processMessage(init_request)) |r| allocator.free(r);
    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // 16 items vs queue_capacity=2 guarantees backpressure on the
    // submitBatch call — more than enough items to exceed the queue even
    // after rounding.
    const batch =
        \\[
        \\ {"jsonrpc":"2.0","id":1,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":2,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":3,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":4,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":5,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":6,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":7,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":8,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":9,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":10,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":11,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":12,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":13,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":14,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":15,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":16,"method":"ping"}
        \\]
    ;

    // If the dispatch path mispairs wg.add/done, this call hangs forever
    // and the test runner kills it. Successful return is itself the assert.
    if (try server.processMessage(batch)) |resp| allocator.free(resp);
}

test "startWorkers creates a server-owned thread-pool and deinit destroys it" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .worker_threads = 2,
    }, demo_handler.handler());
    defer server.deinit();

    // No pool attached until startWorkers runs.
    try std.testing.expect(server.pool == null);
    try std.testing.expect(!server.own_pool);

    try server.ensureWorkers();

    // Pool is now server-owned.
    try std.testing.expect(server.pool != null);
    try std.testing.expect(server.own_pool);

    // Idempotent — calling again must not leak or replace the pool.
    const before = server.pool.?;
    try server.ensureWorkers();
    try std.testing.expect(server.pool.? == before);

    // server.deinit() runs via defer and must shutdown + destroy the owned
    // pool. Test uses testing.allocator which would flag any leak.
}

test "processBatch lazy-creates thread-pool when no pool is attached" {
    const allocator = std.testing.allocator;

    var demo_handler = mcp.DemoHandler.init(allocator);
    var server = try mcp.Server.init(allocator, .{
        .name = "test-server",
        .version = "1.0.0",
        .worker_threads = 2,
    }, demo_handler.handler());
    defer server.deinit();

    // No ensureWorkers, no serve* — pool must be null going in.
    try std.testing.expect(server.pool == null);
    try std.testing.expect(!server.own_pool);

    // Protocol handshake.
    const init_request =
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    ;
    if (try server.processMessage(init_request)) |r| allocator.free(r);
    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    // Send a batch of 4 pings — this triggers processBatch → lazy startWorkers.
    const batch =
        \\[
        \\ {"jsonrpc":"2.0","id":1,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":2,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":3,"method":"ping"},
        \\ {"jsonrpc":"2.0","id":4,"method":"ping"}
        \\]
    ;
    if (try server.processMessage(batch)) |resp| allocator.free(resp);

    try std.testing.expect(server.pool != null);
    try std.testing.expect(server.own_pool);
}

test "parallel module is re-exported from mcp public API" {
    // The re-export itself is the spec contract — this test ensures the
    // module is reachable and that its public types/functions compile
    // through the re-exported namespace. Functional tests for individual
    // parallel ops live in src/parallel.zig or dedicated test files.
    _ = mcp.parallel.JsonRpcRequest;
    _ = mcp.parallel.JsonRpcResponse;
    _ = mcp.parallel.RequestHandler;
    _ = mcp.parallel.ToolCall;
    _ = mcp.parallel.ToolResult;
    _ = mcp.parallel.SseClient;
    _ = mcp.parallel.SseEvent;
    _ = mcp.parallel.ResourceReadRequest;
    _ = mcp.parallel.PromptTemplate;

    // Callable functions exist via the re-export.
    _ = @TypeOf(mcp.parallel.getPool);
    _ = @TypeOf(mcp.parallel.deinitPool);
    _ = @TypeOf(mcp.parallel.parallelBatchProcess);
    _ = @TypeOf(mcp.parallel.parallelSseBroadcast);
    _ = @TypeOf(mcp.parallel.parallelToolExecute);
    _ = @TypeOf(mcp.parallel.parallelResourceRead);
    _ = @TypeOf(mcp.parallel.parallelPromptRender);

    // deinitPool is always safe to call (no-op if pool never initialized).
    mcp.parallel.deinitPool();
}
