const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const WebSocket = @import("../ws/socket.zig").WebSocket;
const zslay = @import("zslay");

pub const Handler = *const fn (req: *Request, res: *Response) void;

pub const WsCompression = enum(u8) {
    disabled,
    permessage_deflate,
};

pub const WsBehavior = struct {
    upgrade: ?*const fn (req: *const Request) bool = null,
    open: ?*const fn (ws: *WebSocket) void = null,
    message: ?*const fn (ws: *WebSocket, message: []const u8, opcode: zslay.Opcode) void = null,
    drain: ?*const fn (ws: *WebSocket) void = null,
    close: ?*const fn (ws: *WebSocket) void = null,
    compression: WsCompression = .disabled,
    max_frame_size: u64 = 16 * 1024,
    max_message_size: u64 = 16 * 1024,
};

pub fn valid_ws_limits(behavior: WsBehavior, message_capacity: usize) bool {
    if (behavior.max_frame_size == 0 or behavior.max_message_size == 0) return false;
    if (behavior.max_frame_size > behavior.max_message_size) return false;
    return behavior.max_message_size <= @as(u64, @intCast(message_capacity));
}

pub const HttpMethod = enum(u8) {
    get,
    head,
    post,
    put,
    delete,
    patch,
    options,
    any,

    pub fn parse(value: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, value, "GET")) return .get;
        if (std.mem.eql(u8, value, "HEAD")) return .head;
        if (std.mem.eql(u8, value, "POST")) return .post;
        if (std.mem.eql(u8, value, "PUT")) return .put;
        if (std.mem.eql(u8, value, "DELETE")) return .delete;
        if (std.mem.eql(u8, value, "PATCH")) return .patch;
        if (std.mem.eql(u8, value, "OPTIONS")) return .options;
        return null;
    }

    pub fn name(method: HttpMethod) []const u8 {
        return switch (method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
            .options => "OPTIONS",
            .any => "",
        };
    }
};

const method_count = @typeInfo(HttpMethod).@"enum".fields.len;
const concrete_methods = [_]HttpMethod{ .get, .head, .post, .put, .delete, .patch, .options };
const all_method_mask: u16 = (@as(u16, 1) << concrete_methods.len) - 1;

pub const RouteMatch = struct {
    path: []const u8,
    http_handler: ?Handler,
    ws_behavior: ?WsBehavior,
    allowed_methods: u16,
    has_http: bool,
};

const max_nodes = 256;
const max_route_path_size = 2048;
const null_node: u16 = std.math.maxInt(u16);
const empty_handlers = [_]?Handler{null} ** method_count;

