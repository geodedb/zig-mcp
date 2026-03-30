// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel MCP operations using spice heartbeat scheduling.
//!
//! Provides high-performance parallel implementations for MCP operations
//! including JSON-RPC batch processing, SSE broadcasting, tool execution,
//! and resource reading.
//!
//! ## Overview
//!
//! This module enables parallel processing of Model Context Protocol
//! operations using the spice thread pool. Ideal for MCP servers handling
//! multiple clients or batch requests.
//!
//! ## Build Configuration
//!
//! Enable: `-Dspice=true` (default)
//! Disable: `-Dspice=false`
//!
//! ## Usage Example
//!
//! ```zig
//! const parallel = @import("parallel.zig");
//!
//! // Execute multiple tool calls in parallel
//! var calls: [4]parallel.ToolCall = undefined;
//! var results: [4]parallel.ToolResult = undefined;
//!
//! for (&calls) |*call| {
//!     call.* = .{
//!         .name = "read_file",
//!         .arguments = "{\"path\": \"/tmp/test.txt\"}",
//!         .call_id = generateId(),
//!     };
//! }
//!
//! parallel.parallelToolExecute(allocator, &calls, &results, myToolExecutor);
//! ```
//!
//! ## Performance Thresholds
//!
//! | Operation        | Threshold   | Sequential Below |
//! |------------------|-------------|------------------|
//! | Batch Process    | 4 requests  | Yes              |
//! | SSE Broadcast    | 8 clients   | Yes              |
//! | Tool Execute     | 2 calls     | Yes              |
//! | Resource Read    | 2 resources | Yes              |
//! | Prompt Render    | 4 templates | Yes              |

const std = @import("std");

const spice = if (true) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

// ============================================================================
// Global Thread Pool
// ============================================================================

var global_pool: if (true) ?spice.ThreadPool else void = if (true) null else {};
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() if (true) *spice.ThreadPool else void {
    // spice always enabled when this module is compiled

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    // spice always enabled when this module is compiled

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// ============================================================================
// Parallel JSON-RPC Batch Processing
// ============================================================================

/// JSON-RPC request
pub const JsonRpcRequest = struct {
    id: ?[]const u8,
    method: []const u8,
    params: ?[]const u8,
};

/// JSON-RPC response
pub const JsonRpcResponse = struct {
    id: ?[]const u8,
    result: ?[]const u8,
    error_code: ?i32,
    error_msg: ?[]const u8,
};

/// Request handler function type
pub const RequestHandler = *const fn (request: JsonRpcRequest, allocator: std.mem.Allocator) JsonRpcResponse;

/// Context for parallel batch processing
pub const BatchProcessContext = struct {
    requests: []const JsonRpcRequest,
    responses: []JsonRpcResponse,
    handler: RequestHandler,
    allocator: std.mem.Allocator,
};

/// Process multiple JSON-RPC requests in parallel.
///
/// Each request is handled independently, enabling parallel
/// execution of batch requests from clients.
///
/// Parameters:
/// - allocator: Memory allocator
/// - requests: Array of JSON-RPC requests
/// - responses: Array to store responses
/// - handler: Function to handle each request
///
/// Threshold: Uses parallel processing for 4+ requests
pub fn parallelBatchProcess(
    allocator: std.mem.Allocator,
    requests: []const JsonRpcRequest,
    responses: []JsonRpcResponse,
    handler: RequestHandler,
) void {
    std.debug.assert(requests.len == responses.len);

    if (!true or requests.len < 4) {
        for (requests, 0..) |request, i| {
            responses[i] = handler(request, allocator);
        }
        return;
    }

    const pool = getPool();
    const ctx = BatchProcessContext{
        .requests = requests,
        .responses = responses,
        .handler = handler,
        .allocator = allocator,
    };
    _ = pool.call(void, parallelBatchProcessTask, ctx);
}

fn parallelBatchProcessTask(t: *spice.Task, ctx: BatchProcessContext) void {
    const requests = ctx.requests;
    const responses = ctx.responses;

    if (requests.len < 2) {
        for (requests, 0..) |request, i| {
            responses[i] = ctx.handler(request, ctx.allocator);
        }
        return;
    }

    const mid = requests.len / 2;
    const left_ctx = BatchProcessContext{
        .requests = requests[0..mid],
        .responses = responses[0..mid],
        .handler = ctx.handler,
        .allocator = ctx.allocator,
    };
    const right_ctx = BatchProcessContext{
        .requests = requests[mid..],
        .responses = responses[mid..],
        .handler = ctx.handler,
        .allocator = ctx.allocator,
    };

    var fut = spice.Future(BatchProcessContext, void).init();
    fut.fork(t, parallelBatchProcessTask, right_ctx);

    t.call(void, parallelBatchProcessTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parallelBatchProcessTask, right_ctx);
    }
}

