const std = @import("std");
const xev = @import("xev");
const c = @import("c");
const Loop = @import("loop.zig").Loop;
const http_parser = @import("../http/parser.zig");
const HttpParser = http_parser.HttpParser;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const radix = @import("../router/radix.zig");
const Router = radix.Router;
const handshake = @import("../crypto/handshake.zig");
const DeflateContext = @import("../ws/deflate.zig").Context;

pub const socket_read_capacity = 8192;
pub const request_buffer_capacity = http_parser.max_request_line_size +
    http_parser.max_header_size + http_parser.max_body_size + 1024;
pub const default_write_queue_capacity = 64 * 1024;

const tls_bio_capacity = 32 * 1024;
const tls_plaintext_record_capacity = 16 * 1024;
const tls_record_overhead = 64;

pub const ProtocolState = enum(u8) {
    http,
    websocket,
};

pub const TcpConnection = struct {
    router: *const Router = undefined,
    pubsub: ?*@import("../ws/pubsub.zig").PubSubEngine = null,
    pool_ptr: ?*anyopaque = null,
    on_close_cb: ?*const fn (pool_ptr: *anyopaque, conn: *TcpConnection) void = null,
    loop: *xev.Loop = undefined,
    io: std.Io = undefined,
    socket: xev.TCP,
    ws_message_buffer: []u8 = &.{},
    ws_compression_buffer: []u8 = &.{},
    ws_compression_output_buffer: []u8 = &.{},
    ws_deflate: ?*DeflateContext = null,

    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    read_cancel_completion: xev.Completion = .{},
    write_cancel_completion: xev.Completion = .{},

    req: Request = .{},
    parser: HttpParser = .{},
    ws: WebSocket = undefined,

    last_active_ms: i64 = 0,
    request_len: usize = 0,
    write_head: usize = 0,
    write_len: usize = 0,
    write_in_flight_len: usize = 0,

    ssl: ?*c.SSL = null,
    network_bio: ?*c.BIO = null,
    protocol_state: ProtocolState = .http,
    is_tls_handshake_done: bool = false,
    tls_shutdown_started: bool = false,
    read_active: bool = false,
    is_writing: bool = false,
    read_cancel_active: bool = false,
    write_cancel_active: bool = false,
    close_complete: bool = false,
    was_backpressured: bool = false,
    close_when_drained: bool = false,
    closing: bool = false,
    expect_continue_sent: bool = false,
    suppress_response_body: bool = false,

    read_buffer: [socket_read_capacity]u8 = undefined,
    request_buffer: [request_buffer_capacity]u8 = undefined,
    tls_write_buffer: [8192]u8 = undefined,
    write_queue: []u8 = &.{},

    pub fn init_tls(self: *TcpConnection, ssl_ctx: *c.SSL_CTX) !void {
        if (self.ssl != null or self.network_bio != null) return error.TlsAlreadyInitialized;

        const ssl = c.SSL_new(ssl_ctx) orelse return error.SslAllocationFailed;
        errdefer c.SSL_free(ssl);

        var ssl_bio: ?*c.BIO = null;
        var network_bio: ?*c.BIO = null;
        if (c.BIO_new_bio_pair(
            &ssl_bio,
            tls_bio_capacity,
            &network_bio,
            tls_bio_capacity,
        ) != 1) return error.BioAllocationFailed;
        errdefer {
            if (ssl_bio) |bio| _ = c.BIO_free(bio);
        }
        errdefer {
            if (network_bio) |bio| _ = c.BIO_free(bio);
        }

        c.SSL_set_bio(ssl, ssl_bio.?, ssl_bio.?);
        ssl_bio = null;
        c.SSL_set_accept_state(ssl);
        self.ssl = ssl;
        self.network_bio = network_bio;
        network_bio = null;
        self.tls_shutdown_started = false;
    }

    pub fn deinit_tls(self: *TcpConnection) void {
        const ssl = self.ssl orelse return;
        c.SSL_free(ssl);
        self.ssl = null;
        if (self.network_bio) |bio| _ = c.BIO_free(bio);
        self.network_bio = null;
        self.is_tls_handshake_done = false;
        self.tls_shutdown_started = false;
    }

    pub fn process_tls_data(self: *TcpConnection, ssl: *c.SSL, encrypted_data: []const u8) void {
        const network_bio = self.network_bio orelse {
            close_connection(self);
            return;
        };
        var offset: usize = 0;

        while (offset < encrypted_data.len) {
            const remaining = encrypted_data.len - offset;
            const write_len: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
            const written = c.BIO_write(network_bio, encrypted_data[offset..].ptr, write_len);
            if (written <= 0) {
                close_connection(self);
                return;
            }
            offset += @intCast(written);
        }

        if (!self.is_tls_handshake_done) {
            self.drive_tls_handshake(ssl) catch {
                close_connection(self);
                return;
            };
            if (!self.is_tls_handshake_done) return;
        }

        var plain_buffer: [socket_read_capacity]u8 = undefined;
        while (!self.closing) {
            const read_bytes = c.SSL_read(ssl, &plain_buffer, plain_buffer.len);
            if (read_bytes > 0) {
                self.route_decrypted_data(plain_buffer[0..@intCast(read_bytes)]);
                continue;
            }

            const ssl_error = c.SSL_get_error(ssl, read_bytes);
            switch (ssl_error) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => break,
                c.SSL_ERROR_ZERO_RETURN => close_after_flush(self),
                else => close_connection(self),
            }
            break;
        }

        self.flush_tls_out() catch close_connection(self);
    }

    fn drive_tls_handshake(self: *TcpConnection, ssl: *c.SSL) !void {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const status = handshake.step(ssl);
            try self.flush_tls_out();

            switch (status) {
                .success => {
                    self.is_tls_handshake_done = true;
                    return;
                },
                .want_read => return,
                .want_write => {
                    const network_bio = self.network_bio orelse return error.TlsUnavailable;
                    if (c.BIO_ctrl_pending(network_bio) != 0) return;
                },
                .failed => return error.TlsHandshakeFailed,
            }
        }
        return error.TlsHandshakeStalled;
    }

    pub fn route_decrypted_data(self: *TcpConnection, data: []u8) void {
        switch (self.protocol_state) {
            .http => self.route_http_data(data),
            .websocket => self.ws.on_data(data),
        }
    }

    fn route_http_data(self: *TcpConnection, data: []const u8) void {
        const available = self.request_buffer.len - self.request_len;
        if (data.len > available) {
            const status = switch (self.parser.state) {
                .body, .chunk_size, .chunk_ext, .chunk_data, .chunk_crlf, .chunk_trailer => "413 Payload Too Large",
                else => "431 Request Header Fields Too Large",
            };
            self.reject_http(status, "Request exceeds the configured limit");
            return;
        }

        @memcpy(self.request_buffer[self.request_len .. self.request_len + data.len], data);
        self.request_len += data.len;

        while (self.request_len > 0 and !self.closing) {
            const consumed = http_parser.consume(
                &self.parser,
                &self.req,
                self.request_buffer[0..self.request_len],
            );

            if (self.parser.state == .error_invalid) {
                self.reject_http("400 Bad Request", "Bad Request");
                return;
            }
            if (self.parser.state == .error_headers_too_large) {
                self.reject_http("431 Request Header Fields Too Large", "Request headers too large");
                return;
            }
            if (self.parser.state == .error_too_large) {
                self.reject_http("413 Payload Too Large", "Payload Too Large");
                return;
            }
            if (self.parser.state != .done) {
                self.handle_expect_continue();
                return;
            }

            const close_requested = self.req.header_has_token("Connection", "close");
            self.dispatch_request();
            if (self.closing or self.close_when_drained) return;

            if (self.protocol_state == .websocket) {
                if (consumed < self.request_len) {
                    self.ws.on_data(self.request_buffer[consumed..self.request_len]);
                }
                self.request_len = 0;
                return;
            }

            if (close_requested) {
                close_after_flush(self);
                return;
            }

            const remaining = self.request_len - consumed;
            std.mem.copyForwards(
                u8,
                self.request_buffer[0..remaining],
                self.request_buffer[consumed..self.request_len],
            );
            self.request_len = remaining;
            self.req = .{};
            http_parser.reset(&self.parser);
            self.expect_continue_sent = false;
            self.suppress_response_body = false;
        }
    }

    fn dispatch_request(self: *TcpConnection) void {
        var response = Response{ .target = .{ .tcp = self } };
        const method = radix.HttpMethod.parse(self.req.method);
        self.suppress_response_body = method == .head;

        const route = self.router.match(self.req.path, method) orelse {
            response.end("404 Not Found", "Route not found") catch close_connection(self);
            return;
        };

        const websocket_intent = route.ws_behavior != null and method == .get and
            (self.req.get_header("Upgrade") != null or self.req.header_has_token("Connection", "upgrade"));
        if (websocket_intent) {
            self.ws = WebSocket{ .conn = self, .pubsub = self.pubsub };
            self.ws.upgrade(&self.req, &response, route.ws_behavior.?);
            return;
        }

        if (route.http_handler) |handler| {
            handler(&self.req, &response);
            if (response.is_complete()) return;

            if (response.is_started()) {
                close_after_flush(self);
                return;
            }
            response.end("500 Internal Server Error", "Handler did not complete the response") catch close_connection(self);
            return;
        }

        if (method == .options) {
            self.send_method_response(&response, route.allowed_methods, "204 No Content", "");
            return;
        }

        if (route.ws_behavior != null and method == .get) {
            response.end_with_headers(
                "426 Upgrade Required",
                "Connection: close\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n",
                "WebSocket upgrade required",
            ) catch {
                close_connection(self);
                return;
            };
            close_after_flush(self);
            return;
        }

        self.send_method_response(&response, route.allowed_methods, "405 Method Not Allowed", "Method Not Allowed");
    }

    fn send_method_response(
        self: *TcpConnection,
        response: *Response,
        allowed_methods: u16,
        status: []const u8,
        body: []const u8,
    ) void {
        var allow_value_buffer: [64]u8 = undefined;
        const allow_value = radix.format_allowed_methods(allowed_methods, &allow_value_buffer) catch {
            close_connection(self);
            return;
        };
        var allow_header_buffer: [80]u8 = undefined;
        const allow_header = std.fmt.bufPrint(
            &allow_header_buffer,
            "Allow: {s}\r\n",
            .{allow_value},
        ) catch {
            close_connection(self);
            return;
        };
        response.end_with_headers(status, allow_header, body) catch close_connection(self);
    }

    fn handle_expect_continue(self: *TcpConnection) void {
        if (self.expect_continue_sent or self.closing) return;

        switch (self.parser.state) {
            .body, .chunk_size, .chunk_ext, .chunk_data, .chunk_crlf, .chunk_trailer => {},
            else => return,
        }

        const expect_count = self.req.count_headers("Expect");
        if (expect_count == 0) return;
        const expect = self.req.get_unique_header("Expect") orelse {
            self.reject_http("417 Expectation Failed", "Expectation Failed");
            return;
        };
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, expect, " \t"), "100-continue")) {
            self.reject_http("417 Expectation Failed", "Expectation Failed");
            return;
        }

        self.write_data("HTTP/1.1 100 Continue\r\n\r\n") catch {
            close_connection(self);
            return;
        };
        self.expect_continue_sent = true;
    }

    fn reject_http(self: *TcpConnection, status: []const u8, body: []const u8) void {
        var response = Response{ .target = .{ .tcp = self } };
        response.end_with_headers(status, "Connection: close\r\n", body) catch {
            close_connection(self);
            return;
        };
        close_after_flush(self);
    }

    fn flush_tls_out(self: *TcpConnection) !void {
        if (self.ssl == null) return;
        const network_bio = self.network_bio orelse return error.TlsUnavailable;

        while (c.BIO_ctrl_pending(network_bio) > 0) {
            const available = self.write_queue.len - self.write_len;
            if (available == 0) return;

            const pending: usize = @intCast(c.BIO_ctrl_pending(network_bio));
            const read_len = @min(pending, @min(self.tls_write_buffer.len, available));
            const read_bytes = c.BIO_read(network_bio, &self.tls_write_buffer, @intCast(read_len));
            if (read_bytes <= 0) return error.TlsWriteFailed;

            const encrypted = self.tls_write_buffer[0..@intCast(read_bytes)];
            try self.enqueue_plain_parts(&.{encrypted});
        }
    }

    fn enqueue_plain_parts(self: *TcpConnection, parts: []const []const u8) !void {
        if (self.closing) return error.ConnectionClosed;

        var total_len: usize = 0;
        for (parts) |part| {
            if (part.len > self.write_queue.len - total_len) return error.WouldBlock;
            total_len += part.len;
        }
        if (total_len > self.write_queue.len - self.write_len) return error.WouldBlock;
        if (total_len == 0) return;

        const tail = (self.write_head + self.write_len) % self.write_queue.len;
        _ = copy_parts_to_ring(self.write_queue, tail, parts);

        self.write_len += total_len;
        if (self.write_len >= self.write_queue.len / 2) self.was_backpressured = true;
        self.start_write();
    }

    fn write_tls_parts(self: *TcpConnection, parts: []const []const u8) !void {
        const ssl = self.ssl orelse return error.TlsUnavailable;
        const network_bio = self.network_bio orelse return error.TlsUnavailable;

        var plain_len: usize = 0;
        var record_count: usize = 0;
        for (parts) |part| {
            if (part.len > self.write_queue.len - plain_len) return error.WouldBlock;
            plain_len += part.len;

            const part_records = std.math.divCeil(
                usize,
                part.len,
                tls_plaintext_record_capacity,
            ) catch return error.WouldBlock;
            if (part_records > std.math.maxInt(usize) - record_count) return error.WouldBlock;
            record_count += part_records;
        }

        const pending: usize = @intCast(c.BIO_ctrl_pending(network_bio));
        if (record_count > self.write_queue.len / tls_record_overhead) return error.WouldBlock;
        const overhead = tls_record_overhead * record_count;
        if (overhead > self.write_queue.len - plain_len) return error.WouldBlock;
        const required = plain_len + overhead;
        if (pending > self.write_queue.len - required) return error.WouldBlock;
        if (required + pending > self.write_queue.len - self.write_len) return error.WouldBlock;

        for (parts) |part| {
            var offset: usize = 0;
            while (offset < part.len) {
                const remaining = part.len - offset;
                const chunk_len: c_int = @intCast(@min(remaining, tls_plaintext_record_capacity));
                const written = c.SSL_write(ssl, part[offset..].ptr, chunk_len);
                if (written <= 0) {
                    const ssl_error = c.SSL_get_error(ssl, written);
                    if (ssl_error != c.SSL_ERROR_WANT_WRITE) return error.TlsWriteFailed;
                    try self.flush_tls_out();
                    continue;
                }
                offset += @intCast(written);
                try self.flush_tls_out();
            }
        }
    }

    fn begin_tls_shutdown(self: *TcpConnection) !void {
        if (self.tls_shutdown_started or !self.is_tls_handshake_done) return;
        const ssl = self.ssl orelse return;
        self.tls_shutdown_started = true;

        const result = c.SSL_shutdown(ssl);
        if (result < 0) {
            const ssl_error = c.SSL_get_error(ssl, result);
            if (ssl_error != c.SSL_ERROR_WANT_READ and ssl_error != c.SSL_ERROR_WANT_WRITE) {
                return error.TlsShutdownFailed;
            }
        }
        try self.flush_tls_out();
    }

    fn start_write(self: *TcpConnection) void {
        if (self.is_writing or self.write_len == 0 or self.closing) return;

        const contiguous_len = @min(self.write_len, self.write_queue.len - self.write_head);
        self.write_in_flight_len = contiguous_len;
        self.is_writing = true;
        self.socket.write(
            self.loop,
            &self.write_completion,
            .{ .slice = self.write_queue[self.write_head .. self.write_head + contiguous_len] },
            TcpConnection,
            self,
            on_write_complete,
        );
    }

    pub fn write_data(self: *TcpConnection, data: []const u8) !void {
        try self.write_data_parts(&.{data});
    }

    pub fn write_data_parts(self: *TcpConnection, parts: []const []const u8) !void {
        if (self.closing or self.close_when_drained) return error.ConnectionClosed;
        if (self.ssl != null) return self.write_tls_parts(parts);
        return self.enqueue_plain_parts(parts);
    }

    pub fn buffered_amount(self: *const TcpConnection) usize {
        return self.write_len;
    }
};

