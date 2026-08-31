<p align="center">
  <img src="misc/uwebzockets-banner.png" alt="µWebZockets banner">
</p>

# µWebZockets

[![Test](https://github.com/kiensony/uWebZockets/actions/workflows/test.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/test.yml)
[![Autobahn Compliance](https://github.com/kiensony/uWebZockets/actions/workflows/autobahn-compliance.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/autobahn-compliance.yml)
[![h1spec Compliance](https://github.com/kiensony/uWebZockets/actions/workflows/h1spec-compliance.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/h1spec-compliance.yml)
[![Benchmark](https://github.com/kiensony/uWebZockets/actions/workflows/benchmark.yml/badge.svg)](https://github.com/kiensony/uWebZockets/actions/workflows/benchmark.yml)

µWebZockets is a bounded-memory, event-driven WebSocket, HTTP/1.1, and HTTP/3
server library for Zig 0.16.0. The request, response, frame parsing, masking,
routing, and connection I/O paths use fixed-capacity storage after application
startup. BoringSSL provides TLS, libxev drives non-blocking POSIX I/O, zslay
0.1.5 provides the WebSocket frame state machine, and lsquic provides QUIC.

Version `1.0.0-alpha` is intended for evaluation and controlled production
pilots. Its API may still change before 1.0.0.

## Features

- HTTP/1.1 GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, and fallback routes
- Request targets split into path and query slices without allocation
- Automatic 404, 405 with `Allow`, OPTIONS, HEAD fallback, and `100 Continue`
- Fixed-size request parsing with strict framing and header validation
- Fixed-capacity, backpressure-aware response queues and chunked responses
- RFC 6455 server framing, fragmentation, masking, close handling, and
  streaming UTF-8 validation
- RFC 7692 per-message deflate with strict extension parsing, bounded expansion,
  and mandatory client/server no-context-takeover
- SIMD WebSocket masking with a scalar tail
- Bounded WebSocket messages, frames, subscriptions, and topic ownership
- HTTPS with BoringSSL TLS 1.3 and HTTP/1.1 ALPN
- Alpha HTTP/3 request/response routing over lsquic with bounded QPACK, stream,
  body, response, and packet storage
- Contiguous connection pools and per-connection storage selected at compile
  time
- Completion-driven shutdown that drains accept, read, write, close, timer,
  and UDP operations before releasing their slabs
- Native GNU/Linux, musl/Linux, and macOS release packages

The bundled Autobahn runner executes all 517 selected server cases. The
verified alpha baseline is 514 `OK` and 3 `INFORMATIONAL` results for both
protocol and close behavior. The strict gate accepts all 517 cases, including
RFC 7692 groups 12 and 13, with no exclusions.

## Requirements

- Zig 0.16.0
- CMake 3.20 or newer
- Ninja
- A POSIX target supported by libxev
- zlib development headers and a static library
- Git submodules checked out recursively

The Nix flake pins Nixpkgs 26.05 and provides the supported Zig, CMake, Ninja,
Go, Python, Perl, and zlib toolchain on all release architectures.

## Build

```sh
git clone --recurse-submodules https://github.com/kiensony/uWebZockets.git
cd uWebZockets
nix develop
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

The Nix shell also exposes a coherent LLVM sanitizer runtime, matching glibc,
and dynamic linker. Run the complete test graph with ASan, UBSan,
LeakSanitizer, Zig C-UB checks, and frame pointers:

```sh
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
```

Outside Nix, also pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. If
that runtime requires a different glibc than the host, pass the matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths together.
Sanitizer builds are intentionally restricted to native Linux, set coherent
runtime RPATHs, and use a separate vendor cache.

Without Nix, install the requirements above and run the same Zig commands. If
zlib is not in the compiler's default search path, pass a prefix containing
`include/` and `lib/libz.a`:

```sh
zig build -Dzlib-prefix=/path/to/zlib-prefix
```

`zig build lib -Doptimize=ReleaseFast` installs the µWebZockets, BoringSSL,
lsquic, and libdeflate static archives under `zig-out/lib`. Applications that
link these archives directly must also link libc, the C++ runtime, zlib, and
the platform networking libraries required by those dependencies.

## Use as a Zig dependency

Until the alpha tag is published, a source checkout can be used as a path
dependency:

```zig
// build.zig.zon
.dependencies = .{
    .uWebZockets = .{ .path = "vendor/uWebZockets" },
},
```

```zig
// build.zig
const uz = b.dependency("uWebZockets", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("uWebZockets", uz.module("uWebZockets"));
```

The dependency checkout must include the repository's recursive git
submodules.

## HTTP example

```zig
const std = @import("std");
const uz = @import("uWebZockets");

fn hello(req: *uz.Request, res: *uz.Response) void {
    const name = if (req.query.len == 0) "world" else req.query;
    res.end_with_headers(
        "200 OK",
        "Content-Type: text/plain\r\n",
        name,
    ) catch return;
}

pub fn main(init: std.process.Init) !void {
    var server = try uz.App(1024).init(init.io);
    defer server.deinit();

    _ = try server.get("/hello", hello);
    try server.listen("0.0.0.0", 3000);
    try server.run();
}
```

Route strings are borrowed for the application's lifetime. Register static or
otherwise long-lived strings before calling `listen` or `listen_udp`; route
registration returns `error.RoutesLocked` after either listener starts. Do not
move the `App` value after listening; event-loop callbacks retain its address.

For incremental HTTP output, call `begin_chunked`, `write_chunk` as needed,
then `end_chunks`. A handler must finish one response before returning; async
handler suspension is not part of the alpha API. `Request` fields borrow the
connection's request buffer and are valid only until the handler returns.

## WebSocket example

```zig
const std = @import("std");
const uz = @import("uWebZockets");
fn echo(ws: *uz.WebSocket, message: []const u8, opcode: uz.Opcode) void {
    ws.send(message, opcode) catch {
        ws.send_close(1011, "write failed") catch return;
    };
}

pub fn main(init: std.process.Init) !void {
    const max_message_size = 1024 * 1024;
    const write_queue_size = max_message_size + 64 * 1024;
    var server = try uz.ConfiguredApp(
        1024,
        max_message_size,
        write_queue_size,
    ).init(init.io);
    defer server.deinit();

    _ = try server.ws("/echo", .{
        .message = echo,
        .compression = .permessage_deflate,
        .max_frame_size = max_message_size,
        .max_message_size = max_message_size,
    });
    try server.listen("0.0.0.0", 3000);
    try server.run();
}
```

`App` defaults to 16 KiB WebSocket messages. `ConfiguredApp` changes the
compile-time connection count, message capacity, and write-queue capacity.
`send` returns `error.WouldBlock` if bounded output storage is exhausted. Use
the WebSocket `drain` callback and `buffered_amount` to resume producers.
Incoming `message` slices are valid only for the duration of the callback.
Outgoing text and close data are validated; `send_close` closes after the
frame drains, while `terminate` performs an immediate transport close.

Compression is opt-in per WebSocket route. Enabling `.permessage_deflate`
allocates separate bounded receive and send scratch slices per connection
during route registration; message processing itself does not allocate.
Negotiation always selects
`server_no_context_takeover` and `client_no_context_takeover`, accepts window
sizes 9 through 15 for server output and 8 through 15 for client input, and
rejects compressed expansion beyond `max_message_size`.

The default idle timeout is 120 seconds and is refreshed by successful reads
and writes. Use `ConfiguredAppWithTimeout` to select another compile-time
timeout, or zero to disable idle sweeping:

```zig
const Server = uz.ConfiguredAppWithTimeout(
    1024,
    1024 * 1024,
    1024 * 1024 + 64 * 1024,
    300_000,
);
```

## HTTPS

Use `init_https` with PEM certificate and private-key paths:

```zig
var server = try uz.App(1024).init_https(
    init.io,
    "certs/cert.pem",
    "certs/key.pem",
);
```

The server negotiates TLS 1.3 and advertises only `http/1.1`.

## HTTP/3

`init_http3` creates isolated TLS 1.3 contexts: TCP advertises only
`http/1.1`, while QUIC advertises only `h3`. Register the same HTTP handlers,
then bind the QUIC endpoint with `listen_udp`:

```zig
var server = try uz.App(128).init_http3(
    init.io,
    "certs/cert.pem",
    "certs/key.pem",
);
defer server.deinit();

_ = try server.get("/", hello);
try server.listen_udp("0.0.0.0", 8443);
try server.run();
```

The adapter decodes HTTP/3 pseudo-headers directly into the existing `Request`
shape and writes structured QPACK response headers without converting through
HTTP/1.1 text. QUIC connections, streams, header sets, packet buffers, request
bodies, and responses come from startup-allocated contiguous pools. The `App`
value must remain at a stable address after `listen_udp`.

## Capacity and protocol limits

The alpha defaults are deliberately finite:

| Resource | Limit |
| --- | ---: |
| Request line | 8 KiB |
| HTTP headers | 16 KiB total, 64 fields |
| HTTP request body | 16 KiB |
| Routes | 256 radix nodes |
| Route path | 2 KiB |
| WebSocket message | 16 KiB with `App` |
| WebSocket control payload | 125 bytes |
| HTTP/3 decoded headers | 16 KiB total, 64 fields |
| HTTP/3 request body | 16 KiB |
| HTTP/3 response metadata | 4 KiB, 64 fields |
| HTTP/3 response body | configured write-queue capacity |
| QUIC UDP payload | 2 KiB |
| QUIC connections and active streams | configured connection capacity |
| Write queue | fixed per connection |
| Idle timeout | 120 seconds by default |

Oversized or ambiguous input is rejected rather than expanded dynamically.

## Current limitations

- HTTP/2 is unavailable.
- HTTP/3 is an alpha server adapter. WebSocket extended CONNECT, server push,
  WebTransport, 0-RTT application handling, and a cross-implementation HTTP/3
  compliance gate are not yet exposed.
- Per-message deflate deliberately uses no-context-takeover. An offered 8-bit
  server compression window is declined because zlib cannot emit it reliably;
  8-bit client compression is accepted and decoded within the configured
  output bound.
- Windows is not a supported alpha target.
- Route parameters, middleware, async handlers, and a stable C ABI are not yet
  exposed.
- The project has not yet published long-term performance guarantees.

See [CHANGELOG.md](CHANGELOG.md), [CODEBASE.md](CODEBASE.md), and
[CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) for release details, architecture, and
verification. Security reports must follow [SECURITY.md](SECURITY.md).

## License

µWebZockets is licensed under the MIT License. Third-party attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