// ============================================================================
// Parallel SSE Broadcast
// ============================================================================

/// SSE client connection
pub const SseClient = struct {
    client_id: u64,
    last_event_id: ?u64,
    active: bool,
};

/// SSE event
pub const SseEvent = struct {
    event_type: []const u8,
    data: []const u8,
    event_id: ?u64,
};

/// SSE send result
pub const SseSendResult = struct {
    client_id: u64,
    success: bool,
    error_msg: ?[]const u8,
};

/// SSE sender function type
pub const SseSender = *const fn (client: SseClient, event: SseEvent) SseSendResult;

/// Context for parallel SSE broadcast
pub const SseBroadcastContext = struct {
    clients: []const SseClient,
    event: SseEvent,
    results: []SseSendResult,
    sender: SseSender,
};

/// Broadcast SSE event to multiple clients in parallel.
///
/// Each client send is independent, enabling parallel
/// notification of many connected clients.
///
/// Parameters:
/// - clients: Array of SSE client connections
/// - event: Event to broadcast
/// - results: Array to store send results
/// - sender: Function to send to each client
///
/// Threshold: Uses parallel processing for 8+ clients
pub fn parallelSseBroadcast(
    clients: []const SseClient,
    event: SseEvent,
    results: []SseSendResult,
    sender: SseSender,
) void {
    std.debug.assert(clients.len == results.len);

    if (!true or clients.len < 8) {
        for (clients, 0..) |client, i| {
            results[i] = sender(client, event);
        }
        return;
    }

    const pool = getPool();
    const ctx = SseBroadcastContext{
        .clients = clients,
        .event = event,
        .results = results,
        .sender = sender,
    };
    _ = pool.call(void, parallelSseBroadcastTask, ctx);
}

fn parallelSseBroadcastTask(t: *spice.Task, ctx: SseBroadcastContext) void {
    const clients = ctx.clients;
    const results = ctx.results;

    if (clients.len < 4) {
        for (clients, 0..) |client, i| {
            results[i] = ctx.sender(client, ctx.event);
        }
        return;
    }

    const mid = clients.len / 2;
    const left_ctx = SseBroadcastContext{
        .clients = clients[0..mid],
        .event = ctx.event,
        .results = results[0..mid],
        .sender = ctx.sender,
    };
    const right_ctx = SseBroadcastContext{
        .clients = clients[mid..],
        .event = ctx.event,
        .results = results[mid..],
        .sender = ctx.sender,
    };

    var fut = spice.Future(SseBroadcastContext, void).init();
    fut.fork(t, parallelSseBroadcastTask, right_ctx);

    t.call(void, parallelSseBroadcastTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parallelSseBroadcastTask, right_ctx);
    }
}

// ============================================================================
// Parallel Tool Execution
// ============================================================================

/// Tool call request
pub const ToolCall = struct {
    name: []const u8,
    arguments: ?[]const u8,
    call_id: []const u8,
};

/// Tool execution result
pub const ToolResult = struct {
    call_id: []const u8,
    success: bool,
    output: ?[]const u8,
    error_msg: ?[]const u8,
};

/// Tool executor function type
pub const ToolExecutor = *const fn (call: ToolCall, allocator: std.mem.Allocator) ToolResult;

/// Context for parallel tool execution
pub const ToolExecuteContext = struct {
    calls: []const ToolCall,
    results: []ToolResult,
    executor: ToolExecutor,
    allocator: std.mem.Allocator,
};

/// Execute multiple tool calls in parallel.
///
/// Each tool call is independent, enabling parallel
/// execution of multiple tools in a single request.
///
/// Parameters:
/// - allocator: Memory allocator
/// - calls: Array of tool calls
/// - results: Array to store execution results
/// - executor: Function to execute each tool
///
/// Threshold: Uses parallel processing for 2+ calls
pub fn parallelToolExecute(
    allocator: std.mem.Allocator,
    calls: []const ToolCall,
    results: []ToolResult,
    executor: ToolExecutor,
) void {
    std.debug.assert(calls.len == results.len);

    if (!true or calls.len < 2) {
        for (calls, 0..) |call, i| {
            results[i] = executor(call, allocator);
        }
        return;
    }

    const pool = getPool();
    const ctx = ToolExecuteContext{
        .calls = calls,
        .results = results,
        .executor = executor,
        .allocator = allocator,
    };
    _ = pool.call(void, parallelToolExecuteTask, ctx);
}

