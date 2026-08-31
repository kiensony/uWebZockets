const std = @import("std");
const handshake = @import("../ws/handshake.zig");
const PubSubEngine = @import("../ws/pubsub.zig").PubSubEngine;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const TcpConnection = @import("../core/tcp.zig").TcpConnection;
const mask = @import("../ws/mask.zig");
const utf8 = @import("../ws/utf8.zig");
const zslay = @import("zslay");

// tests websocket accept token computation based on rfc 6455
test "ws: compute_accept_token" {
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    var out_buffer: [28]u8 = undefined;

    const accept_token = handshake.compute_accept_token(client_key, &out_buffer);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_token);
}

test "ws: validates the complete upgrade handshake" {
    const key = try handshake.validate_request(
        "GET",
        "keep-alive, Upgrade",
        "websocket",
        "13",
        "dGhlIHNhbXBsZSBub25jZQ==",
    );
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key);

    try std.testing.expectError(
        error.InvalidKey,
        handshake.validate_request("GET", "Upgrade", "websocket", "13", "not-base64"),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        handshake.validate_request("GET", "Upgrade", "websocket", "12", "dGhlIHNhbXBsZSBub25jZQ=="),
    );
}

test "ws: zslay server rejects unmasked client frames" {
    var nodes: [2]zslay.Conn.FrameNode = undefined;
    var conn = try zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = 1024,
        .max_message_len = 1024,
    });
    var header: [14]u8 = undefined;
    const header_len = try zslay.encode_header(&header, .{
        .payload_len = 0,
        .mask = false,
        .opcode = @intFromEnum(zslay.Opcode.text),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
    }, 0, null);

    @memcpy(conn.get_header_buffer(), header[0..header_len]);
    try conn.advance_header_read(header_len);
    try std.testing.expectError(error.PayloadNotMasked, conn.advance_rx());
}

test "ws: zslay enforces frame limits from extended headers" {
    var nodes: [2]zslay.Conn.FrameNode = undefined;
    var conn = try zslay.Conn.init(&nodes, .{
        .role = .server,
        .max_frame_len = 1024,
        .max_message_len = 1024,
    });
    var header: [14]u8 = undefined;
    const masking_key = [_]u8{ 1, 2, 3, 4 };
    const header_len = try zslay.encode_header(&header, .{
        .payload_len = 126,
        .mask = true,
        .opcode = @intFromEnum(zslay.Opcode.binary),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
    }, 2048, masking_key);

    var offset: usize = 0;
    while (offset < header_len) {
        try std.testing.expectEqual(zslay.RxAction.need_header, try conn.advance_rx());
        const destination = conn.get_header_buffer();
        const copy_len = @min(destination.len, header_len - offset);
        @memcpy(destination[0..copy_len], header[offset .. offset + copy_len]);
        try conn.advance_header_read(copy_len);
        offset += copy_len;
    }
    try std.testing.expectError(error.PayloadTooLarge, conn.advance_rx());
}

test "ws: SIMD mask is position-aware and reversible" {
    const key = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    var payload = "0123456789abcdefghijklmnopqrstuvwxyz".*;
    const original = payload;

    mask.apply(&payload, key, 0);
    try std.testing.expect(!std.mem.eql(u8, &payload, &original));
    mask.apply(&payload, key, 0);
    try std.testing.expectEqualSlices(u8, &original, &payload);
}

test "ws: SIMD mask preserves key position across chunks" {
    const key = [_]u8{ 1, 2, 3, 4 };
    var whole = "0123456789abcdefghijklmnop".*;
    var split = whole;

    mask.apply(&whole, key, 0);
    mask.apply(split[0..7], key, 0);
    mask.apply(split[7..], key, 7);
    try std.testing.expectEqualSlices(u8, &whole, &split);
}

