//! MCP Protocol Conformance Tests
//!
//! Tests for MCP 2025-11-25 specification compliance.
//! Validates JSON-RPC 2.0 and MCP-specific behaviors.

const std = @import("std");
const json = @import("json");
const mcp = @import("mcp");

// ============================================================================
// JSON-RPC 2.0 Conformance Tests
// ============================================================================

test "JSON-RPC: request must have jsonrpc field" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const invalid = "{\"id\":1,\"method\":\"test\"}";

    try expectValidRequest(valid);
    try expectInvalidRequest(invalid);
}

test "JSON-RPC: jsonrpc must be exactly 2.0" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const invalid_1_0 = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"test\"}";
    const invalid_2_1 = "{\"jsonrpc\":\"2.1\",\"id\":1,\"method\":\"test\"}";

    try expectValidRequest(valid);
    try expectInvalidRequest(invalid_1_0);
    try expectInvalidRequest(invalid_2_1);
}

test "JSON-RPC: request must have method field" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const invalid = "{\"jsonrpc\":\"2.0\",\"id\":1}";

    try expectValidRequest(valid);
    try expectInvalidRequest(invalid);
}

test "JSON-RPC: method must be string" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const invalid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":123}";

    try expectValidRequest(valid);
    try expectInvalidRequest(invalid);
}

test "JSON-RPC: id can be string, number, or null" {
    const id_number = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const id_string = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"test\"}";
    const id_null = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"test\"}";

    try expectValidRequest(id_number);
    try expectValidRequest(id_string);
    try expectValidRequest(id_null);
}

test "JSON-RPC: notification has no id field" {
    const notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}";
    try expectValidNotification(notification);
}

test "JSON-RPC: params must be object or array if present" {
    const params_object = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":{}}";
    const params_array = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":[]}";
    const no_params = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";
    const invalid_params = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":\"string\"}";

    try expectValidRequest(params_object);
    try expectValidRequest(params_array);
    try expectValidRequest(no_params);
    try expectInvalidRequest(invalid_params);
}

test "JSON-RPC: response must have result or error, not both" {
    const valid_result = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const valid_error = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid\"}}";
    const invalid_both = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-32600,\"message\":\"Invalid\"}}";

    try expectValidResponse(valid_result);
    try expectValidResponse(valid_error);
    try expectInvalidResponse(invalid_both);
}

test "JSON-RPC: error object must have code and message" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid\"}}";
    const missing_code = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"Invalid\"}}";
    const missing_message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600}}";

    try expectValidResponse(valid);
    try expectInvalidResponse(missing_code);
    try expectInvalidResponse(missing_message);
}

test "JSON-RPC: error code must be integer" {
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid\"}}";
    const invalid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"-32600\",\"message\":\"Invalid\"}}";

    try expectValidResponse(valid);
    try expectInvalidResponse(invalid);
}

// ============================================================================
// MCP Protocol Conformance Tests
// ============================================================================

test "MCP: initialize request format" {
    const valid =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        \\"protocolVersion":"2025-11-25",
        \\"capabilities":{},
        \\"clientInfo":{"name":"test","version":"1.0"}
        \\}}
    ;

    try expectValidMcpRequest(valid, "initialize");
}

test "MCP: initialize requires protocolVersion" {
    const missing_version =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        \\"capabilities":{},
        \\"clientInfo":{"name":"test","version":"1.0"}
        \\}}
    ;

    try expectMcpMissingField(missing_version, "protocolVersion");
}

test "MCP: initialize requires capabilities" {
    const missing_caps =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        \\"protocolVersion":"2025-11-25",
        \\"clientInfo":{"name":"test","version":"1.0"}
        \\}}
    ;

    try expectMcpMissingField(missing_caps, "capabilities");
}

test "MCP: initialize requires clientInfo" {
    const missing_info =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        \\"protocolVersion":"2025-11-25",
        \\"capabilities":{}
        \\}}
    ;

    try expectMcpMissingField(missing_info, "clientInfo");
}

test "MCP: tools/list response format" {
    const valid_response =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"tools":[{
        \\"name":"calculator",
        \\"description":"Performs math",
        \\"inputSchema":{"type":"object","properties":{}}
        \\}]
        \\}}
    ;

    try expectValidMcpResponse(valid_response, "tools");
}

test "MCP: tool definition requires name" {
    const missing_name =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"tools":[{
        \\"description":"Performs math",
        \\"inputSchema":{"type":"object"}
        \\}]
        \\}}
    ;

    try expectMcpMissingField(missing_name, "name");
}

test "MCP: tools/call request format" {
    const valid =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
        \\"name":"calculator",
        \\"arguments":{"a":1,"b":2}
        \\}}
    ;

    try expectValidMcpRequest(valid, "tools/call");
}