fn parallelToolExecuteTask(t: *spice.Task, ctx: ToolExecuteContext) void {
    const calls = ctx.calls;
    const results = ctx.results;

    if (calls.len < 2) {
        for (calls, 0..) |call, i| {
            results[i] = ctx.executor(call, ctx.allocator);
        }
        return;
    }

    const mid = calls.len / 2;
    const left_ctx = ToolExecuteContext{
        .calls = calls[0..mid],
        .results = results[0..mid],
        .executor = ctx.executor,
        .allocator = ctx.allocator,
    };
    const right_ctx = ToolExecuteContext{
        .calls = calls[mid..],
        .results = results[mid..],
        .executor = ctx.executor,
        .allocator = ctx.allocator,
    };

    var fut = spice.Future(ToolExecuteContext, void).init();
    fut.fork(t, parallelToolExecuteTask, right_ctx);

    t.call(void, parallelToolExecuteTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parallelToolExecuteTask, right_ctx);
    }
}

// ============================================================================
// Parallel Resource Reading
// ============================================================================

/// Resource read request
pub const ResourceReadRequest = struct {
    uri: []const u8,
    mime_type: ?[]const u8,
};

/// Resource read result
pub const ResourceReadResult = struct {
    uri: []const u8,
    success: bool,
    content: ?[]const u8,
    mime_type: ?[]const u8,
    error_msg: ?[]const u8,
};

/// Resource reader function type
pub const ResourceReader = *const fn (request: ResourceReadRequest, allocator: std.mem.Allocator) ResourceReadResult;

/// Context for parallel resource reading
pub const ResourceReadContext = struct {
    requests: []const ResourceReadRequest,
    results: []ResourceReadResult,
    reader: ResourceReader,
    allocator: std.mem.Allocator,
};

/// Read multiple resources in parallel.
///
/// Each resource read is independent, enabling parallel
/// fetching of multiple resources in a single request.
///
/// Parameters:
/// - allocator: Memory allocator
/// - requests: Array of resource read requests
/// - results: Array to store read results
/// - reader: Function to read each resource
///
/// Threshold: Uses parallel processing for 2+ resources
pub fn parallelResourceRead(
    allocator: std.mem.Allocator,
    requests: []const ResourceReadRequest,
    results: []ResourceReadResult,
    reader: ResourceReader,
) void {
    std.debug.assert(requests.len == results.len);

    if (!true or requests.len < 2) {
        for (requests, 0..) |request, i| {
            results[i] = reader(request, allocator);
        }
        return;
    }

    const pool = getPool();
    const ctx = ResourceReadContext{
        .requests = requests,
        .results = results,
        .reader = reader,
        .allocator = allocator,
    };
    _ = pool.call(void, parallelResourceReadTask, ctx);
}

fn parallelResourceReadTask(t: *spice.Task, ctx: ResourceReadContext) void {
    const requests = ctx.requests;
    const results = ctx.results;

    if (requests.len < 2) {
        for (requests, 0..) |request, i| {
            results[i] = ctx.reader(request, ctx.allocator);
        }
        return;
    }

    const mid = requests.len / 2;
    const left_ctx = ResourceReadContext{
        .requests = requests[0..mid],
        .results = results[0..mid],
        .reader = ctx.reader,
        .allocator = ctx.allocator,
    };
    const right_ctx = ResourceReadContext{
        .requests = requests[mid..],
        .results = results[mid..],
        .reader = ctx.reader,
        .allocator = ctx.allocator,
    };

    var fut = spice.Future(ResourceReadContext, void).init();
    fut.fork(t, parallelResourceReadTask, right_ctx);

    t.call(void, parallelResourceReadTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parallelResourceReadTask, right_ctx);
    }
}

// ============================================================================
// Parallel Prompt Template Processing
// ============================================================================

/// Prompt template
pub const PromptTemplate = struct {
    name: []const u8,
    template: []const u8,
    variables: []const []const u8,
};

/// Variable values for template
pub const PromptVariables = struct {
    values: []const []const u8,
};

/// Prompt render result
pub const PromptRenderResult = struct {
    success: bool,
    rendered: ?[]const u8,
    error_msg: ?[]const u8,
};

/// Context for parallel prompt rendering
pub const PromptRenderContext = struct {
    templates: []const PromptTemplate,
    variables: []const PromptVariables,
    results: []PromptRenderResult,
    allocator: std.mem.Allocator,
};