fn copy_parts_to_ring(buffer: []u8, initial_tail: usize, parts: []const []const u8) usize {
    std.debug.assert(buffer.len > 0);
    var tail = initial_tail;

    for (parts) |part| {
        const first_len = @min(part.len, buffer.len - tail);
        @memcpy(buffer[tail .. tail + first_len], part[0..first_len]);

        const second_len = part.len - first_len;
        if (second_len > 0) @memcpy(buffer[0..second_len], part[first_len..]);
        tail = (tail + part.len) % buffer.len;
    }
    return tail;
}

pub fn read_start(conn: *TcpConnection, loop: *Loop) void {
    conn.loop = loop.get_xev_loop();
    conn.read_active = true;
    conn.socket.read(
        conn.loop,
        &conn.read_completion,
        .{ .slice = &conn.read_buffer },
        TcpConnection,
        conn,
        on_read_complete,
    );
}

fn on_read_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn = user_data.?;
    conn.loop = loop;
    conn.read_active = false;

    if (conn.closing) {
        release_closed_connection(conn);
        return .disarm;
    }

    const bytes_read = result catch |err| {
        if (err != error.EOF and err != error.ConnectionResetByPeer) {
            std.debug.print("read error: {}\n", .{err});
        }
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    };

    if (bytes_read == 0) {
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    }

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    const data = conn.read_buffer[0..bytes_read];
    if (conn.ssl) |ssl| {
        conn.process_tls_data(ssl, data);
    } else {
        conn.route_decrypted_data(data);
    }

    if (conn.closing or conn.close_when_drained) {
        release_closed_connection(conn);
        return .disarm;
    }
    conn.read_active = true;
    return .rearm;
}

