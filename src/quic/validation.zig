const std = @import("std");

pub fn valid_method(method: []const u8) bool {
    if (method.len == 0) return false;
    for (method) |byte| {
        if (!is_tchar(byte)) return false;
    }
    return true;
}

pub fn valid_target(target: []const u8) bool {
    if (std.mem.eql(u8, target, "*")) return true;
    if (target.len == 0 or target[0] != '/') return false;

    var index: usize = 0;
    while (index < target.len) : (index += 1) {
        const byte = target[index];
        if (byte == '%') {
            if (!valid_percent_escape(target, &index)) return false;
            continue;
        }
        if (byte == '/' or byte == '?' or is_pchar(byte)) continue;
        return false;
    }
    return true;
}

pub fn valid_authority(authority: []const u8) bool {
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;

    if (authority[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (closing == 1 or !valid_ip_literal(authority[1..closing])) return false;
        return valid_port_suffix(authority[closing + 1 ..]);
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host_end = colon orelse authority.len;
    if (host_end == 0) return false;
    if (colon != null and std.mem.indexOfScalarPos(u8, authority, host_end + 1, ':') != null) {
        return false;
    }
    if (!valid_reg_name(authority[0..host_end])) return false;
    return if (colon) |offset| valid_port(authority[offset + 1 ..]) else true;
}

pub fn valid_http3_name(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!is_tchar(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

pub fn valid_header_value(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 32 and byte != '\t') or byte == 127) return false;
    }
    return true;
}

pub fn connection_specific_header(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}

pub fn parse_decimal(value: []const u8) ?usize {
    if (value.len == 0) return null;

    var result: usize = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, byte - '0') catch return null;
    }
    return result;
}

fn is_tchar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn valid_reg_name(host: []const u8) bool {
    var index: usize = 0;
    while (index < host.len) : (index += 1) {
        const byte = host[index];
        if (byte == '%') {
            if (!valid_percent_escape(host, &index)) return false;
            continue;
        }
        if (!is_unreserved(byte) and !is_sub_delim(byte)) return false;
    }
    return true;
}

fn valid_ip_literal(host: []const u8) bool {
    var index: usize = 0;
    while (index < host.len) : (index += 1) {
        const byte = host[index];
        if (byte == '%') {
            if (!valid_percent_escape(host, &index)) return false;
            continue;
        }
        if (!is_unreserved(byte) and !is_sub_delim(byte) and byte != ':') return false;
    }
    return true;
}

fn valid_port_suffix(suffix: []const u8) bool {
    if (suffix.len == 0) return true;
    if (suffix[0] != ':') return false;
    return valid_port(suffix[1..]);
}

fn valid_port(port: []const u8) bool {
    if (port.len == 0) return false;
    for (port) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn valid_percent_escape(value: []const u8, index: *usize) bool {
    if (value.len - index.* < 3) return false;
    if (!std.ascii.isHex(value[index.* + 1]) or !std.ascii.isHex(value[index.* + 2])) {
        return false;
    }
    index.* += 2;
    return true;
}

fn is_pchar(byte: u8) bool {
    return is_unreserved(byte) or is_sub_delim(byte) or byte == ':' or byte == '@';
}

fn is_unreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn is_sub_delim(byte: u8) bool {
    return switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

test "quic: pure header validation rejects malformed metadata" {
    try std.testing.expect(valid_method("PATCH"));
    try std.testing.expect(!valid_method("BAD METHOD"));
    try std.testing.expect(valid_target("/path?value=1"));
    try std.testing.expect(!valid_target("/path#fragment"));
    try std.testing.expect(!valid_target("/bad path"));
    try std.testing.expect(!valid_target("/bad%2"));
    try std.testing.expect(valid_target("*"));
    try std.testing.expect(valid_authority("example.com:443"));
    try std.testing.expect(valid_authority("[::1]:443"));
    try std.testing.expect(!valid_authority("user@example.com"));
    try std.testing.expect(!valid_authority("example.com/path"));
    try std.testing.expect(valid_http3_name("content-type"));
    try std.testing.expect(!valid_http3_name("Content-Type"));
    try std.testing.expect(!valid_header_value("value\r\ninjected"));
    try std.testing.expect(connection_specific_header("Connection"));
    try std.testing.expectEqual(@as(?usize, 4096), parse_decimal("4096"));
    try std.testing.expect(parse_decimal("184467440737095516160") == null);
}
