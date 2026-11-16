//! Coverage-guided fuzz target for the JSON-RPC dispatcher.
//!
//! `zig build test` runs it over the corpus. The property lives in
//! tests/dispatch_fuzz_target.zig, which `zig build fuzz -- --target
//! dispatch` (the CI `fuzz` job) also drives with the mutation fuzzer.

const std = @import("std");
const target = @import("dispatch_fuzz_target.zig");

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    try target.checkOne(buf[0..n]);
}

/// Encodes `s` the way `std.testing.Smith.slice` reads it from a corpus
/// entry: a little-endian u32 length followed by the bytes.
fn seed(comptime s: []const u8) []const u8 {
    const encoded = comptime blk: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, s.len, .little);
        break :blk len ++ s[0..s.len].*;
    };
    return &encoded;
}

test "fuzz: dispatcher responses are always valid single-line JSON" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        seed(
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a\"b\u0001","arguments":{"x":"\n"}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":"s\"\\","method":"tools/call","params":{"name":"echo","arguments":{"k":[1,2,{"z":null}]}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"]}\n{"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"nope"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"file:///\u007f\""}}
        ),
        seed(
            \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"x"},{"jsonrpc":"2.0","id":null,"method":"ping"}]
        ),
        seed(
            \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"abc"}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":4,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"p"}}}
        ),
        seed(
            \\{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"\t"}}
        ),
        seed("not json"),
    } });
}
