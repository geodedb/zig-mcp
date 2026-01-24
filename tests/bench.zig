//! Performance Benchmarks for MCP Library
//!
//! Comprehensive benchmarks for:
//! - JSON parsing throughput
//! - JSON-RPC message handling
//! - WebSocket frame encoding/decoding
//! - HTTP request/response processing
//! - Memory allocation patterns
//!
//! Usage:
//!   zig build bench -- [options]

const std = @import("std");
const json = @import("json");
const mcp = @import("mcp");

/// Benchmark result statistics
pub const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_time_ns: u64,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_bytes: u64 = 0,

    pub fn mean_ns(self: BenchResult) f64 {
        if (self.iterations == 0) return 0;
        return @as(f64, @floatFromInt(self.total_time_ns)) / @as(f64, @floatFromInt(self.iterations));
    }

    pub fn ops_per_sec(self: BenchResult) f64 {
        if (self.total_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(self.total_time_ns));
    }

    pub fn throughput_mb_per_sec(self: BenchResult) f64 {
        if (self.total_time_ns == 0) return 0;
        const bytes_per_sec = @as(f64, @floatFromInt(self.total_bytes)) * 1_000_000_000.0 / @as(f64, @floatFromInt(self.total_time_ns));
        return bytes_per_sec / (1024 * 1024);
    }

    pub fn print(self: BenchResult) void {
        std.debug.print("{s}:\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0});
        std.debug.print("  Mean: {d:.2} ns/op\n", .{self.mean_ns()});
        std.debug.print("  Min: {d} ns, Max: {d} ns\n", .{ self.min_ns, self.max_ns });
        std.debug.print("  Ops/sec: {d:.0}\n", .{self.ops_per_sec()});
        if (self.total_bytes > 0) {
            std.debug.print("  Throughput: {d:.2} MB/s\n", .{self.throughput_mb_per_sec()});
        }
        std.debug.print("\n", .{});
    }
};

/// Benchmark configuration
pub const BenchConfig = struct {
    /// Minimum benchmark duration in nanoseconds
    min_duration_ns: u64 = 1_000_000_000, // 1 second
    /// Maximum iterations
    max_iterations: u64 = 10_000_000,
    /// Warmup iterations
    warmup_iterations: u64 = 1000,
    /// Number of benchmark runs for statistical significance
    runs: u32 = 3,
};

/// Timer for benchmarking
pub const Timer = struct {
    start_time: i128,

    pub fn start() Timer {
        return .{ .start_time = std.time.nanoTimestamp() };
    }

    pub fn elapsed(self: Timer) u64 {
        const end = std.time.nanoTimestamp();
        return @intCast(end - self.start_time);
    }
};

/// Benchmark runner
pub fn runBenchmark(
    name: []const u8,
    config: BenchConfig,
    comptime benchFn: fn (*std.mem.Allocator) u64,
) BenchResult {
    var allocator = std.heap.page_allocator;

    // Warmup
    var i: u64 = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        _ = benchFn(&allocator);
    }

    // Run benchmark
    var result = BenchResult{
        .name = name,
        .iterations = 0,
        .total_time_ns = 0,
    };

    const timer = Timer.start();
    while (result.total_time_ns < config.min_duration_ns and result.iterations < config.max_iterations) {
        const iter_start = std.time.nanoTimestamp();
        result.total_bytes += benchFn(&allocator);
        const iter_time: u64 = @intCast(std.time.nanoTimestamp() - iter_start);

        result.min_ns = @min(result.min_ns, iter_time);
        result.max_ns = @max(result.max_ns, iter_time);
        result.iterations += 1;
        result.total_time_ns = timer.elapsed();
    }

    return result;
}

// ============================================================================
// JSON Parsing Benchmarks
// ============================================================================

const sample_json_small = "{\"id\":1,\"method\":\"test\",\"params\":{}}";
const sample_json_medium =
    \\{"jsonrpc":"2.0","id":12345,"method":"tools/call","params":{"name":"calculator","arguments":{"operation":"add","a":42,"b":58}}}
