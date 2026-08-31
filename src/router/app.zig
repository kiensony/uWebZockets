const std = @import("std");
const core_loop = @import("../core/loop.zig");
const core_tcp = @import("../core/tcp.zig");
const core_context = @import("../core/context.zig");
const core_pool = @import("../core/pool.zig");
const core_timer = @import("../core/timer.zig");
const radix = @import("radix.zig");
const xev = @import("xev");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const DeflateContext = @import("../ws/deflate.zig").Context;
const TlsContext = @import("../crypto/tls.zig").TlsContext;
const quic = @import("../quic/engine.zig");

pub const default_max_ws_message_size = 16 * 1024;
pub const default_write_queue_size = core_tcp.default_write_queue_capacity;
pub const default_idle_timeout_ms: u64 = 120_000;
pub const http3_available = quic.available;

pub fn app(comptime max_connections: usize) type {
    return configured_app(max_connections, default_max_ws_message_size, default_write_queue_size);
}

pub fn configured_app(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
) type {
    return configured_app_with_timeout(
        max_connections,
        max_ws_message_size,
        write_queue_size,
        default_idle_timeout_ms,
    );
}

pub fn configured_app_with_timeout(
    comptime max_connections: usize,
    comptime max_ws_message_size: usize,
    comptime write_queue_size: usize,
    comptime idle_timeout_ms: u64,
) type {
    if (max_connections == 0) @compileError("connection capacity must be greater than zero");
    if (max_ws_message_size == 0) @compileError("WebSocket message capacity must be greater than zero");
    if (write_queue_size == 0) @compileError("write queue capacity must be greater than zero");
    if (max_connections > std.math.maxInt(usize) / max_ws_message_size) {
        @compileError("WebSocket message storage size overflows usize");
    }
    if (max_connections > std.math.maxInt(usize) / write_queue_size) {
        @compileError("write queue storage size overflows usize");
    }

    return struct {
        const Self = @This();
        const Pool = core_pool.freelist_pool(core_tcp.TcpConnection, max_connections);
        const QuicEngine = quic.quic_engine(max_connections, write_queue_size);

        io: std.Io,
        loop: core_loop.Loop,
        pool: Pool,
        ws_message_storage: []u8,
        ws_compression_storage: []u8 = &.{},
        ws_compression_capacity: usize = 0,
        ws_deflate: ?DeflateContext = null,
        write_queue_storage: []u8,
        router: radix.Router,
        server: ?core_tcp.TcpServer = null,
        sweeper: ?core_timer.ConnectionSweeper(Pool, idle_timeout_ms) = null,
        tls_ctx: ?TlsContext = null,
        quic_tls_ctx: ?TlsContext = null,
        quic_engine: ?QuicEngine = null,
        udp_socket: ?xev.UDP = null,
        quic_timer: ?xev.Timer = null,
        udp_read_completion: xev.Completion = .{},
        udp_read_cancel_completion: xev.Completion = .{},
        udp_close_completion: xev.Completion = .{},
        quic_timer_completion: xev.Completion = .{},
        quic_timer_cancel_completion: xev.Completion = .{},
        udp_read_state: xev.UDP.State = undefined,
        udp_read_buffer: [@import("../quic/lsquic_api.zig").max_udp_payload_size]u8 = undefined,
        http3_enabled: bool = false,
        udp_read_active: bool = false,
        udp_read_cancel_active: bool = false,
        udp_close_complete: bool = false,
        quic_timer_active: bool = false,
        quic_timer_cancel_active: bool = false,
        routes_locked: bool = false,
        shutting_down: bool = false,
        deinitialized: bool = false,

        // embeds the pub/sub engine directly into the app
        pubsub: PubSubEngine,

        // initializes a new application.
        pub fn init(io: std.Io) !Self {
            var loop = try core_loop.init();
            errdefer core_loop.deinit(&loop);

            var pool = try Pool.init();
            errdefer pool.deinit();

            const storage_len = max_connections * max_ws_message_size;
            const ws_message_storage = try std.heap.page_allocator.alloc(u8, storage_len);
            errdefer std.heap.page_allocator.free(ws_message_storage);

            const write_storage_len = max_connections * write_queue_size;
            const write_queue_storage = try std.heap.page_allocator.alloc(u8, write_storage_len);
            errdefer std.heap.page_allocator.free(write_queue_storage);

            return Self{
                .io = io,
                .loop = loop,
                .pool = pool,
                .ws_message_storage = ws_message_storage,
                .write_queue_storage = write_queue_storage,
                .router = radix.Router.init(),
                .pubsub = .{},
            };
        }

        // initializes a new application with https support.
        pub fn init_https(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            return instance;
        }

        // initializes a new application with http/3 (quic) support.
        pub fn init_http3(io: std.Io, cert_path: [:0]const u8, key_path: [:0]const u8) !Self {
            var instance = try Self.init(io);
            errdefer instance.deinit();
            instance.tls_ctx = try TlsContext.init(cert_path, key_path);
            instance.quic_tls_ctx = try TlsContext.init_http3(cert_path, key_path);
            instance.http3_enabled = true;
            return instance;
        }

        // deinitializes the application and releases os resources.
        pub fn deinit(self: *Self) void {
            if (self.deinitialized) return;
            self.shutdown() catch |err| {
                // Returning would leave kernel completions pointing at storage
                // the caller is about to release.
                std.debug.panic("application shutdown failed: {}", .{err});
            };

            if (self.sweeper) |*sw| {
                sw.deinit();
            }
            self.sweeper = null;
            self.server = null;

            if (self.quic_engine) |*engine| engine.deinit();
            self.quic_engine = null;
            if (self.quic_timer) |*timer| timer.deinit();
            self.quic_timer = null;
            self.udp_socket = null;
            if (self.quic_tls_ctx) |*tls| tls.deinit();
            self.quic_tls_ctx = null;
            if (self.tls_ctx) |*tls| tls.deinit();
            self.tls_ctx = null;
            if (self.ws_deflate) |*context| context.deinit();
            self.ws_deflate = null;
            core_loop.deinit(&self.loop);
            self.pool.deinit();
            std.heap.page_allocator.free(self.ws_message_storage);
            if (self.ws_compression_storage.len != 0) {
                std.heap.page_allocator.free(self.ws_compression_storage);
                self.ws_compression_storage = &.{};
            }
            std.heap.page_allocator.free(self.write_queue_storage);
            self.deinitialized = true;
        }

        // Stops recurring work and drains every completion that may reference
        // the application's contiguous slabs.
        pub fn shutdown(self: *Self) !void {
            if (self.deinitialized) return error.ApplicationDeinitialized;

            if (!self.shutting_down) {
                self.shutting_down = true;
                if (self.sweeper) |*sw| sw.stop(&self.loop);
                if (self.server) |*server| core_tcp.close_server(server, &self.loop);
                if (self.quic_engine) |*engine| engine.cooldown();
                self.stop_quic_timer();
                self.close_udp();

                for (self.pool.storage, 0..) |*conn, index| {
                    if (!self.pool.is_active(index)) continue;
                    core_tcp.close_connection(conn);
                }
            }

            try core_loop.run(&self.loop);
            if (self.pool.count_active() != 0) return error.ShutdownIncomplete;
            if (self.server) |server| {
                if (!server.close_complete) return error.ShutdownIncomplete;
            }
            if (self.udp_socket != null and !self.udp_close_complete) {
                return error.ShutdownIncomplete;
            }
            if (self.udp_read_active or self.udp_read_cancel_active) {
                return error.ShutdownIncomplete;
            }
            if (self.quic_timer_active or self.quic_timer_cancel_active) {
                return error.ShutdownIncomplete;
            }
        }

        // registers an http get route with fluent chaining.
        pub fn get(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.get(path, handler);
            return self;
        }

        pub fn head(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.head(path, handler);
            return self;
        }

        pub fn post(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.post(path, handler);
            return self;
        }

        pub fn put(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.put(path, handler);
            return self;
        }

        pub fn delete(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.delete(path, handler);
            return self;
        }

        pub fn patch(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.patch(path, handler);
            return self;
        }

        pub fn options(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.options(path, handler);
            return self;
        }

        pub fn any(self: *Self, path: []const u8, handler: radix.Handler) !*Self {
            try self.ensure_routes_mutable();
            try self.router.any(path, handler);
            return self;
        }

        // registers a websocket route with event callbacks.
        pub fn ws(self: *Self, path: []const u8, behavior: radix.WsBehavior) !*Self {
            try self.ensure_routes_mutable();
            if (!radix.valid_ws_limits(behavior, max_ws_message_size)) {
                return error.InvalidWebSocketLimits;
            }
            if (behavior.compression == .permessage_deflate) try self.ensure_ws_compression();
            try self.router.ws(path, behavior);
            return self;
        }

        fn ensure_routes_mutable(self: *const Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.routes_locked) return error.RoutesLocked;
        }

        fn ensure_ws_compression(self: *Self) !void {
            if (self.ws_deflate != null) return;

            var context = try DeflateContext.init(6);
            errdefer context.deinit();
            const per_connection = try context.scratch_bound(max_ws_message_size);
            const per_connection_storage = std.math.mul(
                usize,
                per_connection,
                2,
            ) catch return error.SizeOverflow;
            const storage_len = std.math.mul(
                usize,
                max_connections,
                per_connection_storage,
            ) catch return error.SizeOverflow;
            const storage = try std.heap.page_allocator.alloc(u8, storage_len);

            self.ws_compression_capacity = per_connection;
            self.ws_compression_storage = storage;
            self.ws_deflate = context;
        }

        // callback triggered when the tcp server accepts a new socket.
        fn on_new_connection(socket: xev.TCP, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data));
            if (self.shutting_down) {
                close_rejected_socket(socket);
                return;
            }
            const conn = self.pool.acquire() orelse {
                // No I/O was registered for this descriptor, so direct close is safe.
                close_rejected_socket(socket);
                return;
            };

            conn.req = .{};
            conn.parser = .{};
            conn.protocol_state = .http;
            conn.ssl = null;
            conn.network_bio = null;
            conn.is_tls_handshake_done = false;
            conn.tls_shutdown_started = false;
            conn.read_active = false;
            conn.read_cancel_active = false;
            conn.write_cancel_active = false;
            conn.request_len = 0;
            conn.write_head = 0;
            conn.write_len = 0;
            conn.write_in_flight_len = 0;
            conn.is_writing = false;
            conn.close_complete = false;
            conn.was_backpressured = false;
            conn.close_when_drained = false;
            conn.closing = false;
            conn.expect_continue_sent = false;
            conn.suppress_response_body = false;

            const now = std.Io.Clock.now(.awake, self.io);
            conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

            conn.socket = socket;
            conn.loop = &self.loop.xev_loop;
            // acquire only returns pointers into this pool's contiguous slab.
            const connection_index = self.pool.index_of(conn) orelse unreachable;
            const message_start = connection_index * max_ws_message_size;
            conn.ws_message_buffer = self.ws_message_storage[message_start .. message_start + max_ws_message_size];
            if (self.ws_deflate) |*context| {
                const buffers = compression_buffers(
                    self.ws_compression_storage,
                    self.ws_compression_capacity,
                    connection_index,
                ) orelse unreachable;
                conn.ws_compression_buffer = buffers.incoming;
                conn.ws_compression_output_buffer = buffers.outgoing;
                conn.ws_deflate = context;
            } else {
                conn.ws_compression_buffer = &.{};
                conn.ws_compression_output_buffer = &.{};
                conn.ws_deflate = null;
            }
            const write_start = connection_index * write_queue_size;
            conn.write_queue = self.write_queue_storage[write_start .. write_start + write_queue_size];
            conn.router = &self.router;
            conn.pubsub = &self.pubsub;
            conn.pool_ptr = &self.pool;
            conn.io = self.io;
            conn.on_close_cb = (struct {
                fn cb(pool_ptr: *anyopaque, c: *core_tcp.TcpConnection) void {
                    const pool: *Pool = @ptrCast(@alignCast(pool_ptr));
                    _ = pool.release(c);
                }
            }).cb;

            if (self.tls_ctx) |tls| {
                conn.init_tls(tls.ctx) catch {
                    core_tcp.close_connection(conn);
                    return;
                };
            }
            core_tcp.read_start(conn, &self.loop);
        }

        pub fn listen(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (self.server != null) return error.AlreadyListening;

            const server = try core_tcp.init_server(address, port, on_new_connection, self);
            errdefer close_socket_now(server.listener);

            var sweeper: ?core_timer.ConnectionSweeper(Pool, idle_timeout_ms) = null;
            if (idle_timeout_ms != 0) {
                sweeper = try core_timer.ConnectionSweeper(Pool, idle_timeout_ms).init(self.io, &self.pool);
            }

            self.routes_locked = true;
            self.server = server;
            self.sweeper = sweeper;
            core_tcp.accept_start(&self.server.?, &self.loop);
            if (self.sweeper) |*sw| {
                sw.start(&self.loop);
            }

            std.debug.print("server listening on {s}:{d}\n", .{ address, port });
        }

        // binds the server to a udp socket for quic/http3.
        pub fn listen_udp(self: *Self, address: []const u8, port: u16) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            if (!self.http3_enabled or self.quic_tls_ctx == null) return error.Http3NotInitialized;
            if (self.udp_socket != null or self.quic_engine != null) return error.AlreadyListening;

            const parsed_address = try std.Io.net.IpAddress.parse(address, port);
            var socket = try xev.UDP.init(parsed_address);
            errdefer close_socket_now(socket);
            try socket.bind(parsed_address);

            self.quic_engine = try QuicEngine.init();
            errdefer {
                self.quic_engine.?.deinit();
                self.quic_engine = null;
            }
            try self.quic_engine.?.start(
                self.quic_tls_ctx.?.ctx,
                &self.router,
                socket.fd,
                parsed_address,
            );

            self.quic_timer = try xev.Timer.init();
            errdefer {
                self.quic_timer.?.deinit();
                self.quic_timer = null;
            }
            self.routes_locked = true;
            self.udp_socket = socket;
            self.udp_close_complete = false;
            self.udp_read_active = true;
            self.udp_socket.?.read(
                self.loop.get_xev_loop(),
                &self.udp_read_completion,
                &self.udp_read_state,
                .{ .slice = &self.udp_read_buffer },
                Self,
                self,
                on_udp_read,
            );
            self.start_quic_timer();

            std.debug.print("http/3 server listening on {s}:{d}\n", .{ address, port });
        }

        fn on_udp_read(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: *xev.UDP.State,
            peer: std.Io.net.IpAddress,
            _: xev.UDP,
            _: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.udp_read_active = false;

            const bytes_read = result catch |err| {
                if (self.shutting_down or err == error.Canceled) return .disarm;
                std.debug.print("udp read error: {}\n", .{err});
                self.udp_read_active = true;
                return .rearm;
            };
            if (self.shutting_down) return .disarm;
            if (bytes_read != 0) {
                if (self.quic_engine) |*engine| {
                    engine.process_datagram(self.udp_read_buffer[0..bytes_read], peer);
                }
            }
            self.udp_read_active = true;
            return .rearm;
        }

        fn close_udp(self: *Self) void {
            const socket = self.udp_socket orelse return;
            if (self.udp_close_complete) return;

            if (self.udp_read_active and !self.udp_read_cancel_active) {
                self.udp_read_cancel_active = true;
                self.loop.get_xev_loop().cancel(
                    &self.udp_read_completion,
                    &self.udp_read_cancel_completion,
                    Self,
                    self,
                    on_udp_read_cancel,
                );
            }
            socket.close(
                self.loop.get_xev_loop(),
                &self.udp_close_completion,
                Self,
                self,
                on_udp_close,
            );
        }

        fn on_udp_read_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) std.debug.print("udp read cancel error: {}\n", .{err});
            };
            self.udp_read_cancel_active = false;
            return .disarm;
        }

        fn on_udp_close(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.UDP,
            result: xev.CloseError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| std.debug.print("udp close error: {}\n", .{err});
            self.udp_close_complete = true;
            return .disarm;
        }

        fn start_quic_timer(self: *Self) void {
            if (self.quic_timer_active or self.shutting_down) return;
            const timer = self.quic_timer orelse return;
            const timeout = if (self.quic_engine) |*engine| engine.next_timeout_ms() else 50;
            self.quic_timer_active = true;
            timer.run(
                self.loop.get_xev_loop(),
                &self.quic_timer_completion,
                timeout,
                Self,
                self,
                on_quic_timer,
            );
        }

        fn stop_quic_timer(self: *Self) void {
            const timer = self.quic_timer orelse return;
            if (!self.quic_timer_active or self.quic_timer_cancel_active) return;
            self.quic_timer_cancel_active = true;
            timer.cancel(
                self.loop.get_xev_loop(),
                &self.quic_timer_completion,
                &self.quic_timer_cancel_completion,
                Self,
                self,
                on_quic_timer_cancel,
            );
        }

        fn on_quic_timer(
            user_data: ?*Self,
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: anyerror!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            self.quic_timer_active = false;
            _ = result catch |err| {
                if (self.shutting_down or err == error.Canceled) return .disarm;
                std.debug.print("quic timer error: {}\n", .{err});
                return .disarm;
            };
            if (self.shutting_down) return .disarm;

            if (self.quic_engine) |*engine| engine.process();
            const timer = self.quic_timer orelse return .disarm;
            const timeout = if (self.quic_engine) |*engine| engine.next_timeout_ms() else 50;
            self.quic_timer_active = true;
            timer.run(loop, completion, timeout, Self, self, on_quic_timer);
            return .disarm;
        }

        fn on_quic_timer_cancel(
            user_data: ?*Self,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.CancelError!void,
        ) xev.CallbackAction {
            const self = user_data.?;
            _ = result catch |err| {
                if (err != error.NotFound) std.debug.print("quic timer cancel error: {}\n", .{err});
            };
            self.quic_timer_cancel_active = false;
            return .disarm;
        }

        // blocks the current thread and enters the event loop.
        pub fn run(self: *Self) !void {
            if (self.shutting_down or self.deinitialized) return error.ApplicationUnavailable;
            try core_loop.run(&self.loop);
        }

        // global publish from the server side.
        pub fn publish(self: *Self, topic: []const u8, message: []const u8, is_text: bool) usize {
            return self.pubsub.publish(topic, message, is_text);
        }
    };
}