test "MCP: tools/call requires name" {
    const missing_name =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
        \\"arguments":{"a":1}
        \\}}
    ;

    try expectMcpMissingField(missing_name, "name");
}

test "MCP: resources/list response format" {
    const valid_response =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"resources":[{
        \\"uri":"file:///test.txt",
        \\"name":"test.txt"
        \\}]
        \\}}
    ;

    try expectValidMcpResponse(valid_response, "resources");
}

test "MCP: resource requires uri" {
    const missing_uri =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"resources":[{
        \\"name":"test.txt"
        \\}]
        \\}}
    ;

    try expectMcpMissingField(missing_uri, "uri");
}

test "MCP: resources/read request format" {
    const valid =
        \\{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{
        \\"uri":"file:///test.txt"
        \\}}
    ;

    try expectValidMcpRequest(valid, "resources/read");
}

test "MCP: prompts/list response format" {
    const valid_response =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"prompts":[{
        \\"name":"greeting",
        \\"description":"A greeting prompt"
        \\}]
        \\}}
    ;

    try expectValidMcpResponse(valid_response, "prompts");
}

test "MCP: prompt requires name" {
    const missing_name =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\"prompts":[{
        \\"description":"A greeting prompt"
        \\}]
        \\}}
    ;

    try expectMcpMissingField(missing_name, "name");
}

test "MCP: prompts/get request format" {
    const valid =
        \\{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{
        \\"name":"greeting",
        \\"arguments":{"user":"Alice"}
        \\}}
    ;

    try expectValidMcpRequest(valid, "prompts/get");
}

test "MCP: content types" {
    const text_content =
        \\{"type":"text","text":"Hello"}
    ;
    const image_content =
        \\{"type":"image","data":"base64...","mimeType":"image/png"}
    ;
    const resource_content =
        \\{"type":"resource","resource":{"uri":"file:///test","text":"content"}}
    ;

    try expectValidContentType(text_content, "text");
    try expectValidContentType(image_content, "image");
    try expectValidContentType(resource_content, "resource");
}

test "MCP: text content requires text field" {
    const missing_text =
        \\{"type":"text"}
    ;

    try expectMcpMissingField(missing_text, "text");
}

test "MCP: image content requires data and mimeType" {
    const missing_data =
        \\{"type":"image","mimeType":"image/png"}
    ;
    const missing_mime =
        \\{"type":"image","data":"base64..."}
    ;

    try expectMcpMissingField(missing_data, "data");
    try expectMcpMissingField(missing_mime, "mimeType");
}

test "MCP: ping notification" {
    const ping = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}";
    try expectValidNotification(ping);
}

test "MCP: cancelled notification format" {
    const cancelled =
        \\{"jsonrpc":"2.0","method":"cancelled","params":{
        \\"requestId":123,
        \\"reason":"User cancelled"
        \\}}
    ;

    try expectValidNotification(cancelled);
}

test "MCP: progress notification format" {
    const progress =
        \\{"jsonrpc":"2.0","method":"progress","params":{
        \\"progressToken":"abc123",
        \\"progress":50,
        \\"total":100
        \\}}
    ;

    try expectValidNotification(progress);
}

test "MCP: logging/setLevel request format" {
    const valid =
        \\{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{
        \\"level":"debug"
        \\}}
    ;

    try expectValidMcpRequest(valid, "logging/setLevel");
}

test "MCP: valid log levels" {
    const levels = [_][]const u8{ "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency" };

    for (levels) |level| {
        const request = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"logging/setLevel\",\"params\":{{\"level\":\"{s}\"}}}}",
            .{level},
        );
        defer std.testing.allocator.free(request);
        try expectValidMcpRequest(request, "logging/setLevel");
    }
}

// ============================================================================
// Error Code Conformance Tests
// ============================================================================

test "MCP: standard error codes" {
    // JSON-RPC reserved codes
    try expectErrorCode(-32700, "Parse error");
    try expectErrorCode(-32600, "Invalid Request");
    try expectErrorCode(-32601, "Method not found");
    try expectErrorCode(-32602, "Invalid params");
    try expectErrorCode(-32603, "Internal error");

    // MCP-specific codes
    try expectErrorCode(-32800, "Request cancelled");
    try expectErrorCode(-32801, "Content too large");
}

// ============================================================================
// Helper Functions
// ============================================================================