pub const Router = struct {
    segments: [max_nodes][]const u8 = undefined,
    first_child: [max_nodes]u16 = .{null_node} ** max_nodes,
    next_sibling: [max_nodes]u16 = .{null_node} ** max_nodes,
    has_route: [max_nodes]bool = .{false} ** max_nodes,
    http_handlers: [max_nodes][method_count]?Handler = .{empty_handlers} ** max_nodes,
    ws_behaviors: [max_nodes]?WsBehavior = .{null} ** max_nodes,

    node_count: u16 = 0,
    root_idx: u16 = null_node,

    pub fn init() Router {
        var router = Router{};
        router.root_idx = 0;
        router.node_count = 1;
        router.segments[0] = "";
        router.first_child[0] = null_node;
        router.next_sibling[0] = null_node;
        router.has_route[0] = false;
        router.http_handlers[0] = empty_handlers;
        router.ws_behaviors[0] = null;
        return router;
    }

    fn alloc_node(self: *Router, segment: []const u8) !u16 {
        if (self.node_count >= max_nodes) return error.RouteCapacityReached;

        const index = self.node_count;
        self.node_count += 1;
        self.segments[index] = segment;
        self.first_child[index] = null_node;
        self.next_sibling[index] = null_node;
        self.has_route[index] = false;
        self.http_handlers[index] = empty_handlers;
        self.ws_behaviors[index] = null;
        return index;
    }

    fn common_prefix(first: []const u8, second: []const u8) usize {
        const length = @min(first.len, second.len);
        var index: usize = 0;
        while (index < length and first[index] == second[index]) : (index += 1) {}
        return index;
    }

    fn valid_path(path: []const u8) bool {
        if (path.len == 0 or path.len > max_route_path_size) return false;
        if (path[0] != '/') return false;
        if (std.mem.indexOfAny(u8, path, "?#\r\n") != null) return false;
        return true;
    }

    fn insert_path(self: *Router, path: []const u8) !u16 {
        if (!valid_path(path)) return error.InvalidRoutePath;

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return current;

            var best_child: u16 = null_node;
            var best_prefix: usize = 0;
            var child = self.first_child[current];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const prefix = common_prefix(self.segments[child], search);
                if (prefix == 0) continue;
                best_child = child;
                best_prefix = prefix;
                break;
            }

            if (best_child == null_node) {
                const new_child = try self.alloc_node(search);
                self.next_sibling[new_child] = self.first_child[current];
                self.first_child[current] = new_child;
                return new_child;
            }

            const child_segment = self.segments[best_child];
            if (best_prefix < child_segment.len) {
                const required_nodes: u16 = if (best_prefix < search.len) 2 else 1;
                if (required_nodes > max_nodes - self.node_count) {
                    return error.RouteCapacityReached;
                }

                const split_node = try self.alloc_node(child_segment[best_prefix..]);
                self.first_child[split_node] = self.first_child[best_child];
                self.has_route[split_node] = self.has_route[best_child];
                self.http_handlers[split_node] = self.http_handlers[best_child];
                self.ws_behaviors[split_node] = self.ws_behaviors[best_child];

                self.segments[best_child] = child_segment[0..best_prefix];
                self.first_child[best_child] = split_node;
                self.has_route[best_child] = false;
                self.http_handlers[best_child] = empty_handlers;
                self.ws_behaviors[best_child] = null;
            }

            if (best_prefix == search.len) return best_child;
            current = best_child;
            search = search[best_prefix..];
        }
    }

    fn register_http(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        const node = try self.insert_path(path);
        const method_index = @intFromEnum(method);
        if (self.http_handlers[node][method_index] != null) return error.RouteAlreadyRegistered;

        self.http_handlers[node][method_index] = handler;
        self.has_route[node] = true;
    }

    pub fn get(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .get, handler);
    }

    pub fn head(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .head, handler);
    }

    pub fn post(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .post, handler);
    }

    pub fn put(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .put, handler);
    }

    pub fn delete(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .delete, handler);
    }

    pub fn patch(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .patch, handler);
    }

    pub fn options(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .options, handler);
    }

    pub fn any(self: *Router, path: []const u8, handler: Handler) !void {
        return self.register_http(path, .any, handler);
    }

    pub fn ws(self: *Router, path: []const u8, behavior: WsBehavior) !void {
        const node = try self.insert_path(path);
        if (self.ws_behaviors[node] != null) return error.RouteAlreadyRegistered;

        self.ws_behaviors[node] = behavior;
        self.has_route[node] = true;
    }

    pub fn match(self: *const Router, path: []const u8, method: ?HttpMethod) ?RouteMatch {
        const node = self.find_node(path) orelse return null;
        var handler: ?Handler = null;

        if (method) |known_method| {
            handler = self.http_handlers[node][@intFromEnum(known_method)];
            if (handler == null and known_method == .head) {
                handler = self.http_handlers[node][@intFromEnum(HttpMethod.get)];
            }
        }
        if (handler == null) handler = self.http_handlers[node][@intFromEnum(HttpMethod.any)];

        return .{
            .path = path,
            .http_handler = handler,
            .ws_behavior = self.ws_behaviors[node],
            .allowed_methods = self.allowed_method_mask(node),
            .has_http = self.node_has_http(node),
        };
    }

    fn find_node(self: *const Router, path: []const u8) ?u16 {
        if (self.node_count == 0) return null;

        var current = self.root_idx;
        var search = path;

        while (true) {
            if (search.len == 0) return if (self.has_route[current]) current else null;

            var child = self.first_child[current];
            var found = false;
            const first_char = search[0];

            while (child != null_node) : (child = self.next_sibling[child]) {
                const segment = self.segments[child];
                if (segment.len == 0 or segment[0] != first_char) continue;
                if (!std.mem.startsWith(u8, search, segment)) return null;

                current = child;
                search = search[segment.len..];
                found = true;
                break;
            }

            if (!found) return null;
        }
    }

    fn node_has_http(self: *const Router, node: u16) bool {
        for (self.http_handlers[node]) |handler| {
            if (handler != null) return true;
        }
        return false;
    }

    fn allowed_method_mask(self: *const Router, node: u16) u16 {
        if (self.http_handlers[node][@intFromEnum(HttpMethod.any)] != null) {
            return all_method_mask;
        }

        var mask: u16 = 0;
        for (concrete_methods) |method| {
            if (self.http_handlers[node][@intFromEnum(method)] == null) continue;
            mask |= method_bit(method);
            if (method == .get) mask |= method_bit(.head);
        }
        if (self.ws_behaviors[node] != null) mask |= method_bit(.get);
        return mask;
    }
};

pub fn format_allowed_methods(mask: u16, buffer: []u8) ![]const u8 {
    var offset: usize = 0;

    for (concrete_methods) |method| {
        if (mask & method_bit(method) == 0) continue;

        const separator = if (offset == 0) "" else ", ";
        const method_name = method.name();
        if (separator.len + method_name.len > buffer.len - offset) return error.BufferTooSmall;

        @memcpy(buffer[offset .. offset + separator.len], separator);
        offset += separator.len;
        @memcpy(buffer[offset .. offset + method_name.len], method_name);
        offset += method_name.len;
    }
    return buffer[0..offset];
}

fn method_bit(method: HttpMethod) u16 {
    std.debug.assert(method != .any);
    return @as(u16, 1) << @as(u4, @intCast(@intFromEnum(method)));
}

test "router: websocket limits must fit the configured slab" {
    try std.testing.expect(valid_ws_limits(.{}, 16 * 1024));
    try std.testing.expect(!valid_ws_limits(.{ .max_frame_size = 0 }, 16 * 1024));
    try std.testing.expect(!valid_ws_limits(.{ .max_message_size = 32 * 1024 }, 16 * 1024));
    try std.testing.expect(!valid_ws_limits(.{
        .max_frame_size = 1024,
        .max_message_size = 512,
    }, 16 * 1024));
}
