const std = @import("std");
const tcp = @import("../core/tcp.zig");
const TcpConnection = tcp.TcpConnection;

pub const Http3Target = struct {
    context: *anyopaque,
    end_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    begin_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,
};

pub const ConnectionTarget = union(enum) {
    tcp: *TcpConnection,
    http3: Http3Target,
};

pub const ResponseState = enum(u8) {
    idle,
    streaming,
    ended,
};

pub const Response = struct {
    target: ConnectionTarget,
    state: ResponseState = .idle,
    close_after_end: bool = false,

    pub fn end(self: *Response, status: []const u8, body: []const u8) !void {
        return self.end_with_headers(status, "", body);
    }

    pub fn end_with_headers(
        self: *Response,
        status: []const u8,
        headers: []const u8,
        body: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code) and body.len != 0) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                const close_requested = headers_have_token(headers, "Connection", "close");
                var header_buffer: [1024]u8 = undefined;
                const formatted_headers = if (status_forbids_body(code))
                    std.fmt.bufPrint(
                        &header_buffer,
                        "HTTP/1.1 {s}\r\n{s}\r\n",
                        .{ status, headers },
                    ) catch return error.BufferOverflow
                else
                    std.fmt.bufPrint(
                        &header_buffer,
                        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n",
                        .{ status, body.len, headers },
                    ) catch return error.BufferOverflow;

                if (conn.suppress_response_body or status_forbids_body(code)) {
                    try conn.write_data(formatted_headers);
                } else {
                    try conn.write_data_parts(&.{ formatted_headers, body });
                }
                if (close_requested) tcp.close_after_flush(conn);
            },
            .http3 => |target| {
                try target.end_fn(target.context, status, headers, body);
            },
        }
        self.state = .ended;
    }

    pub fn begin_chunked(
        self: *Response,
        status: []const u8,
        headers: []const u8,
    ) !void {
        if (self.state != .idle) return error.ResponseAlreadyStarted;
        const code = status_code(status) orelse return error.InvalidStatus;
        if (!valid_headers(headers)) return error.InvalidHeaders;
        if (status_forbids_body(code)) return error.BodyNotAllowed;

        switch (self.target) {
            .tcp => |conn| {
                self.close_after_end = headers_have_token(headers, "Connection", "close");
                if (conn.suppress_response_body) return error.BodyNotAllowed;

                var header_buffer: [1024]u8 = undefined;
                const formatted_headers = std.fmt.bufPrint(
                    &header_buffer,
                    "HTTP/1.1 {s}\r\nTransfer-Encoding: chunked\r\n{s}\r\n",
                    .{ status, headers },
                ) catch return error.BufferOverflow;
                try conn.write_data(formatted_headers);
            },
            .http3 => |target| {
                try target.begin_fn(target.context, status, headers);
            },
        }
        self.state = .streaming;
    }

    pub fn write_chunk(self: *Response, chunk: []const u8) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| try @import("chunked.zig").send_chunk(conn, chunk),
            .http3 => |target| try target.write_fn(target.context, chunk),
        }
    }

    pub fn end_chunks(self: *Response) !void {
        if (self.state != .streaming) return error.ResponseNotStreaming;

        switch (self.target) {
            .tcp => |conn| {
                try @import("chunked.zig").end(conn);
                if (self.close_after_end) tcp.close_after_flush(conn);
            },
            .http3 => |target| try target.finish_fn(target.context),
        }
        self.state = .ended;
    }

    pub fn is_complete(self: *const Response) bool {
        return self.state == .ended;
    }

    pub fn is_started(self: *const Response) bool {
        return self.state != .idle;
    }
};

fn status_code(status: []const u8) ?u16 {
    if (status.len < 3) return null;
    for (status[0..3]) |c| {
        if (c < '0' or c > '9') return null;
    }
    if (status.len > 3 and status[3] != ' ') return null;

    if (status.len > 4) {
        for (status[4..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return null;
        }
    }

    const code = std.fmt.parseInt(u16, status[0..3], 10) catch return null;
    if (code < 200 or code > 599) return null;
    return code;
}

fn status_forbids_body(code: u16) bool {
    return code == 204 or code == 304;
}

fn valid_headers(headers: []const u8) bool {
    if (headers.len == 0) return true;
    if (!std.mem.endsWith(u8, headers, "\r\n")) return false;

    var lines = std.mem.splitSequence(u8, headers[0 .. headers.len - 2], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return false;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const name = line[0..colon];
        if (name.len == 0) return false;

        for (name) |c| {
            if (!is_tchar(c)) return false;
        }
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) return false;
        if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return false;

        for (line[colon + 1 ..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
        }
    }
    return true;
}

fn headers_have_token(headers: []const u8, name: []const u8, token: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var values = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (values.next()) |value| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token)) return true;
        }
    }
    return false;
}

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

test "http: response metadata rejects framing ambiguity" {
    try std.testing.expectEqual(@as(?u16, 200), status_code("200 OK"));
    try std.testing.expect(status_code("099 Invalid") == null);
    try std.testing.expect(status_code("600 Invalid") == null);
    try std.testing.expect(status_code("200 OK\r\nX-Test: injected") == null);
    try std.testing.expect(status_forbids_body(204));
    try std.testing.expect(status_forbids_body(304));
    try std.testing.expect(valid_headers("Content-Type: text/plain\r\nConnection: close\r\n"));
    try std.testing.expect(!valid_headers("Content-Length: 1\r\n"));
    try std.testing.expect(!valid_headers("Transfer-Encoding: chunked\r\n"));
    try std.testing.expect(!valid_headers("X-Test: valid\r\n\r\nInjected: value\r\n"));
    try std.testing.expect(headers_have_token("Connection: keep-alive, close\r\n", "Connection", "close"));
}