fn on_write_complete(
    user_data: ?*TcpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn = user_data.?;
    conn.is_writing = false;

    if (conn.closing) {
        conn.write_in_flight_len = 0;
        release_closed_connection(conn);
        return .disarm;
    }

    const written = result catch |err| {
        std.debug.print("write error: {}\n", .{err});
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    };

    if (written == 0 or written > conn.write_in_flight_len) {
        close_connection(conn);
        release_closed_connection(conn);
        return .disarm;
    }

    const now = std.Io.Clock.now(.awake, conn.io);
    conn.last_active_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    conn.write_len -= written;
    conn.write_head = advance_write_head(
        conn.write_head,
        written,
        conn.write_len,
        conn.write_queue.len,
    );
    conn.write_in_flight_len = 0;

    conn.flush_tls_out() catch {
        close_connection(conn);
        return .disarm;
    };
    if (conn.ssl) |ssl| {
        if (!conn.is_tls_handshake_done and !conn.close_when_drained) {
            conn.drive_tls_handshake(ssl) catch {
                close_connection(conn);
                return .disarm;
            };
        }
    }

    if (conn.was_backpressured and conn.write_len < conn.write_queue.len / 2) {
        conn.was_backpressured = false;
        if (conn.protocol_state == .websocket) conn.ws.notify_drain();
    }

    if (conn.write_len == 0 and conn.close_when_drained) {
        close_connection(conn);
        return .disarm;
    }

    conn.start_write();
    return .disarm;
}

