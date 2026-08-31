const std = @import("std");

// globally unique identifier required by rfc 6455 for websocket upgrades.
const websocket_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const ValidationError = error{
    InvalidMethod,
    MissingConnectionUpgrade,
    MissingUpgradeWebSocket,
    MissingVersion,
    UnsupportedVersion,
    MissingKey,
    InvalidKey,
};

pub const PerMessageDeflate = struct {
    server_max_window_bits: ?u4 = null,
    client_max_window_bits: ?u4 = null,
};

pub fn has_token(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, expected)) return true;
    }
    return false;
}

pub fn validate_request(
    method: []const u8,
    connection: ?[]const u8,
    upgrade: ?[]const u8,
    version: ?[]const u8,
    key: ?[]const u8,
) ValidationError![]const u8 {
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidMethod;

    const connection_value = connection orelse return error.MissingConnectionUpgrade;
    if (!has_token(connection_value, "upgrade")) return error.MissingConnectionUpgrade;

    const upgrade_value = upgrade orelse return error.MissingUpgradeWebSocket;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_value, " \t"), "websocket")) {
        return error.MissingUpgradeWebSocket;
    }

    const version_value = version orelse return error.MissingVersion;
    if (!std.mem.eql(u8, std.mem.trim(u8, version_value, " \t"), "13")) {
        return error.UnsupportedVersion;
    }

    const client_key = key orelse return error.MissingKey;
    if (!valid_client_key(client_key)) return error.InvalidKey;
    return client_key;
}

pub fn valid_client_key(client_key: []const u8) bool {
    if (client_key.len != 24) return false;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(client_key) catch return false;
    if (decoded_len != 16) return false;

    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, client_key) catch return false;
    return true;
}

// computes the sec-websocket-accept token strictly on the stack.
// returns a slice pointing to the base64 encoded data inside out_buffer.
pub fn compute_accept_token(client_key: []const u8, out_buffer: *[28]u8) []const u8 {
    // concatenate client key and magic string in a fixed 64-byte stack buffer.
    var combined: [64]u8 = undefined;
    const total_len = client_key.len + websocket_magic.len;

    if (total_len > combined.len) return "";

    @memcpy(combined[0..client_key.len], client_key);
    @memcpy(combined[client_key.len..total_len], websocket_magic);

    // hash with sha-1
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined[0..total_len], &hash, .{});

    // base64 encoding of 20 bytes is exactly 28 bytes.
    return std.base64.standard.Encoder.encode(out_buffer, &hash);
}

// Selects the first compatible permessage-deflate offer. Invalid offers are
// ignored independently so one malformed alternative cannot poison another.
pub fn negotiate_permessage_deflate(value: []const u8) ?PerMessageDeflate {
    var offers = std.mem.splitScalar(u8, value, ',');
    while (offers.next()) |offer| {
        if (parse_permessage_deflate_offer(offer)) |negotiated| return negotiated;
    }
    return null;
}

pub fn format_permessage_deflate_response(
    negotiated: PerMessageDeflate,
    output: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);

    try writer.writeAll(
        "Sec-WebSocket-Extensions: permessage-deflate" ++
            "; server_no_context_takeover" ++
            "; client_no_context_takeover",
    );
    if (negotiated.server_max_window_bits) |bits| {
        try writer.print("; server_max_window_bits={d}", .{bits});
    }
    if (negotiated.client_max_window_bits) |bits| {
        try writer.print("; client_max_window_bits={d}", .{bits});
    }
    try writer.writeAll("\r\n");
    return writer.buffered();
}

fn parse_permessage_deflate_offer(offer: []const u8) ?PerMessageDeflate {
    var fields = std.mem.splitScalar(u8, offer, ';');
    const extension = std.mem.trim(u8, fields.next() orelse return null, " \t");
    if (!std.ascii.eqlIgnoreCase(extension, "permessage-deflate")) return null;

    var negotiated = PerMessageDeflate{};
    var saw_server_no_context = false;
    var saw_client_no_context = false;
    var saw_server_window = false;
    var saw_client_window = false;

    while (fields.next()) |field_value| {
        const field = std.mem.trim(u8, field_value, " \t");
        if (field.len == 0) return null;

        const equals = std.mem.indexOfScalar(u8, field, '=');
        const name = std.mem.trim(u8, field[0 .. equals orelse field.len], " \t");
        const raw_value = if (equals) |index|
            std.mem.trim(u8, field[index + 1 ..], " \t")
        else
            null;

        if (std.ascii.eqlIgnoreCase(name, "server_no_context_takeover")) {
            if (saw_server_no_context or raw_value != null) return null;
            saw_server_no_context = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "client_no_context_takeover")) {
            if (saw_client_no_context or raw_value != null) return null;
            saw_client_no_context = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "server_max_window_bits")) {
            if (saw_server_window) return null;
            saw_server_window = true;
            const bits = parse_window_bits(raw_value orelse return null) orelse return null;
            // zlib cannot represent an 8-bit compression window reliably;
            // accept every interoperable 9-15 bit window.
            if (bits == 8) return null;
            negotiated.server_max_window_bits = bits;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "client_max_window_bits")) {
            if (saw_client_window) return null;
            saw_client_window = true;
            negotiated.client_max_window_bits = if (raw_value) |candidate|
                parse_window_bits(candidate) orelse return null
            else
                15;
            continue;
        }
        return null;
    }

    return negotiated;
}

fn parse_window_bits(raw_value: []const u8) ?u4 {
    var value = raw_value;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    if (value.len == 0 or value.len > 2) return null;

    const parsed = std.fmt.parseInt(u8, value, 10) catch return null;
    if (parsed < 8 or parsed > 15) return null;
    return @intCast(parsed);
}

test "handshake: negotiates bounded no-context permessage-deflate" {
    const negotiated = negotiate_permessage_deflate(
        "foo, permessage-deflate; client_max_window_bits=12; server_max_window_bits=15",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(?u4, 15), negotiated.server_max_window_bits);
    try std.testing.expectEqual(@as(?u4, 12), negotiated.client_max_window_bits);

    var output: [192]u8 = undefined;
    const response = try format_permessage_deflate_response(negotiated, &output);
    try std.testing.expectEqualStrings(
        "Sec-WebSocket-Extensions: permessage-deflate" ++
            "; server_no_context_takeover" ++
            "; client_no_context_takeover" ++
            "; server_max_window_bits=15" ++
            "; client_max_window_bits=12\r\n",
        response,
    );
}

test "handshake: ignores malformed permessage-deflate offers" {
    try std.testing.expectEqual(
        null,
        negotiate_permessage_deflate("permessage-deflate; client_max_window_bits=7"),
    );
    try std.testing.expectEqual(
        null,
        negotiate_permessage_deflate(
            "permessage-deflate; client_no_context_takeover; client_no_context_takeover",
        ),
    );
    try std.testing.expectEqual(
        null,
        negotiate_permessage_deflate("permessage-deflate; unknown=value"),
    );
}

test "handshake: later compatible extension offer remains usable" {
    const negotiated = negotiate_permessage_deflate(
        "permessage-deflate; server_max_window_bits=8, permessage-deflate",
    );
    try std.testing.expect(negotiated != null);
}
