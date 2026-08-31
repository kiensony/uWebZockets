const std = @import("std");
const app = @import("../router/app.zig");
const radix = @import("../router/radix.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

// dummy handler to verify route routing
fn dummy_handler(req: *Request, res: *Response) void {
    _ = req;
    _ = res;
}

// tests radix trie insertion and exact matching
test "router: radix trie exact match" {
    var router = radix.Router.init();

    try router.get("/api/v1/users", dummy_handler);
    try router.post("/api/v1/users", dummy_handler);
    try router.get("/api/v1/posts", dummy_handler);
    try router.ws("/chat", .{});

    const r1 = router.match("/api/v1/users", .get);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r1.?.http_handler != null);

    const r2 = router.match("/api/v1/posts", .get);
    try std.testing.expect(r2 != null);

    const r3 = router.match("/chat", .get);
    try std.testing.expect(r3 != null);
    try std.testing.expect(r3.?.ws_behavior != null);

    const r4 = router.match("/notfound", .get);
    try std.testing.expect(r4 == null);

    const method_mismatch = router.match("/api/v1/posts", .post).?;
    try std.testing.expect(method_mismatch.http_handler == null);

    var allow_buffer: [64]u8 = undefined;
    const allow = try radix.format_allowed_methods(method_mismatch.allowed_methods, &allow_buffer);
    try std.testing.expectEqualStrings("GET, HEAD", allow);
}

test "router: application timeout policy is compile-time configurable" {
    const WithoutIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 0);
    const WithShortIdleTimeout = app.configured_app_with_timeout(1, 1024, 4096, 1000);

    _ = WithoutIdleTimeout;
    _ = WithShortIdleTimeout;
    try std.testing.expectEqual(@as(u64, 120_000), app.default_idle_timeout_ms);
}
