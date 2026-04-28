//! Verifies one MCP RPC span lands in an in-memory recorder when
//! `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from template — we exercise the seam directly via
//! the in-memory recorder rather than driving a real MCP request/
//! response round-trip. Real round-trips need a live transport; the
//! seam's behaviour is identical: `startRpcClientSpan` ->
//! `endRpcClientSpan` enters and leaves one tracer span.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const mcp = @import("mcp");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one MCP RPC client span recorded when otel enabled" {
    if (!mcp.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "mcp-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "mcp-test" });
    mcp.observability.global.tracer = &tracer;
    defer mcp.observability.global.tracer = null;

    const span = mcp.observability.startRpcClientSpan("test/method");
    mcp.observability.endRpcClientSpan(span, true, 0);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Verify span name shape: bare RPC method per otel rpc semantic
    // conventions.
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("test/method", recorded.name);

    // Verify rpc.system + rpc.method attributes landed on the span. The
    // in-memory recorder stores attributes as `[]KV` (string-stringified
    // key/value pairs) — see otel/src/exporters/in_memory.zig.
    var found_system: ?[]const u8 = null;
    var found_method: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "rpc.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "rpc.method")) {
            found_method = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingRpcSystemAttribute;
    try std.testing.expectEqualStrings("mcp", system_value);
    const method_value = found_method orelse return error.MissingRpcMethodAttribute;
    try std.testing.expectEqualStrings("test/method", method_value);
}

test "one MCP RPC server span recorded when otel enabled" {
    if (!mcp.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "mcp-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "mcp-test" });
    mcp.observability.global.tracer = &tracer;
    defer mcp.observability.global.tracer = null;

    const span = mcp.observability.startRpcServerSpan("tools/list");
    mcp.observability.endRpcServerSpan(span, true, 0);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);
    try std.testing.expectEqualStrings("tools/list", recorder.spans.items[0].name);
}