fn advance_write_head(
    current_head: usize,
    written: usize,
    remaining: usize,
    capacity: usize,
) usize {
    std.debug.assert(capacity != 0);
    if (remaining == 0) return 0;
    return (current_head + written) % capacity;
}

pub fn close_after_flush(conn: *TcpConnection) void {
    if (conn.closing) return;
    conn.begin_tls_shutdown() catch {
        close_connection(conn);
        return;
    };
    conn.flush_tls_out() catch {
        close_connection(conn);
        return;
    };
    conn.close_when_drained = true;
    if (conn.write_len == 0 and !conn.is_writing) close_connection(conn);
}

pub fn close_connection(conn: *TcpConnection) void {
    if (conn.closing) return;
    conn.closing = true;
    conn.close_when_drained = false;

    if (conn.protocol_state == .websocket) conn.ws.deinit();
    conn.deinit_tls();

    if (conn.read_active) {
        conn.read_cancel_active = true;
        conn.loop.cancel(
            &conn.read_completion,
            &conn.read_cancel_completion,
            TcpConnection,
            conn,
            on_read_cancel_complete,
        );
    }
    if (conn.is_writing) {
        conn.write_cancel_active = true;
        conn.loop.cancel(
            &conn.write_completion,
            &conn.write_cancel_completion,
            TcpConnection,
            conn,
            on_write_cancel_complete,
        );
    }

    conn.socket.close(
        conn.loop,
        &conn.close_completion,
        TcpConnection,
        conn,
        (struct {
            fn cb(
                user_data: ?*TcpConnection,
                loop: *xev.Loop,
                completion: *xev.Completion,
                socket: xev.TCP,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion;
                _ = socket;
                // The descriptor is already closed regardless of the reported close status.
                _ = result catch |err| {
                    std.debug.print("socket close error: {}\n", .{err});
                };

                const connection = user_data orelse return .disarm;
                connection.close_complete = true;
                release_closed_connection(connection);
                return .disarm;
            }
        }).cb,
    );
}

