const std = @import("std");
const context = @import("../core/context.zig");
const loop = @import("../core/loop.zig");
const tcp = @import("../core/tcp.zig");
const timer = @import("../core/timer.zig");

const pool_mod = @import("../core/pool.zig");

// test generic bitset pool logic.
test "core: bitset pool acquires and releases slots" {
    var pool = context.bitset_pool(usize, 10).init();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test generic freelist pool logic.
test "core: freelist pool acquires and releases slots" {
    var pool = try pool_mod.freelist_pool(usize, 10).init();
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());

    const item = pool.acquire();
    try std.testing.expect(item != null);
    try std.testing.expectEqual(@as(usize, 1), pool.count_active());

    try std.testing.expect(pool.release(item.?));
    try std.testing.expect(!pool.release(item.?));
    var foreign: usize = 0;
    try std.testing.expect(!pool.release(&foreign));
    try std.testing.expectEqual(@as(usize, 0), pool.count_active());
}

// test loop initialization and deinitialization.
test "core: loop init and deinit" {
    var l = try loop.init();
    defer loop.deinit(&l);

    // ensure the underlying xev loop is available by taking its pointer.
    const xev_loop = l.get_xev_loop();
    _ = xev_loop;
}

fn dummy_accept(socket: @import("xev").TCP, user_data: ?*anyopaque) void {
    _ = socket;
    _ = user_data;
}

// test tcp server initialization.
test "core: tcp server init" {
    // bind to ephemeral port 0 to prevent port collisions during tests.
    const server = try tcp.init_server("127.0.0.1", 0, dummy_accept, null);
    defer _ = std.posix.system.close(server.listener.fd);
}

// dummy callback for timer test.
fn dummy_tick() void {}

// test timer initialization and deinitialization.
test "core: timer init and deinit" {
    var t = try timer.init_timer(100, dummy_tick);
    defer timer.deinit_timer(&t);
}
