const std = @import("std");
const uz = @import("uWebZockets");

fn index(_: *uz.Request, response: *uz.Response) void {
    response.end_with_headers(
        "200 OK",
        "Content-Type: text/plain\r\n",
        "Hello from bounded HTTP/3",
    ) catch return;
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(128).init_http3(
        init.io,
        "certs/cert.pem",
        "certs/key.pem",
    );
    defer server.deinit();

    _ = try server.get("/", index);
    try server.listen_udp("0.0.0.0", 8443);
    try server.run();
}