fn on_read_cancel_complete(
    user_data: ?*TcpConnection,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const conn = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) std.debug.print("read cancel error: {}\n", .{err});
    };
    conn.read_cancel_active = false;
    release_closed_connection(conn);
    return .disarm;
}

fn on_write_cancel_complete(
    user_data: ?*TcpConnection,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    const conn = user_data.?;
    _ = result catch |err| {
        if (err != error.NotFound) std.debug.print("write cancel error: {}\n", .{err});
    };
    conn.write_cancel_active = false;
    release_closed_connection(conn);
    return .disarm;
}

fn release_closed_connection(conn: *TcpConnection) void {
    if (!conn.closing or !conn.close_complete) return;
    if (conn.read_active or conn.is_writing) return;
    if (conn.read_cancel_active or conn.write_cancel_active) return;

    const callback = conn.on_close_cb orelse return;
    const pool = conn.pool_ptr orelse return;

    conn.last_active_ms = 0;
    conn.request_len = 0;
    conn.write_head = 0;
    conn.write_len = 0;
    conn.write_in_flight_len = 0;
    conn.was_backpressured = false;
    conn.on_close_cb = null;
    conn.pool_ptr = null;
    callback(pool, conn);
}

pub const AcceptCallback = *const fn (socket: xev.TCP, user_data: ?*anyopaque) void;