;
// Large sample JSON - generated at comptime using string concatenation
const sample_json_large = "{\"items\":[" ++
    "{\"id\":0,\"name\":\"item0\",\"value\":0}," ++
    "{\"id\":1,\"name\":\"item1\",\"value\":100}," ++
    "{\"id\":2,\"name\":\"item2\",\"value\":200}," ++
    "{\"id\":3,\"name\":\"item3\",\"value\":300}," ++
    "{\"id\":4,\"name\":\"item4\",\"value\":400}," ++
    "{\"id\":5,\"name\":\"item5\",\"value\":500}," ++
    "{\"id\":6,\"name\":\"item6\",\"value\":600}," ++
    "{\"id\":7,\"name\":\"item7\",\"value\":700}," ++
    "{\"id\":8,\"name\":\"item8\",\"value\":800}," ++
    "{\"id\":9,\"name\":\"item9\",\"value\":900}," ++
    "{\"id\":10,\"name\":\"item10\",\"value\":1000}," ++
    "{\"id\":11,\"name\":\"item11\",\"value\":1100}," ++
    "{\"id\":12,\"name\":\"item12\",\"value\":1200}," ++
    "{\"id\":13,\"name\":\"item13\",\"value\":1300}," ++
    "{\"id\":14,\"name\":\"item14\",\"value\":1400}," ++
    "{\"id\":15,\"name\":\"item15\",\"value\":1500}," ++
    "{\"id\":16,\"name\":\"item16\",\"value\":1600}," ++
    "{\"id\":17,\"name\":\"item17\",\"value\":1700}," ++
    "{\"id\":18,\"name\":\"item18\",\"value\":1800}," ++
    "{\"id\":19,\"name\":\"item19\",\"value\":1900}" ++
    "]}";

fn benchJsonParseSmall(allocator: *std.mem.Allocator) u64 {
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();

    var err_info = json.ParseError.init();
    var doc = json.parse(arena.allocator(), sample_json_small, .{}, &err_info) catch return 0;
    doc.deinit();
    return sample_json_small.len;
}

fn benchJsonParseMedium(allocator: *std.mem.Allocator) u64 {
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();

    var err_info = json.ParseError.init();
    var doc = json.parse(arena.allocator(), sample_json_medium, .{}, &err_info) catch return 0;
    doc.deinit();
    return sample_json_medium.len;
}

fn benchJsonParseLarge(allocator: *std.mem.Allocator) u64 {
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();

    var err_info = json.ParseError.init();
    var doc = json.parse(arena.allocator(), sample_json_large, .{}, &err_info) catch return 0;
    doc.deinit();
    return sample_json_large.len;
}

// ============================================================================
// WebSocket Frame Benchmarks
// ============================================================================

fn benchWebSocketEncode(allocator: *std.mem.Allocator) u64 {
    _ = allocator;
    const payload = "Hello, WebSocket!";
    var frame: [128]u8 = undefined;

    // Build text frame
    frame[0] = 0x81; // FIN + Text opcode
    if (payload.len < 126) {
        frame[1] = @intCast(payload.len);
        @memcpy(frame[2 .. 2 + payload.len], payload);
    }

    return 2 + payload.len;
}

fn benchWebSocketDecode(_: *std.mem.Allocator) u64 {
    const frame = [_]u8{ 0x81, 0x11 } ++ "Hello, WebSocket!";

    // Parse frame
    const opcode = frame[0] & 0x0F;
    _ = opcode;
    const payload_len = frame[1] & 0x7F;
    const payload = frame[2 .. 2 + payload_len];
    _ = payload;

    return frame.len;
}

// ============================================================================
// HTTP Parsing Benchmarks
// ============================================================================

const sample_http_request =
    "POST /mcp HTTP/1.1\r\n" ++
    "Host: localhost:8080\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 42\r\n" ++
    "Accept: application/json\r\n" ++
    "User-Agent: mcp-client/1.0\r\n" ++
    "\r\n";

fn benchHttpParse(_: *std.mem.Allocator) u64 {
    // Parse HTTP headers
    const header_end = std.mem.indexOf(u8, sample_http_request, "\r\n\r\n") orelse return 0;
    const headers = sample_http_request[0..header_end];

    var lines = std.mem.splitSequence(u8, headers, "\r\n");

    // Parse request line
    const request_line = lines.next() orelse return 0;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    _ = parts.next(); // method
    _ = parts.next(); // path
    _ = parts.next(); // version

    // Parse headers
    var header_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = std.mem.indexOf(u8, line, ":");
        header_count += 1;
    }

    return sample_http_request.len;
}

