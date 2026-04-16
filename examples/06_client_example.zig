//! MCP Client Example
//!
//! This example demonstrates how to build a simple MCP client that:
//! - Connects to an MCP server
//! - Sends JSON-RPC requests
//! - Handles responses
//!
//! Note: This library is primarily a server implementation. This example
//! shows how to construct client-side JSON-RPC messages that work with
//! any MCP server.
//!
//! To run this example:
//!   zig build run-example-client

const std = @import("std");

/// Simple JSON-RPC client for MCP
const McpClient = struct {
    allocator: std.mem.Allocator,
    next_id: i64 = 1,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) McpClient {
        return .{ .allocator = allocator };
    }

    /// Build an initialize request
    pub fn buildInitializeRequest(self: *McpClient, client_name: []const u8, client_version: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"protocolVersion":"2025-11-25","capabilities":{{}},"clientInfo":{{"name":"{s}","version":"{s}"}}}}}}
        , .{ id, client_name, client_version });
    }

    /// Build the initialized notification
    pub fn buildInitializedNotification(_: *McpClient) []const u8 {
        return "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    }

    /// Build a ping request
    pub fn buildPingRequest(self: *McpClient) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"ping"}}
        , .{id});
    }

    /// Build a tools/list request
    pub fn buildListToolsRequest(self: *McpClient) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/list"}}
        , .{id});
    }

    /// Build a tools/call request
    pub fn buildCallToolRequest(self: *McpClient, tool_name: []const u8, args_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
        , .{ id, tool_name, args_json });
    }

    /// Build a resources/list request
    pub fn buildListResourcesRequest(self: *McpClient) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"resources/list"}}
        , .{id});
    }

    /// Build a resources/read request
    pub fn buildReadResourceRequest(self: *McpClient, uri: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"resources/read","params":{{"uri":"{s}"}}}}
        , .{ id, uri });
    }

    /// Build a prompts/list request
    pub fn buildListPromptsRequest(self: *McpClient) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        return std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/list"}}
        , .{id});
    }

    /// Build a prompts/get request
    pub fn buildGetPromptRequest(self: *McpClient, prompt_name: []const u8, args_json: ?[]const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        if (args_json) |args| {
            return std.fmt.allocPrint(self.allocator,
                \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/get","params":{{"name":"{s}","arguments":{s}}}}}
            , .{ id, prompt_name, args });
        } else {
            return std.fmt.allocPrint(self.allocator,
                \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/get","params":{{"name":"{s}"}}}}
            , .{ id, prompt_name });
        }
    }

    /// Build a batch request
    pub fn buildBatchRequest(self: *McpClient, requests: []const []const u8) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.append(self.allocator, '[');

        for (requests, 0..) |req, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.appendSlice(self.allocator, req);
        }

        try buf.append(self.allocator, ']');

        return buf.toOwnedSlice(self.allocator);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== MCP Client Example ===\n\n", .{});
    std.debug.print("This example shows how to construct MCP client requests.\n", .{});
    std.debug.print("In a real client, you would send these over stdio or HTTP.\n\n", .{});

    var client = McpClient.init(allocator);

    // Demonstrate building various requests
    std.debug.print("--- Initialize Request ---\n", .{});
    const init_req = try client.buildInitializeRequest("example-client", "1.0.0");
    defer allocator.free(init_req);
    std.debug.print("{s}\n\n", .{init_req});

    std.debug.print("--- Initialized Notification ---\n", .{});
    const init_notif = client.buildInitializedNotification();
    std.debug.print("{s}\n\n", .{init_notif});

    std.debug.print("--- Ping Request ---\n", .{});
    const ping_req = try client.buildPingRequest();
    defer allocator.free(ping_req);
    std.debug.print("{s}\n\n", .{ping_req});

    std.debug.print("--- List Tools Request ---\n", .{});
    const list_tools_req = try client.buildListToolsRequest();
    defer allocator.free(list_tools_req);
    std.debug.print("{s}\n\n", .{list_tools_req});

    std.debug.print("--- Call Tool Request ---\n", .{});
    const call_tool_req = try client.buildCallToolRequest("echo", "{\"message\":\"Hello, World!\"}");
    defer allocator.free(call_tool_req);
    std.debug.print("{s}\n\n", .{call_tool_req});

    std.debug.print("--- List Resources Request ---\n", .{});
    const list_res_req = try client.buildListResourcesRequest();
    defer allocator.free(list_res_req);
    std.debug.print("{s}\n\n", .{list_res_req});

    std.debug.print("--- Read Resource Request ---\n", .{});
    const read_res_req = try client.buildReadResourceRequest("config://app/settings");
    defer allocator.free(read_res_req);
    std.debug.print("{s}\n\n", .{read_res_req});

    std.debug.print("--- List Prompts Request ---\n", .{});
    const list_prompts_req = try client.buildListPromptsRequest();
    defer allocator.free(list_prompts_req);
    std.debug.print("{s}\n\n", .{list_prompts_req});

    std.debug.print("--- Get Prompt Request ---\n", .{});
    const get_prompt_req = try client.buildGetPromptRequest("summarize", "{\"style\":\"brief\"}");
    defer allocator.free(get_prompt_req);
    std.debug.print("{s}\n\n", .{get_prompt_req});

    std.debug.print("--- Batch Request Example ---\n", .{});
    const batch_items = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"ping\"}",
    };
    const batch_req = try client.buildBatchRequest(&batch_items);
    defer allocator.free(batch_req);
    std.debug.print("{s}\n\n", .{batch_req});

    // Example: How to use with stdio transport
    std.debug.print("=== Using with Stdio Transport ===\n\n", .{});
    std.debug.print(
        \\To communicate with an MCP server via stdio:
        \\
        \\1. Spawn the server process
        \\2. Write requests to the server's stdin (newline-delimited)
        \\3. Read responses from the server's stdout
        \\
        \\Example shell session:
        \\  $ echo '{s}' | ./mcp-server
        \\  $ echo '{s}' | ./mcp-server
        \\
    , .{ init_req, init_notif });

    // Example: How to use with HTTP transport
    std.debug.print("\n=== Using with HTTP Transport ===\n\n", .{});
    std.debug.print(
        \\To communicate with an MCP server via HTTP:
        \\
        \\1. POST JSON-RPC requests to the /mcp endpoint
        \\2. Include Mcp-Session-Id header after initialization
        \\3. Use GET for SSE event stream
        \\
        \\Example curl commands:
        \\  # Initialize
        \\  curl -X POST http://localhost:8080/mcp \
        \\    -H "Content-Type: application/json" \
        \\    -d '<init-request>'
        \\
        \\  # Subsequent requests (use session ID from response)
        \\  curl -X POST http://localhost:8080/mcp \
        \\    -H "Content-Type: application/json" \
        \\    -H "Mcp-Session-Id: <session-id>" \
        \\    -d '<request>'
        \\
    , .{});
}