pub const TcpServer = struct {
    accept_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    accept_cancel_completion: xev.Completion = .{},
    listener: xev.TCP,
    on_connection: AcceptCallback,
    user_data: ?*anyopaque,
    closing: bool = false,
    close_complete: bool = false,
};

pub fn init_server(address: []const u8, port: u16, callback: AcceptCallback, user_data: ?*anyopaque) !TcpServer {
    const parsed_address = try std.Io.net.IpAddress.parse(address, port);
    var listener = try xev.TCP.init(parsed_address);
    errdefer close_unregistered_socket(listener);
    try listener.bind(parsed_address);
    try listener.listen(128);

    return .{
        .listener = listener,
        .on_connection = callback,
        .user_data = user_data,
    };
}

pub fn accept_start(server: *TcpServer, loop: *Loop) void {
    if (server.closing) return;
    server.listener.accept(
        loop.get_xev_loop(),
        &server.accept_completion,
        TcpServer,
        server,
        on_accept_complete,
    );
}

pub fn close_server(server: *TcpServer, loop: *Loop) void {
    if (server.closing) return;
    server.closing = true;
    if (server.accept_completion.state() == .active) {
        loop.get_xev_loop().cancel(
            &server.accept_completion,
            &server.accept_cancel_completion,
            void,
            null,
            on_accept_cancel_complete,
        );
    }
    server.listener.close(
        loop.get_xev_loop(),
        &server.close_completion,
        TcpServer,
        server,
        on_server_close_complete,
    );
}

