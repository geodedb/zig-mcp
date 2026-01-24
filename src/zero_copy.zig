// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Zero-Copy JSON Value Accessors
//!
//! Provides efficient access to JSON values without copying string data.
//! Strings returned are slices into the original parse buffer.
//!
//! IMPORTANT: Values are only valid while the source Document is alive.
//! Do not use returned slices after calling doc.deinit().

const std = @import("std");
const json = @import("json");

/// Zero-copy JSON value wrapper
pub const ZeroCopyValue = struct {
    value: json.Value,

    /// Get a string value without copying
    /// Returns null if not a string
    pub fn asString(self: ZeroCopyValue) ?[]const u8 {
        return switch (self.value) {
            .str => |s| s,
            else => null,
        };
    }

    /// Get a string value or return default
    pub fn asStringOr(self: ZeroCopyValue, default: []const u8) []const u8 {
        return self.asString() orelse default;
    }

    /// Get a boolean value
    pub fn asBool(self: ZeroCopyValue) ?bool {
        return switch (self.value) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Get a boolean value or return default
    pub fn asBoolOr(self: ZeroCopyValue, default: bool) bool {
        return self.asBool() orelse default;
    }

    /// Get an integer value (if number is an integer)
    pub fn asInt(self: ZeroCopyValue, comptime T: type) ?T {
        return switch (self.value) {
            .num => |n| {
                if (!n.isInteger()) return null;
                return std.fmt.parseInt(T, n.lexeme, 10) catch null;
            },
            else => null,
        };
    }

    /// Get an integer value or return default
    pub fn asIntOr(self: ZeroCopyValue, comptime T: type, default: T) T {
        return self.asInt(T) orelse default;
    }

    /// Get a float value
    pub fn asFloat(self: ZeroCopyValue, comptime T: type) ?T {
        return switch (self.value) {
            .num => |n| std.fmt.parseFloat(T, n.lexeme) catch null,
            else => null,
        };
    }

    /// Check if value is null
    pub fn isNull(self: ZeroCopyValue) bool {
        return self.value == .null;
    }

    /// Get array length
    pub fn arrayLen(self: ZeroCopyValue) ?usize {
        return switch (self.value) {
            .arr => |a| a.len,
            else => null,
        };
    }

    /// Get array element at index
    pub fn arrayAt(self: ZeroCopyValue, index: usize) ?ZeroCopyValue {
        return switch (self.value) {
            .arr => |a| if (index < a.len) ZeroCopyValue{ .value = a[index] } else null,
            else => null,
        };
    }

    /// Iterate over array elements
    pub fn arrayIterator(self: ZeroCopyValue) ?ArrayIterator {
        return switch (self.value) {
            .arr => |a| ArrayIterator{ .items = a, .index = 0 },
            else => null,
        };
    }

    /// Get object member by key (zero-copy key lookup)
    pub fn get(self: ZeroCopyValue, key: []const u8) ?ZeroCopyValue {
        return switch (self.value) {
            .obj => |members| {
                for (members) |m| {
                    if (std.mem.eql(u8, m.k, key)) {
                        return ZeroCopyValue{ .value = m.v };
                    }
                }
                return null;
            },
            else => null,
        };
    }

    /// Get nested value by path (e.g., "params.name")
    pub fn getPath(self: ZeroCopyValue, path: []const u8) ?ZeroCopyValue {
        var current = self;
        var iter = std.mem.splitScalar(u8, path, '.');
        while (iter.next()) |key| {
            current = current.get(key) orelse return null;
        }
        return current;
    }

    /// Iterate over object members
    pub fn objectIterator(self: ZeroCopyValue) ?ObjectIterator {
        return switch (self.value) {
            .obj => |members| ObjectIterator{ .members = members, .index = 0 },
            else => null,
        };
    }

    /// Get number of object members
    pub fn objectLen(self: ZeroCopyValue) ?usize {
        return switch (self.value) {
            .obj => |members| members.len,
            else => null,
        };
    }
};

/// Iterator for array elements
pub const ArrayIterator = struct {
    items: []json.Value,
    index: usize,

    pub fn next(self: *ArrayIterator) ?ZeroCopyValue {
        if (self.index >= self.items.len) return null;
        const value = ZeroCopyValue{ .value = self.items[self.index] };
        self.index += 1;
        return value;
    }

    pub fn reset(self: *ArrayIterator) void {
        self.index = 0;
    }
};

/// Iterator for object members
pub const ObjectIterator = struct {
    members: []json.Member,
    index: usize,

    pub const Entry = struct {
        key: []const u8,
        value: ZeroCopyValue,
    };

    pub fn next(self: *ObjectIterator) ?Entry {
        if (self.index >= self.members.len) return null;
        const member = self.members[self.index];
        self.index += 1;
        return Entry{
            .key = member.k,
            .value = ZeroCopyValue{ .value = member.v },
        };
    }

    pub fn reset(self: *ObjectIterator) void {
        self.index = 0;
    }
};

/// Wrap a json.Value for zero-copy access
pub fn wrap(value: json.Value) ZeroCopyValue {
    return ZeroCopyValue{ .value = value };
}

/// Parse JSON and return zero-copy root value
/// The returned ZeroCopyValue is only valid while doc is alive
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !struct { doc: json.Document, root: ZeroCopyValue } {
    var err_info = json.ParseError.init();
    const doc = try json.parse(allocator, input, .{}, &err_info);
    return .{
        .doc = doc,
        .root = ZeroCopyValue{ .value = doc.root },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "zero-copy string access" {
    const input = "{\"name\":\"test\",\"count\":42}";
    var result = try parse(std.testing.allocator, input);
    defer result.doc.deinit();

    const name = result.root.get("name").?.asString().?;
    try std.testing.expectEqualStrings("test", name);
}

test "zero-copy integer access" {
    const input = "{\"count\":42}";
    var result = try parse(std.testing.allocator, input);
    defer result.doc.deinit();

    const count = result.root.get("count").?.asInt(i32).?;
    try std.testing.expectEqual(@as(i32, 42), count);
}

test "zero-copy path access" {
    const input = "{\"params\":{\"name\":\"value\"}}";
    var result = try parse(std.testing.allocator, input);
    defer result.doc.deinit();

    const value = result.root.getPath("params.name").?.asString().?;
    try std.testing.expectEqualStrings("value", value);
}

test "zero-copy array iteration" {
    const input = "[1,2,3]";
    var result = try parse(std.testing.allocator, input);
    defer result.doc.deinit();

    var iter = result.root.arrayIterator().?;
    var sum: i32 = 0;
    while (iter.next()) |elem| {
        sum += elem.asInt(i32).?;
    }
    try std.testing.expectEqual(@as(i32, 6), sum);
}

test "zero-copy object iteration" {
    const input = "{\"a\":1,\"b\":2}";
    var result = try parse(std.testing.allocator, input);
    defer result.doc.deinit();

    var iter = result.root.objectIterator().?;
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