test "ws: streaming UTF-8 validation fails at the offending byte" {
    var state = utf8.validate_chunk(.{}, &.{ 0xf0, 0x90 }) orelse unreachable;
    try std.testing.expect(!utf8.is_complete(state));
    state = utf8.validate_chunk(state, &.{ 0x80, 0x80 }) orelse unreachable;
    try std.testing.expect(utf8.is_complete(state));

    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xf4, 0x90 }) == null);
    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xed, 0xa0, 0x80 }) == null);
    try std.testing.expect(utf8.validate_chunk(.{}, &.{ 0xc0, 0x80 }) == null);
}

test "ws: pubsub owns topics and reclaims subscriptions" {
    var engine = PubSubEngine{};
    var first_socket: WebSocket = undefined;
    var second_socket: WebSocket = undefined;
    var topic = "room".*;

    try engine.subscribe(&first_socket, &topic);
    try engine.subscribe(&first_socket, &topic);
    try engine.subscribe(&second_socket, &topic);
    try std.testing.expectEqual(@as(usize, 2), engine.sub_count);

    topic[0] = 'x';
    try std.testing.expect(engine.unsubscribe(&first_socket, "room"));
    engine.unsubscribe_all(&second_socket);
    try std.testing.expectEqual(@as(usize, 0), engine.sub_count);
    try std.testing.expectEqual(@as(usize, 0), engine.topic_count);
}

test "ws: full subscription storage does not leak empty topics" {
    var engine = PubSubEngine{};
    var socket: WebSocket = undefined;
    engine.sub_count = @import("../ws/pubsub.zig").max_subscriptions;

    try std.testing.expectError(
        error.SubscriptionCapacityReached,
        engine.subscribe(&socket, "unused"),
    );
    try std.testing.expectEqual(@as(usize, 0), engine.topic_count);
}

test "ws: fragmented message completes with an empty continuation" {
    const Capture = struct {
        var calls: usize = 0;
        var message_len: usize = 0;
        var opcode: zslay.Opcode = .continuation;

        fn on_message(_: *WebSocket, message: []const u8, message_opcode: zslay.Opcode) void {
            calls += 1;
            message_len = message.len;
            opcode = message_opcode;
        }
    };

    const message_size = 4 * 1024 * 1024;
    const fragment_size = 1024;
    const masking_key = [_]u8{ 1, 2, 3, 4 };
    const message_buffer = try std.testing.allocator.alloc(u8, message_size);
    defer std.testing.allocator.free(message_buffer);

    var tcp_conn = TcpConnection{
        .socket = undefined,
        .ws_message_buffer = message_buffer,
    };
    var ws = WebSocket{
        .conn = &tcp_conn,
        .behavior = .{
            .message = Capture.on_message,
            .max_frame_size = message_size,
            .max_message_size = message_size,
        },
        .initialized = true,
    };
    ws.z_conn = try zslay.Conn.init(&ws.tx_nodes, .{
        .role = .server,
        .max_frame_len = message_size,
        .max_message_len = message_size,
    });

    var wire: [14 + fragment_size]u8 = undefined;
    for (0..message_size / fragment_size) |fragment_index| {
        const opcode: zslay.Opcode = if (fragment_index == 0) .text else .continuation;
        const header_len = try zslay.encode_header(
            &wire,
            .{
                .payload_len = 126,
                .mask = true,
                .opcode = @intFromEnum(opcode),
                .rsv3 = false,
                .rsv2 = false,
                .rsv1 = false,
                .fin = false,
            },
            fragment_size,
            masking_key,
        );
        @memset(wire[header_len .. header_len + fragment_size], '*');
        mask.apply(wire[header_len .. header_len + fragment_size], masking_key, 0);
        ws.on_data(wire[0 .. header_len + fragment_size]);
    }

    const final_header_len = try zslay.encode_header(
        &wire,
        .{
            .payload_len = 0,
            .mask = true,
            .opcode = @intFromEnum(zslay.Opcode.continuation),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = true,
        },
        0,
        masking_key,
    );
    ws.on_data(wire[0..final_header_len]);

    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    try std.testing.expectEqual(message_size, Capture.message_len);
    try std.testing.expectEqual(zslay.Opcode.text, Capture.opcode);
}
