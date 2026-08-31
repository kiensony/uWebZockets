const std = @import("std");
const c = @import("c");
const pool = @import("../core/pool.zig");
const Router = @import("../router/radix.zig").Router;
const api = @import("lsquic_api.zig");
const stream = @import("stream.zig");
const HeaderSet = stream.HeaderSet;
const QuicStream = stream.QuicStream;

pub const available = true;

pub fn quic_engine(comptime capacity: usize, comptime response_capacity: usize) type {
    if (capacity == 0) @compileError("QUIC capacity must be greater than zero");
    if (capacity > std.math.maxInt(c_uint)) @compileError("QUIC capacity exceeds lsquic limits");
    if (response_capacity == 0) @compileError("HTTP/3 response capacity must be greater than zero");
    if (capacity > std.math.maxInt(usize) / 4) @compileError("QUIC packet capacity overflows usize");
    if (capacity > std.math.maxInt(usize) / stream.header_capacity) {
        @compileError("HTTP/3 header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream.request_body_capacity) {
        @compileError("HTTP/3 request storage size overflows usize");
    }
    const stream_receive_capacity = stream.header_capacity + stream.request_body_capacity;
    if (capacity > std.math.maxInt(usize) / stream_receive_capacity) {
        @compileError("HTTP/3 connection flow-control capacity overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / stream.response_header_capacity) {
        @compileError("HTTP/3 response header storage size overflows usize");
    }
    if (capacity > std.math.maxInt(usize) / response_capacity) {
        @compileError("HTTP/3 response storage size overflows usize");
    }

    const packet_slot_count = @max(@as(usize, 16), capacity * 4);
    const PacketSlot = struct {
        bytes: [api.max_udp_payload_size]u8,
    };
    const StreamPool = pool.freelist_pool(QuicStream, capacity);
    const HeaderPool = pool.freelist_pool(HeaderSet, capacity);
    const PacketPool = pool.freelist_pool(PacketSlot, packet_slot_count);

    return struct {
        const Self = @This();

        engine: ?*c.lsquic_engine = null,
        ssl_ctx: *c.SSL_CTX = undefined,
        router: *const Router = undefined,
        udp_fd: std.posix.socket_t = -1,
        local_address: api.Sockaddr = .{},
        settings: c.lsquic_engine_settings = std.mem.zeroes(c.lsquic_engine_settings),
        stream_interface: c.lsquic_stream_if = std.mem.zeroes(c.lsquic_stream_if),
        header_interface: c.lsquic_hset_if = std.mem.zeroes(c.lsquic_hset_if),
        packet_interface: c.lsquic_packout_mem_if = std.mem.zeroes(c.lsquic_packout_mem_if),
        engine_api: c.lsquic_engine_api = std.mem.zeroes(c.lsquic_engine_api),
        stream_pool: StreamPool,
        header_pool: HeaderPool,
        packet_pool: PacketPool,
        header_storage: []u8,
        request_body_storage: []u8,
        response_header_storage: []u8,
        response_body_storage: []u8,
        active_connections: usize = 0,
        global_acquired: bool = false,

        pub fn init() !Self {
            var stream_pool = try StreamPool.init();
            errdefer stream_pool.deinit();
            var header_pool = try HeaderPool.init();
            errdefer header_pool.deinit();
            var packet_pool = try PacketPool.init();
            errdefer packet_pool.deinit();

            const header_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream.header_capacity,
            );
            errdefer std.heap.page_allocator.free(header_storage);
            const request_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream.request_body_capacity,
            );
            errdefer std.heap.page_allocator.free(request_body_storage);
            const response_header_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * stream.response_header_capacity,
            );
            errdefer std.heap.page_allocator.free(response_header_storage);
            const response_body_storage = try std.heap.page_allocator.alloc(
                u8,
                capacity * response_capacity,
            );
            errdefer std.heap.page_allocator.free(response_body_storage);

            return .{
                .stream_pool = stream_pool,
                .header_pool = header_pool,
                .packet_pool = packet_pool,
                .header_storage = header_storage,
                .request_body_storage = request_body_storage,
                .response_header_storage = response_header_storage,
                .response_body_storage = response_body_storage,
            };
        }

        pub fn start(
            self: *Self,
            ssl_ctx: *c.SSL_CTX,
            router: *const Router,
            udp_fd: std.posix.socket_t,
            local_address: std.Io.net.IpAddress,
        ) !void {
            if (self.engine != null) return error.QuicEngineAlreadyStarted;
            try api.acquire_global();
            self.global_acquired = true;
            errdefer {
                api.release_global();
                self.global_acquired = false;
            }

            self.ssl_ctx = ssl_ctx;
            self.router = router;
            self.udp_fd = udp_fd;
            self.local_address = api.Sockaddr.init(local_address);

            c.lsquic_engine_init_settings(&self.settings, c.LSENG_HTTP_SERVER);
            self.settings.es_max_streams_in = @intCast(capacity);
            self.settings.es_max_inchoate = @intCast(capacity);
            self.settings.es_max_header_list_size = stream.header_capacity;
            self.settings.es_max_header_sets = 1;
            self.settings.es_qpack_dec_max_size = 0;
            self.settings.es_qpack_dec_max_blocked = 0;
            self.settings.es_init_max_streams_bidi = @intCast(capacity);
            self.settings.es_init_max_stream_data_bidi_remote = stream_receive_capacity;
            self.settings.es_init_max_data = @intCast(@min(
                capacity * stream_receive_capacity,
                std.math.maxInt(c_uint),
            ));
            self.settings.es_max_udp_payload_size_rx = api.max_udp_payload_size;
            self.settings.es_base_plpmtu = 1200;
            self.settings.es_max_plpmtu = 1472;
            self.settings.es_max_batch_size = 16;
            self.settings.es_rw_once = 1;
            self.settings.es_proc_time_thresh = 10_000;

            var settings_error: [256]u8 = undefined;
            if (c.lsquic_engine_check_settings(
                &self.settings,
                c.LSENG_HTTP_SERVER,
                &settings_error,
                settings_error.len,
            ) != 0) return error.InvalidLsquicSettings;

            self.stream_interface = std.mem.zeroes(c.lsquic_stream_if);
            self.stream_interface.on_new_conn = on_new_connection;
            self.stream_interface.on_conn_closed = on_connection_closed;
            self.stream_interface.on_new_stream = on_new_stream;
            self.stream_interface.on_read = on_stream_read;
            self.stream_interface.on_write = on_stream_write;
            self.stream_interface.on_close = on_stream_close;
            self.stream_interface.on_hset_in = on_header_set_available;

            self.header_interface = std.mem.zeroes(c.lsquic_hset_if);
            self.header_interface.hsi_create_header_set = create_header_set;
            self.header_interface.hsi_prepare_decode = prepare_header_decode;
            self.header_interface.hsi_process_header = process_header;
            self.header_interface.hsi_discard_header_set = discard_header_set;

            self.packet_interface = std.mem.zeroes(c.lsquic_packout_mem_if);
            self.packet_interface.pmi_allocate = allocate_packet;
            self.packet_interface.pmi_release = release_packet;
            self.packet_interface.pmi_return = release_packet;

            self.engine_api = std.mem.zeroes(c.lsquic_engine_api);
            self.engine_api.ea_settings = &self.settings;
            self.engine_api.ea_stream_if = &self.stream_interface;
            self.engine_api.ea_stream_if_ctx = self;
            self.engine_api.ea_packets_out = packets_out;
            self.engine_api.ea_packets_out_ctx = self;
            self.engine_api.ea_get_ssl_ctx = get_ssl_context;
            self.engine_api.ea_hsi_if = &self.header_interface;
            self.engine_api.ea_hsi_ctx = self;
            self.engine_api.ea_pmi = &self.packet_interface;
            self.engine_api.ea_pmi_ctx = self;

            self.engine = c.lsquic_engine_new(c.LSENG_HTTP_SERVER, &self.engine_api) orelse {
                return error.LsquicEngineCreationFailed;
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.engine) |engine| c.lsquic_engine_destroy(engine);
            self.engine = null;
            self.udp_fd = -1;

            std.debug.assert(self.stream_pool.count_active() == 0);
            std.debug.assert(self.header_pool.count_active() == 0);
            std.debug.assert(self.packet_pool.count_active() == 0);
            std.debug.assert(self.active_connections == 0);
            if (self.global_acquired) api.release_global();
            self.global_acquired = false;

            std.heap.page_allocator.free(self.response_body_storage);
            std.heap.page_allocator.free(self.response_header_storage);
            std.heap.page_allocator.free(self.request_body_storage);
            std.heap.page_allocator.free(self.header_storage);
            self.packet_pool.deinit();
            self.header_pool.deinit();
            self.stream_pool.deinit();
        }

        pub fn process_datagram(self: *Self, data: []const u8, peer: std.Io.net.IpAddress) void {
            const engine = self.engine orelse return;
            if (data.len == 0 or data.len > api.max_udp_payload_size) return;

            const peer_address = api.Sockaddr.init(peer);
            if (c.lsquic_engine_packet_in(
                engine,
                data.ptr,
                data.len,
                self.local_address.ptr(),
                peer_address.ptr(),
                self,
                0,
            ) < 0) return;
            self.process();
        }

        pub fn process(self: *Self) void {
            const engine = self.engine orelse return;
            if (c.lsquic_engine_has_unsent_packets(engine) != 0) {
                c.lsquic_engine_send_unsent_packets(engine);
            }
            c.lsquic_engine_process_conns(engine);
        }

        pub fn cooldown(self: *Self) void {
            const engine = self.engine orelse return;
            c.lsquic_engine_cooldown(engine);
            c.lsquic_engine_process_conns(engine);
        }

        pub fn next_timeout_ms(self: *Self) u64 {
            const engine = self.engine orelse return 50;
            var microseconds: c_int = 0;
            if (c.lsquic_engine_earliest_adv_tick(engine, &microseconds) == 0) return 50;
            if (microseconds <= 0) return 1;
            const rounded: u64 = @divTrunc(@as(u64, @intCast(microseconds)) + 999, 1000);
            return std.math.clamp(rounded, 1, 50);
        }

        fn acquire_header_set(self: *Self) ?*HeaderSet {
            const header_set = self.header_pool.acquire() orelse return null;
            const index = self.header_pool.index_of(header_set) orelse unreachable;
            const storage_start = index * stream.header_capacity;
            header_set.reset(
                self,
                release_header_set,
                self.header_storage[storage_start .. storage_start + stream.header_capacity],
            );
            return header_set;
        }

        fn release_header_set(context: *anyopaque, header_set: *HeaderSet) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.header_pool.release(header_set));
        }

        fn acquire_stream(self: *Self, lsquic_stream: *c.lsquic_stream) ?*QuicStream {
            const quic_stream = self.stream_pool.acquire() orelse return null;
            const index = self.stream_pool.index_of(quic_stream) orelse unreachable;
            const body_start = index * stream.request_body_capacity;
            const response_header_start = index * stream.response_header_capacity;
            const response_body_start = index * response_capacity;
            quic_stream.reset(
                self,
                release_stream,
                lsquic_stream,
                self.router,
                self.request_body_storage[body_start .. body_start + stream.request_body_capacity],
                self.response_body_storage[response_body_start .. response_body_start + response_capacity],
                self.response_header_storage[response_header_start .. response_header_start + stream.response_header_capacity],
            );
            return quic_stream;
        }

        fn release_stream(context: *anyopaque, quic_stream: *QuicStream) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.stream_pool.release(quic_stream));
        }

        fn on_new_connection(context: ?*anyopaque, connection: ?*c.lsquic_conn) callconv(.c) ?*c.lsquic_conn_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const conn = connection orelse return null;
            if (self.active_connections >= capacity) {
                c.lsquic_conn_abort(conn);
                return null;
            }
            self.active_connections += 1;
            return @ptrCast(self);
        }

        fn on_connection_closed(connection: ?*c.lsquic_conn) callconv(.c) void {
            const conn = connection orelse return;
            const context = c.lsquic_conn_get_ctx(conn) orelse return;
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.active_connections != 0) self.active_connections -= 1;
            c.lsquic_conn_set_ctx(conn, null);
        }

        fn on_new_stream(context: ?*anyopaque, lsquic_stream: ?*c.lsquic_stream) callconv(.c) ?*c.lsquic_stream_ctx {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const raw_stream = lsquic_stream orelse return null;
            const quic_stream = self.acquire_stream(raw_stream) orelse {
                _ = c.lsquic_stream_close(raw_stream);
                return null;
            };
            _ = c.lsquic_stream_wantread(raw_stream, 1);
            return @ptrCast(quic_stream);
        }

        fn on_stream_read(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_read();
        }

        fn on_stream_write(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_write();
        }

        fn on_stream_close(_: ?*c.lsquic_stream, context: ?*c.lsquic_stream_ctx) callconv(.c) void {
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            quic_stream.on_close();
        }

        fn on_header_set_available(
            lsquic_stream: ?*c.lsquic_stream,
            context: ?*c.lsquic_stream_ctx,
        ) callconv(.c) void {
            const raw_stream = lsquic_stream orelse return;
            const quic_stream: *QuicStream = @ptrCast(@alignCast(context orelse return));
            const raw_header_set = c.lsquic_stream_get_hset(raw_stream) orelse {
                _ = c.lsquic_stream_close(raw_stream);
                return;
            };
            const header_set: *HeaderSet = @ptrCast(@alignCast(raw_header_set));
            quic_stream.attach_headers(header_set);
        }

        fn create_header_set(
            context: ?*anyopaque,
            _: ?*c.lsquic_stream,
            is_push_promise: c_int,
        ) callconv(.c) ?*anyopaque {
            if (is_push_promise != 0) return null;
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            return self.acquire_header_set();
        }

        fn prepare_header_decode(
            context: ?*anyopaque,
            existing: ?*c.lsxpack_header,
            required: usize,
        ) callconv(.c) ?*c.lsxpack_header {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return null));
            return header_set.prepare_decode(existing, required);
        }

        fn process_header(context: ?*anyopaque, header: ?*c.lsxpack_header) callconv(.c) c_int {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return -1));
            return if (header_set.process_header(header)) 0 else 1;
        }

        fn discard_header_set(context: ?*anyopaque) callconv(.c) void {
            const header_set: *HeaderSet = @ptrCast(@alignCast(context orelse return));
            header_set.release();
        }

        fn packets_out(
            context: ?*anyopaque,
            specs: [*c]const c.lsquic_out_spec,
            count: c_uint,
        ) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(context orelse return -1));
            return api.send_packets(self.udp_fd, specs, count);
        }

        fn get_ssl_context(
            peer_context: ?*anyopaque,
            _: [*c]const c.struct_sockaddr,
        ) callconv(.c) ?*c.SSL_CTX {
            const self: *Self = @ptrCast(@alignCast(peer_context orelse return null));
            return self.ssl_ctx;
        }

        fn allocate_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            _: ?*c.lsquic_conn_ctx,
            size: c_ushort,
            _: u8,
        ) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            if (size == 0 or size > api.max_udp_payload_size) return null;
            const slot = self.packet_pool.acquire() orelse return null;
            return &slot.bytes;
        }

        fn release_packet(
            context: ?*anyopaque,
            _: ?*anyopaque,
            buffer: ?*anyopaque,
            _: u8,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            const raw_buffer = buffer orelse return;
            const slot: *PacketSlot = @ptrCast(@alignCast(raw_buffer));
            std.debug.assert(self.packet_pool.release(slot));
        }
    };
}
