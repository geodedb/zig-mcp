//! Resources and Prompts Example
//!
//! This example demonstrates how to implement:
//! - Resource providers (files, data, etc.)
//! - Resource templates for dynamic resources
//! - Resource subscriptions for change notifications
//! - Prompt templates with arguments
//!
//! To run this example:
//!   zig build run-example-resources

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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    result_allocator = allocator;

    const handler = createHandler();

    var server = try mcp.Server.init(allocator, .{
        .name = "resources-prompts-server",
        .version = "1.0.0",
        .instructions =
        \\This server demonstrates MCP resources and prompts:
        \\
        \\Resources:
        \\- config://app/settings - Application configuration
        \\- data://users/{id} - User data (template)
        \\
        \\Prompts:
        \\- summarize - Summarize text with customizable style
        \\- code-review - Review code with focus area
        ,
    }, handler);
    defer server.deinit();

    std.debug.print("Resources & Prompts Server started.\n", .{});
    std.debug.print("Waiting for requests on stdin...\n\n", .{});

    try server.serveStdio();
}

// ============================================================================
// Handler Implementation
// ============================================================================

fn createHandler() mcp.Handler {
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

// ============================================================================
// Resource Implementation
// ============================================================================

/// Lists available static resources
fn listResources(_: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    // Pagination support: cursor indicates where to resume
    _ = cursor;

    // Return list of static resources
    // Each resource has:
    // - uri: Unique identifier for the resource
    // - name: Human-readable name
    // - description: Optional description
    // - mimeType: Content type of the resource
    return owned(
        \\{"resources":[
        \\  {
        \\    "uri": "config://app/settings",
        \\    "name": "Application Settings",
        \\    "description": "Current application configuration",
        \\    "mimeType": "application/json"
        \\  },
        \\  {
        \\    "uri": "config://app/version",
        \\    "name": "Version Info",
        \\    "description": "Application version information",
        \\    "mimeType": "application/json"
        \\  },
        \\  {
        \\    "uri": "data://readme",
        \\    "name": "README",
        \\    "description": "Server documentation",
        \\    "mimeType": "text/markdown"
        \\  }
        \\]}
    );
}

/// Reads a specific resource
fn readResource(_: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
    // Route based on URI scheme and path
    if (std.mem.eql(u8, uri, "config://app/settings")) {
        // Return resource content
        // The response contains a "contents" array with the resource data
        return owned(
            \\{"contents":[{
            \\  "uri": "config://app/settings",
            \\  "mimeType": "application/json",
            \\  "text": "{\"theme\":\"dark\",\"language\":\"en\",\"notifications\":true}"
            \\}]}
        );
    }

    if (std.mem.eql(u8, uri, "config://app/version")) {
        return owned(
            \\{"contents":[{
            \\  "uri": "config://app/version",
            \\  "mimeType": "application/json",
            \\  "text": "{\"version\":\"1.0.0\",\"build\":\"2025.01.24\",\"commit\":\"abc123\"}"
            \\}]}
        );
    }

    if (std.mem.eql(u8, uri, "data://readme")) {
        return owned(
            \\{"contents":[{
            \\  "uri": "data://readme",
            \\  "mimeType": "text/markdown",
            \\  "text": "# MCP Resources Example\n\nThis server demonstrates resource handling in MCP.\n\n## Available Resources\n\n- config://app/settings\n- config://app/version\n- data://readme"
            \\}]}
        );
    }

    // Check for template-based resources (users)
    if (std.mem.startsWith(u8, uri, "data://users/")) {
        const user_id = uri["data://users/".len..];
        _ = user_id;

        // In a real implementation, you would look up the user
        return owned(
            \\{"contents":[{
            \\  "uri": "data://users/123",
            \\  "mimeType": "application/json",
            \\  "text": "{\"id\":123,\"name\":\"Example User\",\"email\":\"user@example.com\"}"
            \\}]}
        );
    }

    return error.ResourceNotFound;
}

/// Lists resource templates for dynamic resources
fn listResourceTemplates(_: ?*anyopaque) anyerror![]const u8 {
    // Resource templates define patterns for dynamic resources
    // The {id} placeholder in the URI is filled in by the client
    return owned(
        \\{"resourceTemplates":[
        \\  {
        \\    "uriTemplate": "data://users/{id}",
        \\    "name": "User Data",
        \\    "description": "Retrieve user information by ID",
        \\    "mimeType": "application/json"
        \\  },
        \\  {
        \\    "uriTemplate": "data://files/{path}",
        \\    "name": "File Contents",
        \\    "description": "Read file contents by path",
        \\    "mimeType": "application/octet-stream"
        \\  }
        \\]}
    );
}

/// Subscribe to resource changes
fn subscribeResource(_: ?*anyopaque, uri: []const u8) anyerror!void {
    // In a real implementation, you would:
    // 1. Track the subscription
    // 2. Monitor the resource for changes
    // 3. Send notifications/resources/updated when changes occur
    std.debug.print("Client subscribed to: {s}\n", .{uri});
}

/// Unsubscribe from resource changes
fn unsubscribeResource(_: ?*anyopaque, uri: []const u8) anyerror!void {
    std.debug.print("Client unsubscribed from: {s}\n", .{uri});
}

// ============================================================================
// Prompt Implementation
// ============================================================================

/// Lists available prompt templates
fn listPrompts(_: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    _ = cursor;

    // Prompts are reusable templates that clients can invoke
    // Arguments allow customization of the prompt
    return owned(
        \\{"prompts":[
        \\  {
        \\    "name": "summarize",
        \\    "title": "Text Summarizer",
        \\    "description": "Summarize text content with customizable style and length",
        \\    "arguments": [
        \\      {
        \\        "name": "text",
        \\        "description": "The text to summarize",
        \\        "required": true
        \\      },
        \\      {
        \\        "name": "style",
        \\        "description": "Summary style: brief, detailed, or bullet-points",
        \\        "required": false
        \\      },
        \\      {
        \\        "name": "maxLength",
        \\        "description": "Maximum length in words",
        \\        "required": false
        \\      }
        \\    ]
        \\  },
        \\  {
        \\    "name": "code-review",
        \\    "title": "Code Reviewer",
        \\    "description": "Review code for issues, style, and improvements",
        \\    "arguments": [
        \\      {
        \\        "name": "code",
        \\        "description": "The code to review",
        \\        "required": true
        \\      },
        \\      {
        \\        "name": "language",
        \\        "description": "Programming language of the code",
        \\        "required": true
        \\      },
        \\      {
        \\        "name": "focus",
        \\        "description": "Focus area: security, performance, style, all",
        \\        "required": false
        \\      }
        \\    ]
        \\  },
        \\  {
        \\    "name": "explain",
        \\    "title": "Concept Explainer",
        \\    "description": "Explain a concept at a specified level",
        \\    "arguments": [
        \\      {
        \\        "name": "topic",
        \\        "description": "The topic or concept to explain",
        \\        "required": true
        \\      },
        \\      {
        \\        "name": "level",
        \\        "description": "Explanation level: beginner, intermediate, expert",
        \\        "required": false
        \\      }
        \\    ]
        \\  }
        \\]}
    );
}

/// Gets a specific prompt with arguments filled in
fn getPrompt(_: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8 {
    _ = args_json; // In a real implementation, parse and use these

    // Return the prompt as messages for the LLM
    // The response contains a "messages" array following the standard format

    if (std.mem.eql(u8, name, "summarize")) {
        return owned(
            \\{"description":"Summarize the provided text","messages":[
            \\  {
            \\    "role": "user",
            \\    "content": {
            \\      "type": "text",
            \\      "text": "Please summarize the following text in a concise manner:\n\n[Text will be inserted here based on the 'text' argument]"
            \\    }
            \\  }
            \\]}
        );
    }

    if (std.mem.eql(u8, name, "code-review")) {
        return owned(
            \\{"description":"Review code for quality and issues","messages":[
            \\  {
            \\    "role": "user",
            \\    "content": {
            \\      "type": "text",
            \\      "text": "Please review the following code and provide feedback on:\n1. Potential bugs or issues\n2. Code style and readability\n3. Performance considerations\n4. Suggested improvements\n\n```\n[Code will be inserted here]\n```"
            \\    }
            \\  }
            \\]}
        );
    }

    if (std.mem.eql(u8, name, "explain")) {
        return owned(
            \\{"description":"Explain a concept clearly","messages":[
            \\  {
            \\    "role": "user",
            \\    "content": {
            \\      "type": "text",
            \\      "text": "Please explain the following concept:\n\n[Topic will be inserted here]\n\nProvide a clear, step-by-step explanation suitable for the specified level."
            \\    }
            \\  }
            \\]}
        );
    }

    return error.PromptNotFound;
}

// ============================================================================
// Completion Support
// ============================================================================

/// Provides autocompletion suggestions
fn complete(_: ?*anyopaque, params_json: []const u8) anyerror![]const u8 {
    // The params contain reference type (prompt or resource) and partial input
    // Return matching suggestions
    _ = params_json;

    // Example: return empty completions
    // In a real implementation, parse params and return relevant suggestions
    return owned(
        \\{"completion":{"values":["example-completion-1","example-completion-2"],"hasMore":false}}
    );
}

// ============================================================================
// Tool stubs (minimal for this example)
// ============================================================================

fn listTools(_: ?*anyopaque, _: ?[]const u8) anyerror![]const u8 {
    return owned("{\"tools\":[]}");
}

fn callTool(_: ?*anyopaque, _: []const u8, _: []const u8, _: *const mcp.CancelToken) anyerror![]const u8 {
    return error.ToolNotFound;
}

fn setLogLevel(_: ?*anyopaque, _: []const u8) anyerror!void {}