const CompressionBuffers = struct {
    incoming: []u8,
    outgoing: []u8,
};

fn compression_buffers(
    storage: []u8,
    direction_capacity: usize,
    connection_index: usize,
) ?CompressionBuffers {
    if (direction_capacity == 0) return null;
    const stride = std.math.mul(usize, direction_capacity, 2) catch return null;
    const start = std.math.mul(usize, connection_index, stride) catch return null;
    const incoming_end = std.math.add(usize, start, direction_capacity) catch return null;
    const outgoing_end = std.math.add(usize, incoming_end, direction_capacity) catch return null;
    if (outgoing_end > storage.len) return null;

    return .{
        .incoming = storage[start..incoming_end],
        .outgoing = storage[incoming_end..outgoing_end],
    };
}

fn close_rejected_socket(socket: xev.TCP) void {
    close_socket_now(socket);
}

fn close_socket_now(socket: anytype) void {
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(@ptrCast(socket.fd));
        return;
    }
    _ = std.posix.system.close(socket.fd);
}

test "router: compression scratch separates receive and send state" {
    var storage = [_]u8{0} ** 32;
    const buffers = compression_buffers(&storage, 8, 1) orelse {
        return error.TestUnexpectedResult;
    };

    @memset(buffers.incoming, 0xa5);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 8), buffers.incoming);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), buffers.outgoing);
    try std.testing.expect(compression_buffers(&storage, 8, 2) == null);
}

test "router: route registration locks before callbacks can observe mutation" {
    const TestApp = app(1);
    var server = try TestApp.init(std.testing.io);
    defer server.deinit();
    server.routes_locked = true;

    const Handler = struct {
        fn handle(_: *@import("../http/request.zig").Request, _: *@import("../http/response.zig").Response) void {}
    };
    try std.testing.expectError(error.RoutesLocked, server.get("/", Handler.handle));
}