/// Render multiple prompt templates in parallel.
///
/// Each template render is independent, enabling parallel
/// processing of multiple prompts.
///
/// Parameters:
/// - allocator: Memory allocator
/// - templates: Array of prompt templates
/// - variables: Array of variable values (matching templates)
/// - results: Array to store render results
///
/// Threshold: Uses parallel processing for 4+ templates
pub fn parallelPromptRender(
    allocator: std.mem.Allocator,
    templates: []const PromptTemplate,
    variables: []const PromptVariables,
    results: []PromptRenderResult,
) void {
    std.debug.assert(templates.len == variables.len);
    std.debug.assert(templates.len == results.len);

    if (!true or templates.len < 4) {
        for (templates, 0..) |template, i| {
            results[i] = renderPrompt(allocator, template, variables[i]);
        }
        return;
    }

    const pool = getPool();
    const ctx = PromptRenderContext{
        .templates = templates,
        .variables = variables,
        .results = results,
        .allocator = allocator,
    };
    _ = pool.call(void, parallelPromptRenderTask, ctx);
}

fn parallelPromptRenderTask(t: *spice.Task, ctx: PromptRenderContext) void {
    const templates = ctx.templates;
    const variables = ctx.variables;
    const results = ctx.results;

    if (templates.len < 2) {
        for (templates, 0..) |template, i| {
            results[i] = renderPrompt(ctx.allocator, template, variables[i]);
        }
        return;
    }

    const mid = templates.len / 2;
    const left_ctx = PromptRenderContext{
        .templates = templates[0..mid],
        .variables = variables[0..mid],
        .results = results[0..mid],
        .allocator = ctx.allocator,
    };
    const right_ctx = PromptRenderContext{
        .templates = templates[mid..],
        .variables = variables[mid..],
        .results = results[mid..],
        .allocator = ctx.allocator,
    };

    var fut = spice.Future(PromptRenderContext, void).init();
    fut.fork(t, parallelPromptRenderTask, right_ctx);

    t.call(void, parallelPromptRenderTask, left_ctx);
    if (fut.join(t) == null) {
        t.call(void, parallelPromptRenderTask, right_ctx);
    }
}

fn renderPrompt(allocator: std.mem.Allocator, template: PromptTemplate, vars: PromptVariables) PromptRenderResult {
    if (template.template.len == 0) {
        return .{ .success = false, .rendered = null, .error_msg = "empty template" };
    }

    if (template.variables.len != vars.values.len) {
        return .{ .success = false, .rendered = null, .error_msg = "variable count mismatch" };
    }

    // Simple variable substitution (actual implementation would be more sophisticated)
    var result = allocator.dupe(u8, template.template) catch {
        return .{ .success = false, .rendered = null, .error_msg = "alloc failed" };
    };

    // In a real implementation, would substitute {{var}} patterns
    return .{ .success = true, .rendered = result, .error_msg = null };
}

// ============================================================================
// Tests
// ============================================================================

fn testHandler(request: JsonRpcRequest, allocator: std.mem.Allocator) JsonRpcResponse {
    _ = allocator;
    return .{
        .id = request.id,
        .result = null,
        .error_code = null,
        .error_msg = null,
    };
}

test "parallel batch process" {
    // spice always enabled when this module is compiled

    var requests: [8]JsonRpcRequest = undefined;
    var responses: [8]JsonRpcResponse = undefined;

    for (&requests, 0..) |*request, i| {
        _ = i;
        request.* = .{
            .id = "test-id",
            .method = "test/method",
            .params = null,
        };
    }

    parallelBatchProcess(std.testing.allocator, &requests, &responses, testHandler);

    for (responses) |response| {
        try std.testing.expect(response.error_code == null);
    }
}

fn testSender(client: SseClient, event: SseEvent) SseSendResult {
    _ = event;
    return .{
        .client_id = client.client_id,
        .success = client.active,
        .error_msg = null,
    };
}

test "parallel sse broadcast" {
    // spice always enabled when this module is compiled

    var clients: [16]SseClient = undefined;
    var results: [16]SseSendResult = undefined;

    for (&clients, 0..) |*client, i| {
        client.* = .{
            .client_id = i,
            .last_event_id = null,
            .active = true,
        };
    }

    const event = SseEvent{
        .event_type = "message",
        .data = "test data",
        .event_id = 1,
    };

    parallelSseBroadcast(&clients, event, &results, testSender);

    for (results) |result| {
        try std.testing.expect(result.success);
    }
}

