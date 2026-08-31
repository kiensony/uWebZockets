const std = @import("std");
const parser = @import("http_parser");
const Request = parser.Request;
const zslay = @import("zslay");
const ws_handshake = @import("ws_handshake");
const quic_validation = @import("quic_validation");

test "fuzz: protocol parsers preserve bounded state" {
    try std.testing.fuzz({}, fuzz_protocol_parsers, .{
        .corpus = &.{
            "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ntest",
            "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n",
            "invalid",
            "\x81\x80\x01\x02\x03\x04",
            "\x89\x80\x01\x02\x03\x04",
            "\x88\x82\x01\x02\x03\x04\x02\xea",
            "\xff\xff\xff\xff",
        },
    });
}

fn fuzz_protocol_parsers(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    try fuzz_http_parser(smith);
    try fuzz_zslay_receive(smith);
    fuzz_extension_negotiation(smith);
    fuzz_http3_validation(smith);
}

fn fuzz_http3_validation(smith: *std.testing.Smith) void {
    var input: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input));
    const split = smith.index(input_len + 1);
    const first = input[0..split];
    const second = input[split..input_len];

    _ = quic_validation.valid_method(first);
    _ = quic_validation.valid_target(first);
    _ = quic_validation.valid_authority(first);
    _ = quic_validation.valid_http3_name(first);
    _ = quic_validation.valid_header_value(second);
    _ = quic_validation.connection_specific_header(first);
    _ = quic_validation.parse_decimal(second);
}

fn fuzz_extension_negotiation(smith: *std.testing.Smith) void {
    var input: [512]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, ';', 8),
        .value(u8, ',', 8),
        .value(u8, '=', 8),
        .value(u8, '"', 4),
    }));
    _ = ws_handshake.negotiate_permessage_deflate(input[0..input_len]);
}

fn fuzz_http_parser(smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '\r', 8),
        .value(u8, '\n', 8),
        .value(u8, ':', 4),
    }));
    const split = smith.index(input_len + 1);

    var p = parser.HttpParser{};
    var req = Request{};
    _ = parser.consume(&p, &req, input[0..split]);
    if (!parser_is_terminal(p.state)) {
        const consumed = parser.consume(&p, &req, input[0..input_len]);
        try std.testing.expect(consumed <= input_len);
    }

    try std.testing.expect(req.header_count <= req.header_names.len);
    try std.testing.expect(req.body.len <= parser.max_body_size);
}

fn parser_is_terminal(state: parser.ParserState) bool {
    return switch (state) {
        .done, .error_invalid, .error_headers_too_large, .error_too_large => true,
        else => false,
    };
}

fn fuzz_zslay_receive(smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var input: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input));
    var nodes: [4]zslay.Conn.FrameNode = undefined;
    var conn = zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = input.len,
        .max_message_len = input.len,
    }) catch return;

    var offset: usize = 0;
    var steps: usize = 0;
    while (steps < input_len * 3 + 32) : (steps += 1) {
        const action = conn.advance_rx() catch return;
        switch (action) {
            .need_header => {
                if (offset == input_len) return;
                const destination = conn.get_header_buffer();
                const copy_len = @min(destination.len, input_len - offset);
                @memcpy(destination[0..copy_len], input[offset .. offset + copy_len]);
                conn.advance_header_read(copy_len) catch return;
                offset += copy_len;
            },
            .need_payload => {
                if (offset == input_len) return;
                const decoded = conn.decoded_header orelse return;
                const remaining = decoded.extended_len - conn.payload_bytes_processed;
                const available: u64 = @intCast(input_len - offset);
                const copy_len = @min(remaining, available);
                conn.advance_payload_read(copy_len) catch return;
                offset += @intCast(copy_len);
            },
            .emit_frame => conn.complete_frame(),
            else => return,
        }
    }

    try std.testing.expect(steps < input_len * 3 + 32);
}
