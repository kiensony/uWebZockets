const std = @import("std");
const parser = @import("../http/parser.zig");
const Request = @import("../http/request.zig").Request;

// tests the zero-allocation http parser state machine
test "http: parse basic get request" {
    var p = parser.HttpParser{};
    var req = Request{};

    var request_data = "GET /index.html HTTP/1.1\r\nHost: localhost\r\nUser-Agent: curl\r\n\r\n".*;

    const consumed = parser.consume(&p, &req, &request_data);

    try std.testing.expectEqual(request_data.len, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/index.html", req.path);
    try std.testing.expectEqual(@as(usize, 2), req.header_count);

    try std.testing.expectEqualStrings("localhost", req.get_header("Host").?);
    try std.testing.expectEqualStrings("curl", req.get_header("User-Agent").?);
}

test "http: preserves parser state across split input" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET /split HTTP/1.1\r\nHost: example.test\r\n\r\n".*;
    const split = 19;

    _ = parser.consume(&p, &req, data[0..split]);
    try std.testing.expect(p.state != .done);

    const consumed = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(data.len, consumed);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/split", req.path);
}

test "http: separates a query from the routed path" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET /search?q=zig%20websocket HTTP/1.1\r\nHost: example.test\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/search?q=zig%20websocket", req.target);
    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("q=zig%20websocket", req.query);
}

test "http: reports first request boundary for pipelining" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = ("GET /one HTTP/1.1\r\nHost: example.test\r\n\r\n" ++
        "GET /two HTTP/1.1\r\nHost: example.test\r\n\r\n").*;
    const first_len = std.mem.indexOf(u8, &data, "GET /two").?;

    const consumed = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(first_len, consumed);
    try std.testing.expectEqualStrings("/one", req.path);

    std.mem.copyForwards(u8, data[0 .. data.len - consumed], data[consumed..]);
    parser.reset(&p);
    req = .{};
    _ = parser.consume(&p, &req, data[0 .. data.len - consumed]);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("/two", req.path);
}

test "http: rejects unsupported transfer codings" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: bounds declared request bodies" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 16385\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_too_large, p.state);
}

test "http: accepts only decimal content lengths" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: +1\r\n\r\nx".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: rejects empty header names" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "GET / HTTP/1.1\r\nHost: example.test\r\n: invalid\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: accepts only hexadecimal chunk sizes" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.error_invalid, p.state);
}

test "http: decodes bounded chunked bodies" {
    var p = parser.HttpParser{};
    var req = Request{};
    var data = "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n".*;

    _ = parser.consume(&p, &req, &data);
    try std.testing.expectEqual(parser.ParserState.done, p.state);
    try std.testing.expectEqualStrings("test", req.body);
}
