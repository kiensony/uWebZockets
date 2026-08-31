const std = @import("std");
const uz = @import("uWebZockets");

fn echo_handler(req: *uz.Request, res: *uz.Response) void {
    const body = if (req.body.len > 0) req.body else "h1spec echo";
    res.end("200 OK", body) catch |err| {
        std.debug.print("response error: {}\n", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    var app = try uz.App(1024).init(init.io);
    defer app.deinit();

    _ = try app.any("/", echo_handler);

    try app.listen("0.0.0.0", 8000);
    try app.run();
}
