const std = @import("std");
pub const Request = @import("request.zig").Request;

// finite states of our zero-allocation http parser.
pub const ParserState = enum {
    method,
    path,
    protocol,
    headers,
    body,
    chunk_size,
    chunk_ext,
    chunk_data,
    chunk_crlf,
    chunk_trailer,
    done,
    error_invalid,
    error_headers_too_large,
    error_too_large,
};

pub const max_request_line_size = 8 * 1024;
pub const max_header_size = 16 * 1024;
pub const max_body_size = 16 * 1024;

fn is_tchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn is_decimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn is_hexadecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

// http parser state data.
pub const HttpParser = struct {
    state: ParserState = .method,
    mark: usize = 0,
    content_length: usize = 0,
    chunk_length: usize = 0,
    body_length: usize = 0,
    body_start: usize = 0,
};

// consumes a chunk of bytes, maps them onto the request.
// returns the number of bytes consumed.
pub fn consume(parser: *HttpParser, req: *Request, buffer: []u8) usize {
    var i: usize = parser.mark;

    while (i < buffer.len) {
        switch (parser.state) {
            .method => {
                if (std.mem.indexOfScalar(u8, buffer[i..], ' ')) |space_idx| {
                    const abs_space = i + space_idx;
                    if (abs_space > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    if (abs_space == parser.mark) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    for (buffer[parser.mark..abs_space]) |c| {
                        if (!is_tchar(c)) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    req.method = buffer[parser.mark..abs_space];
                    parser.mark = abs_space + 1;
                    parser.state = .path;
                    i = abs_space + 1;
                } else {
                    if (std.mem.indexOfAny(u8, buffer[i..], "\r\n")) |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    if (buffer.len > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                    }
                    return buffer.len; // need more data
                }
            },
            .path => {
                if (std.mem.indexOfScalar(u8, buffer[i..], ' ')) |space_idx| {
                    const abs_space = i + space_idx;
                    const path = buffer[parser.mark..abs_space];
                    if (abs_space > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, '#') != null) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    for (path) |c| {
                        if (c < 32 or c == 127) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    req.target = path;
                    if (std.mem.indexOfScalar(u8, path, '?')) |query_start| {
                        req.path = path[0..query_start];
                        req.query = path[query_start + 1 ..];
                    } else {
                        req.path = path;
                        req.query = "";
                    }
                    parser.mark = abs_space + 1;
                    parser.state = .protocol;
                    i = abs_space + 1;
                } else {
                    if (std.mem.indexOfAny(u8, buffer[i..], "\r\n")) |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    if (buffer.len > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                    }
                    return buffer.len;
                }
            },
            .protocol => {
                if (std.mem.indexOfScalar(u8, buffer[i..], '\n')) |nl_idx| {
                    const abs_nl = i + nl_idx;
                    if (abs_nl + 1 > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }
                    if (abs_nl > parser.mark and buffer[abs_nl - 1] == '\r') {
                        const proto = buffer[parser.mark .. abs_nl - 1];
                        if (!std.mem.eql(u8, proto, "HTTP/1.1")) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        parser.mark = abs_nl + 1;
                        parser.state = .headers;
                        i = abs_nl + 1;
                    } else {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                } else {
                    if (buffer.len > max_request_line_size) {
                        parser.state = .error_headers_too_large;
                    }
                    return buffer.len;
                }
            },
            .headers => {
                const headers_end = std.mem.indexOfPos(u8, buffer, parser.mark, "\r\n\r\n");
                if (headers_end) |end| {
                    if (end - parser.mark > max_header_size) {
                        parser.state = .error_headers_too_large;
                        return buffer.len;
                    }

                    var lines = std.mem.splitSequence(u8, buffer[parser.mark..end], "\r\n");
                    var has_host = false;
                    var has_cl = false;
                    var has_te = false;

                    while (lines.next()) |line| {
                        if (line.len == 0) continue;
                        if (std.mem.indexOf(u8, line, ":")) |colon| {
                            const name = line[0..colon];
                            if (name.len == 0) {
                                parser.state = .error_invalid;
                                return buffer.len;
                            }
                            for (name) |c| {
                                if (!is_tchar(c)) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            var val_start = colon + 1;
                            while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) {
                                val_start += 1;
                            }

                            var val_end = line.len;
                            while (val_end > val_start and (line[val_end - 1] == ' ' or line[val_end - 1] == '\t')) {
                                val_end -= 1;
                            }

                            const value = line[val_start..val_end];

                            for (value) |c| {
                                if ((c < 32 and c != '\t') or c == 127) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Host")) {
                                if (has_host or value.len == 0) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_host = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                                if (has_te or !std.ascii.eqlIgnoreCase(value, "chunked")) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_te = true;
                            }

                            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                                if (has_cl) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                has_cl = true;
                                if (!is_decimal(value)) {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                if (std.fmt.parseInt(usize, value, 10)) |len| {
                                    if (len > max_body_size) {
                                        parser.state = .error_too_large;
                                        return buffer.len;
                                    }
                                    parser.content_length = len;
                                } else |_| {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                            }

                            if (req.header_count >= req.header_names.len) {
                                parser.state = .error_headers_too_large;
                                return buffer.len;
                            }
                            req.header_names[req.header_count] = name;
                            req.header_values[req.header_count] = value;
                            req.header_count += 1;
                        } else {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }

                    if (!has_host) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    if (has_te and has_cl) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }

                    if (has_te) {
                        parser.state = .chunk_size;
                        parser.mark = end + 4;
                        parser.body_start = end + 4;
                        parser.body_length = 0;
                        i = parser.mark;
                        continue;
                    }

                    if (parser.content_length > 0) {
                        parser.state = .body;
                        parser.mark = end + 4;
                        i = parser.mark;
                        continue;
                    }

                    parser.state = .done;
                    return end + 4;
                } else {
                    if (buffer.len - parser.mark > max_header_size) {
                        parser.state = .error_headers_too_large;
                    }
                    return buffer.len;
                }
            },
            .body => {
                const remaining = buffer.len - parser.mark;
                if (remaining >= parser.content_length) {
                    req.body = buffer[parser.mark .. parser.mark + parser.content_length];
                    parser.state = .done;
                    return parser.mark + parser.content_length;
                } else {
                    return buffer.len;
                }
            },
            .chunk_size => {
                if (std.mem.indexOfAny(u8, buffer[parser.mark..], "\r;")) |offset| {
                    const end_idx = parser.mark + offset;
                    const hex_str = buffer[parser.mark..end_idx];
                    if (!is_hexadecimal(hex_str)) {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    if (std.fmt.parseInt(usize, hex_str, 16)) |len| {
                        if (parser.body_length > max_body_size or len > max_body_size - parser.body_length) {
                            parser.state = .error_too_large;
                            return buffer.len;
                        }
                        parser.chunk_length = len;
                        if (buffer[end_idx] == ';') {
                            parser.state = .chunk_ext;
                            parser.mark = end_idx + 1;
                        } else {
                            if (end_idx + 1 < buffer.len) {
                                if (buffer[end_idx + 1] != '\n') {
                                    parser.state = .error_invalid;
                                    return buffer.len;
                                }
                                if (len == 0) {
                                    parser.state = .chunk_trailer;
                                } else {
                                    parser.state = .chunk_data;
                                }
                                parser.mark = end_idx + 2;
                            } else {
                                return buffer.len; // need more data
                            }
                        }
                        i = parser.mark;
                        continue;
                    } else |_| {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                }
                return buffer.len;
            },
            .chunk_ext => {
                if (std.mem.indexOfScalar(u8, buffer[parser.mark..], '\r')) |offset| {
                    const end_idx = parser.mark + offset;
                    for (buffer[parser.mark..end_idx]) |c| {
                        if ((c < 32 and c != '\t') or c == 127) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                    }
                    if (end_idx + 1 < buffer.len) {
                        if (buffer[end_idx + 1] != '\n') {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        if (parser.chunk_length == 0) {
                            parser.state = .chunk_trailer;
                        } else {
                            parser.state = .chunk_data;
                        }
                        parser.mark = end_idx + 2;
                        i = parser.mark;
                        continue;
                    } else {
                        return buffer.len;
                    }
                }
                return buffer.len;
            },
            .chunk_data => {
                const available = buffer.len - parser.mark;
                if (available >= parser.chunk_length) {
                    const src = buffer[parser.mark .. parser.mark + parser.chunk_length];
                    const dst = buffer[parser.body_start + parser.body_length .. parser.body_start + parser.body_length + parser.chunk_length];
                    std.mem.copyForwards(u8, dst, src);
                    parser.body_length += parser.chunk_length;
                    parser.mark += parser.chunk_length;
                    parser.state = .chunk_crlf;
                    i = parser.mark;
                    continue;
                }
                return buffer.len;
            },
            .chunk_crlf => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] != '\r' or buffer[parser.mark + 1] != '\n') {
                        parser.state = .error_invalid;
                        return buffer.len;
                    }
                    parser.mark += 2;
                    parser.state = .chunk_size;
                    i = parser.mark;
                    continue;
                }
                return buffer.len;
            },
            .chunk_trailer => {
                if (buffer.len - parser.mark >= 2) {
                    if (buffer[parser.mark] == '\r' and buffer[parser.mark + 1] == '\n') {
                        req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                        parser.state = .done;
                        return parser.mark + 2;
                    }
                    if (std.mem.indexOfPos(u8, buffer, parser.mark, "\r\n\r\n")) |end_idx| {
                        if (!valid_trailers(buffer[parser.mark..end_idx])) {
                            parser.state = .error_invalid;
                            return buffer.len;
                        }
                        req.body = buffer[parser.body_start .. parser.body_start + parser.body_length];
                        parser.state = .done;
                        return end_idx + 4;
                    }
                }
                return buffer.len;
            },
            .done, .error_invalid, .error_headers_too_large, .error_too_large => return i,
        }
    }

    return i;
}

fn valid_trailers(trailers: []const u8) bool {
    if (trailers.len > max_header_size) return false;

    var field_count: usize = 0;
    var lines = std.mem.splitSequence(u8, trailers, "\r\n");
    while (lines.next()) |line| {
        field_count += 1;
        if (field_count > 64) return false;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const name = line[0..colon];
        if (name.len == 0) return false;
        for (name) |c| {
            if (!is_tchar(c)) return false;
        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Length") or
            std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(name, "Host"))
        {
            return false;
        }

        for (line[colon + 1 ..]) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
        }
    }
    return true;
}

// resets the state for the next request.
pub fn reset(parser: *HttpParser) void {
    parser.state = .method;
    parser.mark = 0;
    parser.content_length = 0;
    parser.chunk_length = 0;
    parser.body_length = 0;
    parser.body_start = 0;
}
