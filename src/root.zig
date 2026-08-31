//! Supported µWebZockets public API.

pub const App = @import("router/app.zig").app;
pub const ConfiguredApp = @import("router/app.zig").configured_app;
pub const ConfiguredAppWithTimeout = @import("router/app.zig").configured_app_with_timeout;
pub const default_idle_timeout_ms = @import("router/app.zig").default_idle_timeout_ms;
pub const http3_available = @import("router/app.zig").http3_available;

pub const Request = @import("http/request.zig").Request;
pub const Response = @import("http/response.zig").Response;
pub const chunked = @import("http/chunked.zig");

pub const WebSocket = @import("ws/socket.zig").WebSocket;
pub const WsBehavior = @import("router/radix.zig").WsBehavior;
pub const WsCompression = @import("router/radix.zig").WsCompression;
pub const Opcode = @import("zslay").Opcode;
pub const websocket_mask = @import("ws/mask.zig");

pub const tls = @import("crypto/tls.zig");

comptime {
    _ = @import("test.zig");
}