fn on_accept_cancel_complete(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.CancelError!void,
) xev.CallbackAction {
    _ = result catch |err| {
        if (err != error.NotFound) std.debug.print("accept cancel error: {}\n", .{err});
    };
    return .disarm;
}

fn on_accept_complete(
    user_data: ?*TcpServer,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const server = user_data.?;
    const accepted_socket = result catch |err| {
        if (server.closing) return .disarm;
        std.debug.print("accept error: {}\n", .{err});
        return .rearm;
    };

    if (server.closing) {
        close_unregistered_socket(accepted_socket);
        return .disarm;
    }

    server.on_connection(accepted_socket, server.user_data);
    return .rearm;
}

fn on_server_close_complete(
    user_data: ?*TcpServer,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    result: xev.CloseError!void,
) xev.CallbackAction {
    const server = user_data.?;
    _ = result catch |err| {
        std.debug.print("listener close error: {}\n", .{err});
    };
    server.close_complete = true;
    return .disarm;
}

fn close_unregistered_socket(socket: xev.TCP) void {
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(@ptrCast(socket.fd));
        return;
    }
    _ = std.posix.system.close(socket.fd);
}

test "tcp: multipart ring writes preserve order across wrap" {
    var buffer = [_]u8{0} ** 8;
    const tail = copy_parts_to_ring(&buffer, 6, &.{ "ab", "cde" });

    try std.testing.expectEqual(@as(usize, 3), tail);
    try std.testing.expectEqualStrings("cde", buffer[0..3]);
    try std.testing.expectEqualStrings("ab", buffer[6..8]);
}

test "tcp: drained write ring normalizes its head" {
    try std.testing.expectEqual(@as(usize, 0), advance_write_head(65_504, 32, 0, 65_536));
    try std.testing.expectEqual(@as(usize, 0), advance_write_head(65_504, 32, 57, 65_536));
    try std.testing.expectEqual(@as(usize, 25), advance_write_head(10, 15, 20, 65_536));
}

test "tcp: closed connection waits for active completions" {
    const Release = struct {
        var count: usize = 0;

        fn callback(_: *anyopaque, _: *TcpConnection) void {
            count += 1;
        }
    };

    var pool_token: u8 = 0;
    var conn = TcpConnection{
        .socket = undefined,
        .closing = true,
        .close_complete = true,
        .read_active = true,
        .is_writing = true,
        .pool_ptr = &pool_token,
        .on_close_cb = Release.callback,
    };

    Release.count = 0;
    release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.read_active = false;
    release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 0), Release.count);

    conn.is_writing = false;
    release_closed_connection(&conn);
    release_closed_connection(&conn);
    try std.testing.expectEqual(@as(usize, 1), Release.count);
}

test "tcp: server close drains an outstanding accept" {
    const Accept = struct {
        fn callback(socket: xev.TCP, _: ?*anyopaque) void {
            close_unregistered_socket(socket);
        }
    };

    var loop = try @import("loop.zig").init();
    defer @import("loop.zig").deinit(&loop);
    var server = try init_server("127.0.0.1", 0, Accept.callback, null);

    accept_start(&server, &loop);
    close_server(&server, &loop);
    try @import("loop.zig").run(&loop);
    try std.testing.expect(server.close_complete);
}
