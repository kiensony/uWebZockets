const std = @import("std");
const xev = @import("xev");
const tcp = @import("tcp.zig");
const Loop = @import("loop.zig").Loop;

// a lightweight, zero-allocation timer context for the event loop.
pub const TimerContext = struct {
    timer: xev.Timer,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    interval_ms: u64,
    tick_cb: *const fn () void,
    active: bool = false,
    stopping: bool = false,
};

// initializes a recurring timer.
pub fn init_timer(interval_ms: u64, tick_callback: *const fn () void) !TimerContext {
    const t = try xev.Timer.init();
    return TimerContext{
        .timer = t,
        .interval_ms = interval_ms,
        .tick_cb = tick_callback,
    };
}

// dismantles the timer.
pub fn deinit_timer(ctx: *TimerContext) void {
    ctx.timer.deinit();
}

// arms the timer on the provided event loop.
pub fn start_timer(ctx: *TimerContext, loop: *Loop) void {
    if (ctx.active or ctx.stopping) return;
    ctx.active = true;
    ctx.timer.run(
        loop.get_xev_loop(),
        &ctx.completion,
        ctx.interval_ms,
        TimerContext,
        ctx,
        on_timer_tick,
    );
}

pub fn stop_timer(ctx: *TimerContext, loop: *Loop) void {
    if (!ctx.active or ctx.stopping) return;
    ctx.stopping = true;
    ctx.timer.cancel(
        loop.get_xev_loop(),
        &ctx.completion,
        &ctx.cancel_completion,
        TimerContext,
        ctx,
        on_timer_cancel,
    );
}

// callback triggered by libxev when the interval elapses.
fn on_timer_tick(
    user_data: ?*TimerContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    const ctx = user_data.?;
    _ = result catch |err| {
        ctx.active = false;
        if (err == error.Canceled) return .disarm;
        std.debug.print("timer error: {}\n", .{err});
        return .disarm;
    };

    ctx.active = false;
    if (ctx.stopping) return .disarm;
    ctx.tick_cb();

    // io_uring rearms the original absolute timeout, which is already expired.
    ctx.timer.run(loop, completion, ctx.interval_ms, TimerContext, ctx, on_timer_tick);
    ctx.active = true;
    return .disarm;
}

fn on_timer_cancel(
    user_data: ?*TimerContext,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const ctx = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) std.debug.print("timer cancel error: {}\n", .{err});
        return .disarm;
    };
    ctx.active = false;
    return .disarm;
}

// connection sweeper, generic over pool type to prevent import loops
pub fn ConnectionSweeper(comptime PoolType: type, comptime idle_timeout_ms: u64) type {
    if (idle_timeout_ms > std.math.maxInt(i64)) {
        @compileError("idle timeout exceeds the monotonic clock representation");
    }

    return struct {
        const Self = @This();
        const timeout_ms: i64 = @intCast(idle_timeout_ms);

        timer: xev.Timer,
        completion: xev.Completion = .{},
        cancel_completion: xev.Completion = .{},
        pool: *PoolType,
        io: std.Io,
        active: bool = false,
        stopping: bool = false,

        pub fn init(io: std.Io, pool: *PoolType) !Self {
            return Self{
                .timer = try xev.Timer.init(),
                .pool = pool,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.timer.deinit();
        }

        pub fn start(self: *Self, loop: *Loop) void {
            if (self.active or self.stopping) return;
            self.active = true;
            // run callback every 5000ms (5 seconds)
            self.timer.run(
                loop.get_xev_loop(),
                &self.completion,
                5000,
                Self,
                self,
                on_tick,
            );
        }

        pub fn stop(self: *Self, loop: *Loop) void {
            if (!self.active or self.stopping) return;
            self.stopping = true;
            self.timer.cancel(
                loop.get_xev_loop(),
                &self.completion,
                &self.cancel_completion,
                Self,
                self,
                on_cancel,
            );
        }

        // callback triggered by libxev every 5 seconds
        fn on_tick(
            user_data: ?*Self,
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                self.active = false;
                if (err == error.Canceled) return .disarm;
                std.debug.print("sweeper timer error: {}\n", .{err});
                return .disarm;
            };

            self.active = false;
            if (self.stopping) return .disarm;
            const now = std.Io.Clock.now(.awake, self.io);
            const current_time: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000));

            // sweep through contiguous storage array (data-oriented design)
            // contiguous memory ensures cpu cache processes all items in microseconds
            for (self.pool.storage, 0..) |*conn, index| {
                if (!self.pool.is_active(index) or conn.closing) continue;
                if (conn.last_active_ms <= 0) continue;

                const idle_time = current_time - conn.last_active_ms;
                if (idle_time <= timeout_ms) continue;

                conn.last_active_ms = 0;
                tcp.close_connection(conn);
            }

            // Schedule a new relative timeout instead of reusing an expired one.
            self.timer.run(loop, completion, 5000, Self, self, on_tick);
            self.active = true;
            return .disarm;
        }

        fn on_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) std.debug.print("sweeper cancel error: {}\n", .{err});
                return .disarm;
            };
            self.active = false;
            return .disarm;
        }
    };
}

test "timer: stop drains the active completion" {
    const Tick = struct {
        fn callback() void {}
    };

    var loop = try @import("loop.zig").init();
    defer @import("loop.zig").deinit(&loop);
    var timer = try init_timer(60_000, Tick.callback);
    defer deinit_timer(&timer);

    start_timer(&timer, &loop);
    stop_timer(&timer, &loop);
    try @import("loop.zig").run(&loop);
    try std.testing.expect(!timer.active);
}