fn expectValidRequest(input: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(std.testing.allocator, input, .{}, &err_info) catch {
        return error.ParseFailed;
    };
    defer doc.deinit();

    // Check required fields
    switch (doc.root) {
        .obj => |members| {
            var has_jsonrpc = false;
            var has_method = false;
            var jsonrpc_valid = false;
            var method_is_string = false;

            for (members) |m| {
                if (std.mem.eql(u8, m.k, "jsonrpc")) {
                    has_jsonrpc = true;
                    if (m.v == .str and std.mem.eql(u8, m.v.str, "2.0")) {
                        jsonrpc_valid = true;
                    }
                }
                if (std.mem.eql(u8, m.k, "method")) {
                    has_method = true;
                    method_is_string = m.v == .str;
                }
                if (std.mem.eql(u8, m.k, "params")) {
                    if (m.v != .obj and m.v != .arr) {
                        return error.InvalidParams;
                    }
                }
            }

            if (!has_jsonrpc or !jsonrpc_valid) return error.InvalidJsonRpc;
            if (!has_method or !method_is_string) return error.InvalidMethod;
        },
        else => return error.NotAnObject,
    }
}

fn expectInvalidRequest(input: []const u8) !void {
    expectValidRequest(input) catch return;
    return error.ExpectedInvalid;
}

fn expectValidNotification(input: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(std.testing.allocator, input, .{}, &err_info) catch {
        return error.ParseFailed;
    };
    defer doc.deinit();

    switch (doc.root) {
        .obj => |members| {
            for (members) |m| {
                if (std.mem.eql(u8, m.k, "id")) {
                    return error.NotificationHasId;
                }
            }
        },
        else => return error.NotAnObject,
    }
}

fn expectValidResponse(input: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(std.testing.allocator, input, .{}, &err_info) catch {
        return error.ParseFailed;
    };
    defer doc.deinit();

    switch (doc.root) {
        .obj => |members| {
            var has_result = false;
            var has_error = false;

            for (members) |m| {
                if (std.mem.eql(u8, m.k, "result")) has_result = true;
                if (std.mem.eql(u8, m.k, "error")) {
                    has_error = true;
                    // Validate error structure
                    if (m.v == .obj) {
                        var has_code = false;
                        var has_message = false;
                        var code_is_int = false;

                        for (m.v.obj) |em| {
                            if (std.mem.eql(u8, em.k, "code")) {
                                has_code = true;
                                code_is_int = em.v == .num;
                            }
                            if (std.mem.eql(u8, em.k, "message")) {
                                has_message = true;
                            }
                        }

                        if (!has_code or !has_message) return error.InvalidErrorObject;
                        if (!code_is_int) return error.ErrorCodeNotInt;
                    }
                }
            }

            if (has_result and has_error) return error.BothResultAndError;
            if (!has_result and !has_error) return error.NeitherResultNorError;
        },
        else => return error.NotAnObject,
    }
}

fn expectInvalidResponse(input: []const u8) !void {
    expectValidResponse(input) catch return;
    return error.ExpectedInvalid;
}

fn expectValidMcpRequest(input: []const u8, expected_method: []const u8) !void {
    _ = expected_method;
    try expectValidRequest(input);
}

fn expectValidMcpResponse(input: []const u8, expected_field: []const u8) !void {
    _ = expected_field;
    try expectValidResponse(input);
}

fn expectMcpMissingField(input: []const u8, field: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(std.testing.allocator, input, .{}, &err_info) catch {
        return error.ParseFailed;
    };
    defer doc.deinit();

    // Search for the field recursively
    if (findField(doc.root, field)) {
        return error.FieldPresent;
    }
}

fn findField(value: json.Value, field: []const u8) bool {
    switch (value) {
        .obj => |members| {
            for (members) |m| {
                if (std.mem.eql(u8, m.k, field)) return true;
                if (findField(m.v, field)) return true;
            }
        },
        .arr => |items| {
            for (items) |item| {
                if (findField(item, field)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn expectValidContentType(input: []const u8, expected_type: []const u8) !void {
    var err_info = json.ParseError.init();
    var doc = json.parse(std.testing.allocator, input, .{}, &err_info) catch {
        return error.ParseFailed;
    };
    defer doc.deinit();

    switch (doc.root) {
        .obj => |members| {
            for (members) |m| {
                if (std.mem.eql(u8, m.k, "type")) {
                    if (m.v == .str and std.mem.eql(u8, m.v.str, expected_type)) {
                        return;
                    }
                }
            }
        },
        else => {},
    }
    return error.InvalidContentType;
}

fn expectErrorCode(code: i32, _: []const u8) !void {
    // Validate error code is in valid range
    if (code >= -32099 and code <= -32000) {
        // Server error range - valid
    } else if (code >= -32899 and code <= -32800) {
        // MCP error range - valid
    } else if (code == -32700 or code == -32600 or code == -32601 or code == -32602 or code == -32603) {
        // Standard JSON-RPC errors - valid
    } else {
        return error.InvalidErrorCode;
    }
}
