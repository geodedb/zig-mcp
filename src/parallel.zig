// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel MCP operations using thread-pool submit/WaitGroup scheduling.
//!
//! Provides high-performance parallel implementations for MCP operations
//! including JSON-RPC batch processing, SSE broadcasting, tool execution,
//! and resource reading.
//!
//! ## Overview
//!
//! This module enables parallel processing of Model Context Protocol
//! operations using the thread-pool library. Ideal for MCP servers handling
//! multiple clients or batch requests.
//!
//! ## Build Configuration
//!
//! Enable: `-Dthread-pool=true` (default)
//! Disable: `-Dthread-pool=false`
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
const tp = @import("thread_pool");

// ============================================================================
// Global Thread Pool
// ============================================================================

const MAX_CHUNKS = 64;

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: std.Io.Mutex = std.Io.Mutex.init;

pub fn getPool() *tp.ThreadPool {
    pool_mutex.lockUncancelable(io());
    defer pool_mutex.unlock(io());

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch
            @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    pool_mutex.lockUncancelable(io());
    defer pool_mutex.unlock(io());

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

/// Chunk context for parallel batch processing
const BatchProcessChunk = struct {
    requests: []const JsonRpcRequest,
    responses: []JsonRpcResponse,
    handler: RequestHandler,
    allocator: std.mem.Allocator,
};

fn batchProcessChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *BatchProcessChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.requests, 0..) |request, i| {
        chunk.responses[i] = chunk.handler(request, chunk.allocator);
    }
}

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

    if (requests.len < 4) {
        for (requests, 0..) |request, i| {
            responses[i] = handler(request, allocator);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(1, requests.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]BatchProcessChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < requests.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, requests.len);
        chunks[n] = .{
            .requests = requests[i..end],
            .responses = responses[i..end],
            .handler = handler,
            .allocator = allocator,
        };
        batch[n] = .{ .task_fn = &batchProcessChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (requests, 0..) |request, j| {
            responses[j] = handler(request, allocator);
        }
        return;
    };
    wg.wait();
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

/// Chunk context for parallel SSE broadcast
const SseBroadcastChunk = struct {
    clients: []const SseClient,
    event: SseEvent,
    results: []SseSendResult,
    sender: SseSender,
};

fn sseBroadcastChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *SseBroadcastChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.clients, 0..) |client, i| {
        chunk.results[i] = chunk.sender(client, chunk.event);
    }
}

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

    if (clients.len < 8) {
        for (clients, 0..) |client, i| {
            results[i] = sender(client, event);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(1, clients.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]SseBroadcastChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < clients.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, clients.len);
        chunks[n] = .{
            .clients = clients[i..end],
            .event = event,
            .results = results[i..end],
            .sender = sender,
        };
        batch[n] = .{ .task_fn = &sseBroadcastChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (clients, 0..) |client, j| {
            results[j] = sender(client, event);
        }
        return;
    };
    wg.wait();
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

/// Chunk context for parallel tool execution
const ToolExecuteChunk = struct {
    calls: []const ToolCall,
    results: []ToolResult,
    executor: ToolExecutor,
    allocator: std.mem.Allocator,
};

fn toolExecuteChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ToolExecuteChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.calls, 0..) |call, i| {
        chunk.results[i] = chunk.executor(call, chunk.allocator);
    }
}

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

    if (calls.len < 2) {
        for (calls, 0..) |call, i| {
            results[i] = executor(call, allocator);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(1, calls.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]ToolExecuteChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < calls.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, calls.len);
        chunks[n] = .{
            .calls = calls[i..end],
            .results = results[i..end],
            .executor = executor,
            .allocator = allocator,
        };
        batch[n] = .{ .task_fn = &toolExecuteChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (calls, 0..) |call, j| {
            results[j] = executor(call, allocator);
        }
        return;
    };
    wg.wait();
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

/// Chunk context for parallel resource reading
const ResourceReadChunk = struct {
    requests: []const ResourceReadRequest,
    results: []ResourceReadResult,
    reader: ResourceReader,
    allocator: std.mem.Allocator,
};

fn resourceReadChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *ResourceReadChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.requests, 0..) |request, i| {
        chunk.results[i] = chunk.reader(request, chunk.allocator);
    }
}

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

    if (requests.len < 2) {
        for (requests, 0..) |request, i| {
            results[i] = reader(request, allocator);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(1, requests.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]ResourceReadChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < requests.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, requests.len);
        chunks[n] = .{
            .requests = requests[i..end],
            .results = results[i..end],
            .reader = reader,
            .allocator = allocator,
        };
        batch[n] = .{ .task_fn = &resourceReadChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (requests, 0..) |request, j| {
            results[j] = reader(request, allocator);
        }
        return;
    };
    wg.wait();
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

/// Chunk context for parallel prompt rendering
const PromptRenderChunk = struct {
    templates: []const PromptTemplate,
    variables: []const PromptVariables,
    results: []PromptRenderResult,
    allocator: std.mem.Allocator,
};

fn promptRenderChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *PromptRenderChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.templates, 0..) |template, i| {
        chunk.results[i] = renderPrompt(chunk.allocator, template, chunk.variables[i]);
    }
}

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

    if (templates.len < 4) {
        for (templates, 0..) |template, i| {
            results[i] = renderPrompt(allocator, template, variables[i]);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(1, templates.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]PromptRenderChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < templates.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, templates.len);
        chunks[n] = .{
            .templates = templates[i..end],
            .variables = variables[i..end],
            .results = results[i..end],
            .allocator = allocator,
        };
        batch[n] = .{ .task_fn = &promptRenderChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (templates, 0..) |template, j| {
            results[j] = renderPrompt(allocator, template, variables[j]);
        }
        return;
    };
    wg.wait();
}

fn renderPrompt(allocator: std.mem.Allocator, template: PromptTemplate, vars: PromptVariables) PromptRenderResult {
    if (template.template.len == 0) {
        return .{ .success = false, .rendered = null, .error_msg = "empty template" };
    }

    if (template.variables.len != vars.values.len) {
        return .{ .success = false, .rendered = null, .error_msg = "variable count mismatch" };
    }

    // Simple variable substitution (actual implementation would be more sophisticated)
    const result = allocator.dupe(u8, template.template) catch {
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
    var requests: [8]JsonRpcRequest = undefined;
    var responses: [8]JsonRpcResponse = undefined;

    for (&requests) |*request| {
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
    var templates: [8]PromptTemplate = undefined;
    var variables: [8]PromptVariables = undefined;
    var results: [8]PromptRenderResult = undefined;

    for (&templates) |*tmpl| {
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
