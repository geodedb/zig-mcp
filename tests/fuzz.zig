//! Fuzz Testing for MCP Parsers
//!
//! Provides fuzz testing infrastructure for:
//! - JSON-RPC message parsing
//! - WebSocket frame parsing
//! - HTTP header parsing
//!
//! Usage:
//!   zig build fuzz -- --corpus corpus/ --iterations 1000000

const std = @import("std");
const json = @import("json");
const mcp = @import("mcp");

/// Fuzz test result
pub const FuzzResult = struct {
    iterations: u64,
    crashes: u64,
    hangs: u64,
    coverage_paths: u64,
    unique_errors: std.StringHashMap(u64),

    pub fn init(allocator: std.mem.Allocator) FuzzResult {
        return .{
            .iterations = 0,
            .crashes = 0,
            .hangs = 0,
            .coverage_paths = 0,
            .unique_errors = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *FuzzResult) void {
        self.unique_errors.deinit();
    }

    pub fn recordError(self: *FuzzResult, err_name: []const u8) void {
        if (self.unique_errors.getPtr(err_name)) |count| {
            count.* += 1;
        } else {
            self.unique_errors.put(err_name, 1) catch {};
        }
    }
};

/// Fuzz configuration
pub const FuzzConfig = struct {
    /// Maximum input size
    max_input_size: usize = 65536,
    /// Number of iterations
    iterations: u64 = 1000000,
    /// Timeout per iteration (ms)
    timeout_ms: u64 = 100,
    /// Seed for reproducibility (0 = random)
    seed: u64 = 0,
    /// Corpus directory
    corpus_dir: ?[]const u8 = null,
    /// Enable coverage-guided fuzzing
    coverage_guided: bool = true,
};

/// Fuzz target function type
pub const FuzzTarget = *const fn ([]const u8) void;

/// Fuzzer engine
pub const Fuzzer = struct {
    allocator: std.mem.Allocator,
    config: FuzzConfig,
    prng: std.Random.DefaultPrng,
    result: FuzzResult,
    corpus: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, config: FuzzConfig) Fuzzer {
        const seed = if (config.seed == 0) blk: {
            var buf: [8]u8 = undefined;
            std.crypto.random.bytes(&buf);
            break :blk std.mem.readInt(u64, &buf, .little);
        } else config.seed;

        return .{
            .allocator = allocator,
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
            .result = FuzzResult.init(allocator),
            .corpus = .{},
        };
    }

    fn rng(self: *Fuzzer) std.Random {
        return self.prng.random();
    }

    pub fn deinit(self: *Fuzzer) void {
        for (self.corpus.items) |item| {
            self.allocator.free(item);
        }
        self.corpus.deinit(self.allocator);
        self.result.deinit();
    }

    /// Add input to corpus
    pub fn addToCorpus(self: *Fuzzer, input: []const u8) !void {
        const copy = try self.allocator.dupe(u8, input);
        try self.corpus.append(self.allocator, copy);
    }

    /// Load corpus from directory
    pub fn loadCorpus(self: *Fuzzer, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const file = dir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const content = file.readToEndAlloc(self.allocator, self.config.max_input_size) catch continue;
                try self.corpus.append(self.allocator, content);
            }
        }
    }

    /// Generate random input
    pub fn generateInput(self: *Fuzzer) ![]u8 {
        const random = self.rng();
        const len = random.intRangeAtMost(usize, 1, self.config.max_input_size);
        const buf = try self.allocator.alloc(u8, len);
        random.bytes(buf);
        return buf;
    }

    /// Mutate existing input
    pub fn mutateInput(self: *Fuzzer, input: []const u8) ![]u8 {
        if (input.len == 0) return self.generateInput();

        const random = self.rng();
        const mutation = random.intRangeAtMost(u8, 0, 5);
        var result = try self.allocator.dupe(u8, input);

        switch (mutation) {
            0 => {
                // Bit flip
                if (result.len > 0) {
                    const pos = random.intRangeLessThan(usize, 0, result.len);
                    const bit: u3 = @truncate(random.intRangeLessThan(u8, 0, 8));
                    result[pos] ^= @as(u8, 1) << bit;
                }
            },
            1 => {
                // Byte replacement
                if (result.len > 0) {
                    const pos = random.intRangeLessThan(usize, 0, result.len);
                    result[pos] = random.int(u8);
                }
            },
            2 => {
                // Insert byte
                if (result.len < self.config.max_input_size) {
                    const pos = random.intRangeAtMost(usize, 0, result.len);
                    var new_buf = try self.allocator.alloc(u8, result.len + 1);
                    @memcpy(new_buf[0..pos], result[0..pos]);
                    new_buf[pos] = random.int(u8);
                    @memcpy(new_buf[pos + 1 ..], result[pos..]);
                    self.allocator.free(result);
                    result = new_buf;
                }
            },
            3 => {
                // Delete byte
                if (result.len > 1) {
                    const pos = random.intRangeLessThan(usize, 0, result.len);
                    var new_buf = try self.allocator.alloc(u8, result.len - 1);
                    @memcpy(new_buf[0..pos], result[0..pos]);
                    @memcpy(new_buf[pos..], result[pos + 1 ..]);
                    self.allocator.free(result);
                    result = new_buf;
                }
            },
            4 => {
                // Insert interesting value
                const interesting_values = [_][]const u8{
                    "\x00",
                    "\xff",
                    "\x7f",
                    "\x80",
                    "\"",
                    "\\",
                    "\n",
                    "\r\n",
                    "{}",
                    "[]",
                    "null",
                    "true",
                    "false",
                    "-1",
                    "0",
                    "9999999999999999999",
                };
                const val = interesting_values[random.intRangeLessThan(usize, 0, interesting_values.len)];
                const pos = random.intRangeAtMost(usize, 0, result.len);
                var new_buf = try self.allocator.alloc(u8, result.len + val.len);
                @memcpy(new_buf[0..pos], result[0..pos]);
                @memcpy(new_buf[pos .. pos + val.len], val);
                @memcpy(new_buf[pos + val.len ..], result[pos..]);
                self.allocator.free(result);
                result = new_buf;
            },
            5 => {
                // Duplicate region
                if (result.len > 0 and result.len * 2 <= self.config.max_input_size) {
                    const start = random.intRangeLessThan(usize, 0, result.len);
                    const end = random.intRangeAtMost(usize, start + 1, result.len);
                    const region = result[start..end];
                    var new_buf = try self.allocator.alloc(u8, result.len + region.len);
                    @memcpy(new_buf[0..end], result[0..end]);
                    @memcpy(new_buf[end .. end + region.len], region);
                    @memcpy(new_buf[end + region.len ..], result[end..]);
                    self.allocator.free(result);
                    result = new_buf;
                }
            },
            else => {},
        }

        return result;
    }

    /// Run fuzzer
    pub fn run(self: *Fuzzer, target: FuzzTarget) !void {
        // Load corpus if specified
        if (self.config.corpus_dir) |dir| {
            try self.loadCorpus(dir);
        }

        // Add seed inputs if corpus is empty
        if (self.corpus.items.len == 0) {
            try self.addSeedInputs();
        }

        var i: u64 = 0;
        while (i < self.config.iterations) : (i += 1) {
            self.result.iterations = i + 1;

            const random = self.rng();
            // Generate or mutate input
            const input = if (self.corpus.items.len > 0 and random.boolean())
                try self.mutateInput(self.corpus.items[random.intRangeLessThan(usize, 0, self.corpus.items.len)])
            else
                try self.generateInput();
            defer self.allocator.free(input);

            // Run target
            target(input);

            // Progress report
            if (i > 0 and i % 10000 == 0) {
                std.debug.print("Iterations: {d}, Errors: {d}\n", .{ i, self.result.unique_errors.count() });
            }
        }
    }

    fn addSeedInputs(self: *Fuzzer) !void {
        // JSON-RPC seeds
        try self.addToCorpus("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}");
        try self.addToCorpus("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
        try self.addToCorpus("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}");
        try self.addToCorpus("{\"jsonrpc\":\"2.0\",\"method\":\"notification\"}");

        // HTTP seeds
        try self.addToCorpus("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
        try self.addToCorpus("POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n");

        // WebSocket seeds
        try self.addToCorpus(&[_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' }); // Text frame
        try self.addToCorpus(&[_]u8{ 0x88, 0x02, 0x03, 0xE8 }); // Close frame
        try self.addToCorpus(&[_]u8{ 0x89, 0x00 }); // Ping frame
        try self.addToCorpus(&[_]u8{ 0x8A, 0x00 }); // Pong frame
    }
};

// ============================================================================
// Fuzz Targets
// ============================================================================

/// Fuzz target for JSON parsing
pub fn fuzzJsonParse(input: []const u8) void {
    var err_info = json.ParseError.init();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var doc = json.parse(arena.allocator(), input, .{}, &err_info) catch {
        return; // Parse errors are expected
    };
    doc.deinit();
}

/// Fuzz target for JSON-RPC message parsing
pub fn fuzzJsonRpcParse(input: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Try to parse as JSON first
    var err_info = json.ParseError.init();
    var doc = json.parse(arena.allocator(), input, .{}, &err_info) catch return;
    defer doc.deinit();

    // Validate JSON-RPC structure
    switch (doc.root) {
        .obj => |members| {
            var has_jsonrpc = false;
            for (members) |m| {
                if (std.mem.eql(u8, m.k, "jsonrpc")) {
                    has_jsonrpc = true;
                    if (m.v != .str) return;
                    if (!std.mem.eql(u8, m.v.str, "2.0")) return;
                }
            }
            if (!has_jsonrpc) return;
        },
        else => return,
    }
}

/// Fuzz target for WebSocket frame parsing
pub fn fuzzWebSocketFrame(input: []const u8) void {
    if (input.len < 2) return;

    // Parse WebSocket frame header
    const byte0 = input[0];
    const byte1 = input[1];

    const fin = (byte0 & 0x80) != 0;
    _ = fin;
    const opcode = byte0 & 0x0F;
    const masked = (byte1 & 0x80) != 0;
    var payload_len: u64 = byte1 & 0x7F;

    var offset: usize = 2;

    // Extended payload length
    if (payload_len == 126) {
        if (input.len < 4) return;
        payload_len = std.mem.readInt(u16, input[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (input.len < 10) return;
        payload_len = std.mem.readInt(u64, input[2..10], .big);
        offset = 10;
    }

    // Masking key
    var mask_key: [4]u8 = undefined;
    if (masked) {
        if (input.len < offset + 4) return;
        @memcpy(&mask_key, input[offset .. offset + 4]);
        offset += 4;
    }

    // Validate opcode
    switch (opcode) {
        0x0, 0x1, 0x2, 0x8, 0x9, 0xA => {},
        else => return, // Invalid opcode
    }

    // Validate payload
    if (input.len < offset + payload_len) return;
    const payload = input[offset .. offset + @as(usize, @intCast(payload_len))];

    // Unmask if needed
    if (masked) {
        var unmasked = std.heap.page_allocator.alloc(u8, payload.len) catch return;
        defer std.heap.page_allocator.free(unmasked);
        for (payload, 0..) |b, i| {
            unmasked[i] = b ^ mask_key[i % 4];
        }
    }
}

/// Fuzz target for HTTP header parsing
pub fn fuzzHttpHeaders(input: []const u8) void {
    // Look for header end
    const header_end = std.mem.indexOf(u8, input, "\r\n\r\n") orelse return;
    const headers = input[0..header_end];

    // Parse request line
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    const request_line = lines.next() orelse return;

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    _ = parts.next() orelse return; // path
    const version = parts.next() orelse return;

    // Validate method
    const valid_methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" };
    var valid = false;
    for (valid_methods) |m| {
        if (std.mem.eql(u8, method, m)) {
            valid = true;
            break;
        }
    }
    if (!valid) return;

    // Validate HTTP version
    if (!std.mem.startsWith(u8, version, "HTTP/")) return;

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        _ = line[0..colon]; // header name
        if (colon + 1 < line.len) {
            _ = std.mem.trim(u8, line[colon + 1 ..], " "); // header value
        }
    }
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var config = FuzzConfig{};
    var target_name: []const u8 = "json";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            config.corpus_dir = args.next();
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            if (args.next()) |n| {
                config.iterations = std.fmt.parseInt(u64, n, 10) catch 1000000;
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            if (args.next()) |s| {
                config.seed = std.fmt.parseInt(u64, s, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (args.next()) |t| {
                target_name = t;
            }
        }
    }

    const target: FuzzTarget = if (std.mem.eql(u8, target_name, "json"))
        fuzzJsonParse
    else if (std.mem.eql(u8, target_name, "jsonrpc"))
        fuzzJsonRpcParse
    else if (std.mem.eql(u8, target_name, "websocket"))
        fuzzWebSocketFrame
    else if (std.mem.eql(u8, target_name, "http"))
        fuzzHttpHeaders
    else {
        std.debug.print("Unknown target: {s}\n", .{target_name});
        printUsage();
        return;
    };

    std.debug.print("MCP Fuzz Tester\n", .{});
    std.debug.print("===============\n", .{});
    std.debug.print("Target: {s}\n", .{target_name});
    std.debug.print("Iterations: {d}\n", .{config.iterations});
    std.debug.print("Seed: {d}\n\n", .{config.seed});

    var fuzzer = Fuzzer.init(allocator, config);
    defer fuzzer.deinit();

    try fuzzer.run(target);

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Iterations: {d}\n", .{fuzzer.result.iterations});
    std.debug.print("  Unique errors: {d}\n", .{fuzzer.result.unique_errors.count()});
}

fn printUsage() void {
    const usage =
        \\MCP Fuzz Tester
        \\
        \\Usage: fuzz [options]
        \\
        \\Options:
        \\  --target <name>    Target: json, jsonrpc, websocket, http (default: json)
        \\  --corpus <dir>     Corpus directory for seed inputs
        \\  --iterations <n>   Number of iterations (default: 1000000)
        \\  --seed <n>         Random seed (0 = random)
        \\  --help, -h         Show this help
        \\
        \\Examples:
        \\  fuzz --target jsonrpc --iterations 100000
        \\  fuzz --target websocket --corpus corpus/ws/
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// ============================================================================
// Tests
// ============================================================================

test "fuzzer mutation" {
    const allocator = std.testing.allocator;
    var fuzzer = Fuzzer.init(allocator, .{ .iterations = 10 });
    defer fuzzer.deinit();

    const input = "test input";
    const mutated = try fuzzer.mutateInput(input);
    defer allocator.free(mutated);

    // Mutation should produce something
    try std.testing.expect(mutated.len > 0);
}

test "json fuzz target" {
    fuzzJsonParse("{}");
    fuzzJsonParse("{\"key\":\"value\"}");
    fuzzJsonParse("invalid json");
    fuzzJsonParse("");
}

test "websocket fuzz target" {
    fuzzWebSocketFrame(&[_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' });
    fuzzWebSocketFrame(&[_]u8{ 0x88, 0x00 });
    fuzzWebSocketFrame("");
}

test "http fuzz target" {
    fuzzHttpHeaders("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    fuzzHttpHeaders("POST /test HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
    fuzzHttpHeaders("invalid");
}
