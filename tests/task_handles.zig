//! Task handles must not dangle (SONNY-6644).
//!
//! `Server.createTask` and `Server.getTask` used to return a pointer into
//! the server's task hashmap after releasing its lock: any later insert can
//! move the entry and a concurrent update races the caller's reads. They now
//! return an owned copy (`Task.deinit` frees it). Driven through the
//! server's public API and a real tasks/get round trip.

const std = @import("std");
const mcp = @import("mcp");

test "createTask and getTask return copies that survive later inserts and updates" {
    const a = std.testing.allocator;
    var demo = mcp.DemoHandler.init(a);
    var server = try mcp.Server.init(a, .{ .name = "t", .version = "1", .tasks_enabled = true }, demo.handler());
    defer server.deinit();

    var first = try server.createTask("tools/call", null);
    defer first.deinit(a);
    const id_copy = try a.dupe(u8, first.id);
    defer a.free(id_copy);

    // Enough inserts to grow (and move) the task table several times.
    for (0..300) |_| {
        var t = try server.createTask("tools/call", 1000);
        t.deinit(a);
    }
    server.updateTaskStatus(first.id, .completed, "{\"value\":42}");

    // The copy is a snapshot: still valid, unchanged by the update.
    try std.testing.expectEqualStrings(id_copy, first.id);
    try std.testing.expectEqualStrings("tools/call", first.method);
    try std.testing.expectEqual(mcp.TaskState.working, first.status);

    // A fresh copy sees the update.
    var now = (try server.getTask(first.id)).?;
    defer now.deinit(a);
    try std.testing.expectEqual(mcp.TaskState.completed, now.status);
    try std.testing.expectEqualStrings("{\"value\":42}", now.result.?);

    try std.testing.expect((try server.getTask("task-does-not-exist")) == null);

    // The task is also visible to the client through the dispatcher.
    _ = try server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    const msg = try std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{{"taskId":"{s}"}}}}
    , .{id_copy});
    defer a.free(msg);
    const resp = (try server.processMessage(msg)).?;
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"status\":\"completed\"") != null);
}
