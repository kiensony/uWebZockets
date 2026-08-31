const std = @import("std");
const uz = @import("uWebZockets");

const max_message_size = 16 * 1024 * 1024;
const write_queue_size = max_message_size + 64 * 1024;

fn echo_message(ws: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    ws.send(message, opcode) catch {
        ws.send_close(1011, "Echo failed") catch ws.terminate();
    };
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.ConfiguredApp(4, max_message_size, write_queue_size).init(init.io);
    defer app.deinit();

    _ = try app.ws("/", .{
        .message = echo_message,
        .compression = .permessage_deflate,
        .max_frame_size = max_message_size,
        .max_message_size = max_message_size,
    });
    try app.listen("0.0.0.0", 9001);

    try app.run();
}