// ============================================================================
// Memory Allocation Benchmarks
// ============================================================================

fn benchArenaAlloc(allocator: *std.mem.Allocator) u64 {
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();

    var total: usize = 0;
    for (0..100) |_| {
        const buf = arena.allocator().alloc(u8, 256) catch continue;
        total += buf.len;
    }

    return total;
}

fn benchGeneralPurposeAlloc(_: *std.mem.Allocator) u64 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var total: usize = 0;
    var ptrs: [100][]u8 = undefined;

    for (0..100) |i| {
        ptrs[i] = alloc.alloc(u8, 256) catch continue;
        total += ptrs[i].len;
    }

    for (0..100) |i| {
        alloc.free(ptrs[i]);
    }

    return total;
}

// ============================================================================
// Concurrent Operation Benchmarks
// ============================================================================

fn benchMutexContention(_: *std.mem.Allocator) u64 {
    var mutex = std.Thread.Mutex{};
    var counter: u64 = 0;

    for (0..1000) |_| {
        mutex.lock();
        counter += 1;
        mutex.unlock();
    }

    return counter;
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    std.debug.print("MCP Performance Benchmarks\n", .{});
    std.debug.print("==========================\n\n", .{});

    // Use heap allocator for Windows compatibility
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var run_all = true;
    var run_json = false;
    var run_websocket = false;
    var run_http = false;
    var run_memory = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            run_json = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "--websocket")) {
            run_websocket = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "--http")) {
            run_http = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            run_memory = true;
            run_all = false;
        }
    }

    const config = BenchConfig{};

    // JSON Benchmarks
    if (run_all or run_json) {
        std.debug.print("=== JSON Parsing ===\n\n", .{});
        runBenchmark("JSON Parse (small)", config, benchJsonParseSmall).print();
        runBenchmark("JSON Parse (medium)", config, benchJsonParseMedium).print();
        runBenchmark("JSON Parse (large)", config, benchJsonParseLarge).print();
    }

    // WebSocket Benchmarks
    if (run_all or run_websocket) {
        std.debug.print("=== WebSocket Frames ===\n\n", .{});
        runBenchmark("WebSocket Encode", config, benchWebSocketEncode).print();
        runBenchmark("WebSocket Decode", config, benchWebSocketDecode).print();
    }

    // HTTP Benchmarks
    if (run_all or run_http) {
        std.debug.print("=== HTTP Parsing ===\n\n", .{});
        runBenchmark("HTTP Parse", config, benchHttpParse).print();
    }

    // Memory Benchmarks
    if (run_all or run_memory) {
        std.debug.print("=== Memory Allocation ===\n\n", .{});
        runBenchmark("Arena Allocator", config, benchArenaAlloc).print();
        runBenchmark("General Purpose Allocator", config, benchGeneralPurposeAlloc).print();
        runBenchmark("Mutex Contention", config, benchMutexContention).print();
    }

    std.debug.print("Benchmarks complete.\n", .{});
}

fn printUsage() void {
    const usage =
        \\MCP Performance Benchmarks
        \\
        \\Usage: bench [options]
        \\
        \\Options:
        \\  --json        Run JSON parsing benchmarks
        \\  --websocket   Run WebSocket frame benchmarks
        \\  --http        Run HTTP parsing benchmarks
        \\  --memory      Run memory allocation benchmarks
        \\  --help, -h    Show this help
        \\
        \\Without options, runs all benchmarks.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// ============================================================================
// Tests
// ============================================================================

test "benchmark result statistics" {
    var result = BenchResult{
        .name = "test",
        .iterations = 1000,
        .total_time_ns = 1_000_000, // 1ms
        .total_bytes = 1024 * 1000,
    };

    try std.testing.expectEqual(@as(f64, 1000.0), result.mean_ns());
    try std.testing.expectEqual(@as(f64, 1_000_000_000.0), result.ops_per_sec());
}

test "timer accuracy" {
    const timer = Timer.start();
    std.time.sleep(1_000_000); // 1ms
    const elapsed = timer.elapsed();
    try std.testing.expect(elapsed >= 900_000 and elapsed <= 10_000_000);
}
