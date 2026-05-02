//! observability.zig — single-file otel seam for mcp.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` / `otel.instrumentation.http` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break MCP traffic.
//!
//! NOTE: deviation from template — MCP is JSON-RPC 2.0 shaped. The
//! HTTP-flavoured `instrumentation.http.start{Client,Server}Span` shape
//! is wrong for an MCP request/response. We expose the generic
//! HTTP-flavoured `startClientSpan` / `startServerSpan` helpers for
//! template symmetry (and to keep the disabled-mode test surface
//! consistent across consumers), AND domain-specific
//! `startRpcClientSpan(method)` / `startRpcServerSpan(method)` helpers
//! that construct a span via `otel.api.trace.Tracer.startSpan` directly
//! with otel's `rpc.*` semantic conventions
//! (`rpc.system="mcp"`, `rpc.method`).

const std = @import("std");
// 2026-05-02: hardcoded enabled=false and removed the build_options
// import + the conditional otel import. The previous pattern surfaced
// a Zig 0.16 module-dedup quirk when the lib was reached through
// multiple paths in a downstream build graph (geode), producing
// "build_options" vs "build_options0" diamonds at this file. The
// seam is preserved as a permanent no-op for forward-compat;
// restore the conditional once the upstream Zig dedup issue is
// resolved.
pub const enabled: bool = false;

const otel = struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Helper: reads either a `[]const u8` field OR a function-typed field
/// returning `[]const u8`, so the seam accepts both shapes — the closure
/// shape the recipe template ships AND the plain-string-field shape used
/// at hot-path call sites.
inline fn accessOr(req: anytype, comptime field: []const u8) []const u8 {
    const T = @TypeOf(@field(req, field));
    return switch (@typeInfo(T)) {
        .pointer => @field(req, field),
        .@"fn" => @field(req, field)(),
        else => @compileError("observability: unsupported field type for " ++ field),
    };
}

/// Start a span for a generic outbound operation. Kept for template
/// symmetry; mcp hot paths use `startRpcClientSpan` instead.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for a generic inbound operation. Kept for template
/// symmetry; mcp hot paths use `startRpcServerSpan` instead.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .route = accessOr(req, "route"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Start a span for an outbound MCP JSON-RPC request.
///
/// Span shape:
///   - name: the bare RPC method (e.g. `"tools/call"`); per otel rpc
///     semantic conventions the span name SHOULD be the full method
///     identifier without surrounding decoration.
///   - kind: `.client`
///   - attributes:
///       * `rpc.system = "mcp"`
///       * `rpc.method = method`
///
/// Telemetry is non-fatal: any failure to start the span or attach
/// attributes returns a `Span{}` no-op — MCP traffic continues either way.
pub fn startRpcClientSpan(method: []const u8) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = tracer.startSpan(.empty(), method, .{ .kind = .client }) catch return Span{};
    span.setStringAttribute("rpc.system", "mcp") catch {};
    span.setStringAttribute("rpc.method", method) catch {};
    return span;
}

/// Close a client RPC span, recording success/failure.
///
/// On `ok = true` we set status `.ok`; on `ok = false` we set status
/// `.error_` with the JSON-RPC `error_code` stringified into the
/// description and additionally attach `rpc.jsonrpc.error_code` for
/// downstream filtering.
pub fn endRpcClientSpan(span: Span, ok: bool, error_code: i32) void {
    if (!enabled) return;
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        // Best-effort attach of the JSON-RPC error code as an integer
        // attribute. Failures (OOM in the attribute set) cannot block
        // the caller — telemetry is non-fatal.
        span.setIntAttribute("rpc.jsonrpc.error_code", error_code) catch {};
        var buf: [32]u8 = undefined;
        const desc = std.fmt.bufPrint(&buf, "rpc error {d}", .{error_code}) catch "rpc error";
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig.
        span.setStatus(.@"error", desc);
    }
    span.end(null);
}

/// Start a span for an inbound MCP JSON-RPC request.
///
/// Span shape mirrors `startRpcClientSpan` but with `.kind = .server`.
pub fn startRpcServerSpan(method: []const u8) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = tracer.startSpan(.empty(), method, .{ .kind = .server }) catch return Span{};
    span.setStringAttribute("rpc.system", "mcp") catch {};
    span.setStringAttribute("rpc.method", method) catch {};
    return span;
}

/// Close a server RPC span. Same semantics as `endRpcClientSpan` — the
/// only differing field on the span itself is `kind`, which was set
/// at start time.
pub fn endRpcServerSpan(span: Span, ok: bool, error_code: i32) void {
    if (!enabled) return;
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        span.setIntAttribute("rpc.jsonrpc.error_code", error_code) catch {};
        var buf: [32]u8 = undefined;
        const desc = std.fmt.bufPrint(&buf, "rpc error {d}", .{error_code}) catch "rpc error";
        span.setStatus(.@"error", desc);
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