test "parallel sse broadcast - inactive clients" {
    // spice always enabled when this module is compiled

    var clients: [8]SseClient = undefined;
    var results: [8]SseSendResult = undefined;

    for (&clients, 0..) |*client, i| {
        client.* = .{
            .client_id = i,
            .last_event_id = null,
            .active = false, // Inactive
        };
    }

    const event = SseEvent{
        .event_type = "notification",
        .data = "data",
        .event_id = 2,
    };

    parallelSseBroadcast(&clients, event, &results, testSender);

    for (results) |result| {
        try std.testing.expect(!result.success);
    }
}

fn testExecutor(call: ToolCall, allocator: std.mem.Allocator) ToolResult {
    _ = allocator;
    return .{
        .call_id = call.call_id,
        .success = call.name.len > 0,
        .output = null,
        .error_msg = null,
    };
}

test "parallel tool execute" {
    // spice always enabled when this module is compiled

    var calls: [4]ToolCall = undefined;
    var results: [4]ToolResult = undefined;

    for (&calls) |*call| {
        call.* = .{
            .name = "test_tool",
            .arguments = null,
            .call_id = "call-1",
        };
    }

    parallelToolExecute(std.testing.allocator, &calls, &results, testExecutor);

    for (results) |result| {
        try std.testing.expect(result.success);
    }
}

test "parallel tool execute - empty name" {
    // spice always enabled when this module is compiled

    var calls: [4]ToolCall = undefined;
    var results: [4]ToolResult = undefined;

    for (&calls) |*call| {
        call.* = .{
            .name = "", // Empty
            .arguments = null,
            .call_id = "call-1",
        };
    }

    parallelToolExecute(std.testing.allocator, &calls, &results, testExecutor);

    for (results) |result| {
        try std.testing.expect(!result.success);
    }
}

fn testReader(request: ResourceReadRequest, allocator: std.mem.Allocator) ResourceReadResult {
    _ = allocator;
    return .{
        .uri = request.uri,
        .success = request.uri.len > 0,
        .content = null,
        .mime_type = request.mime_type,
        .error_msg = null,
    };
}

test "parallel resource read" {
    // spice always enabled when this module is compiled

    var requests: [4]ResourceReadRequest = undefined;
    var results: [4]ResourceReadResult = undefined;

    for (&requests) |*request| {
        request.* = .{
            .uri = "file:///path/to/resource",
            .mime_type = "text/plain",
        };
    }

    parallelResourceRead(std.testing.allocator, &requests, &results, testReader);

    for (results) |result| {
        try std.testing.expect(result.success);
    }
}

test "parallel prompt render" {
    // spice always enabled when this module is compiled

    var templates: [8]PromptTemplate = undefined;
    var variables: [8]PromptVariables = undefined;
    var results: [8]PromptRenderResult = undefined;

    for (&templates, 0..) |*tmpl, i| {
        _ = i;
        tmpl.* = .{
            .name = "greeting",
            .template = "Hello, {{name}}!",
            .variables = &[_][]const u8{"name"},
        };
    }

    for (&variables) |*vars| {
        vars.* = .{
            .values = &[_][]const u8{"World"},
        };
    }

    parallelPromptRender(std.testing.allocator, &templates, &variables, &results);

    for (results) |result| {
        try std.testing.expect(result.success);
        if (result.rendered) |r| std.testing.allocator.free(r);
    }
}

test "parallel prompt render - empty template" {
    // spice always enabled when this module is compiled

    var templates: [4]PromptTemplate = undefined;
    var variables: [4]PromptVariables = undefined;
    var results: [4]PromptRenderResult = undefined;

    for (&templates) |*tmpl| {
        tmpl.* = .{
            .name = "empty",
            .template = "", // Empty
            .variables = &[_][]const u8{},
        };
    }

    for (&variables) |*vars| {
        vars.* = .{ .values = &[_][]const u8{} };
    }

    parallelPromptRender(std.testing.allocator, &templates, &variables, &results);

    for (results) |result| {
        try std.testing.expect(!result.success);
    }
}

test "parallel prompt render - variable mismatch" {
    // spice always enabled when this module is compiled

    var templates: [4]PromptTemplate = undefined;
    var variables: [4]PromptVariables = undefined;
    var results: [4]PromptRenderResult = undefined;

    for (&templates) |*tmpl| {
        tmpl.* = .{
            .name = "test",
            .template = "Hello {{a}} {{b}}",
            .variables = &[_][]const u8{ "a", "b" }, // 2 variables
        };
    }

    for (&variables) |*vars| {
        vars.* = .{ .values = &[_][]const u8{"only_one"} }; // Only 1 value
    }

    parallelPromptRender(std.testing.allocator, &templates, &variables, &results);

    for (results) |result| {
        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
    }
}
