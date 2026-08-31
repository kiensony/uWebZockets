const std = @import("std");

// incoming HTTP/1.1 request, zero-allocation.
pub const Request = struct {
    method: []const u8 = "",
    target: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    body: []const u8 = "",

    header_names: [64][]const u8 = undefined,
    header_values: [64][]const u8 = undefined,
    header_count: usize = 0,

    // retrieves a header value by name.
    pub fn get_header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.header_names[0..self.header_count], 0..) |h_name, i| {
            if (std.ascii.eqlIgnoreCase(h_name, name)) return self.header_values[i];
        }
        return null;
    }

    pub fn get_unique_header(self: *const Request, name: []const u8) ?[]const u8 {
        var value: ?[]const u8 = null;

        for (self.header_names[0..self.header_count], self.header_values[0..self.header_count]) |header_name, header_value| {
            if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
            if (value != null) return null;
            value = header_value;
        }
        return value;
    }

    pub fn count_headers(self: *const Request, name: []const u8) usize {
        var count: usize = 0;
        for (self.header_names[0..self.header_count]) |header_name| {
            if (std.ascii.eqlIgnoreCase(header_name, name)) count += 1;
        }
        return count;
    }

    pub fn header_has_token(self: *const Request, name: []const u8, token: []const u8) bool {
        for (self.header_names[0..self.header_count], self.header_values[0..self.header_count]) |header_name, value| {
            if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;

            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |candidate| {
                const trimmed = std.mem.trim(u8, candidate, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
            }
        }
        return false;
    }
};
