const std = @import("std");
const uz = @import("uWebZockets");

fn on_ws_open(ws: *uz.WebSocket) void {
    // upon connection, join the client to the "global" room
    ws.subscribe("global") catch {
        std.debug.print("error: unable to join room.\n", .{});
        return;
    };

    // notify the whole room about the new user
    _ = ws.publish("global", "system: a new user just joined", true);
}

fn on_ws_message(ws: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    // broadcast this person's message to everyone in the "global" room
    const is_text = (opcode == .text);
    _ = ws.publish("global", message, is_text);
}

fn on_ws_close(ws: *uz.WebSocket) void {
    _ = ws.unsubscribe("global");
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(128).init(init.io);
    defer app.deinit();

    _ = try app.ws("/chat", .{
        .open = on_ws_open,
        .message = on_ws_message,
        .close = on_ws_close,
    });
    try app.listen("0.0.0.0", 3000);

    std.debug.print("group chat server is running on port 3000\n", .{});
    try app.run();
}
