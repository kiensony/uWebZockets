# µWebZockets Examples

Build the supported examples with Zig 0.16.0 and all recursive submodules:

```sh
zig build -Doptimize=ReleaseSafe
```

The default install contains `hello_world`, `chat_server`, `http3_server`,
`h1spec`, and `autobahn_server` under `zig-out/bin`.

## HTTP/1.1 server

Start the server:

```sh
./zig-out/bin/hello_world
```

Verify it from another terminal:

```sh
curl -i http://127.0.0.1:3000/
```

The expected result is `HTTP/1.1 200 OK` and the body `Hello from
µWebZockets! Zero allocation achieved.`

The equivalent build-and-run step is:

```sh
zig build hello_world -Doptimize=ReleaseSafe
```

## WebSocket pub/sub server

Start the server:

```sh
./zig-out/bin/chat_server
```

Connect two clients to the same bounded topic:

```sh
npx wscat -c ws://127.0.0.1:3000/chat
```

Text or binary messages sent by either client are published to the `global`
topic. The example reports subscription failure instead of silently continuing
when fixed pub/sub capacity is exhausted.

Message bytes are borrowed only until the callback returns. Copy into
application-owned bounded storage if work must outlive that callback.

The equivalent build-and-run step is:

```sh
zig build chat_server -Doptimize=ReleaseSafe
```

## Compliance targets

`autobahn_server` listens on port 9001 and accepts a 16 MiB echo message for
the external Autobahn fuzzing client. `h1spec` listens on port 8000 for the
vendored HTTP/1.1 suite. Use the GitHub workflows or the commands documented in
[CI_CD_PIPELINE.md](../CI_CD_PIPELINE.md) so readiness checks and report gates
are applied consistently.

## HTTP/3 server

Place a PEM certificate and matching private key at `certs/cert.pem` and
`certs/key.pem`, then build and start the bounded lsquic server:

```sh
zig build http3_server -Doptimize=ReleaseSafe
./zig-out/bin/http3_server
```

The server listens for QUIC on UDP port 8443 and routes `GET /` through the
same `Request` and `Response` API as HTTP/1.1. A client with HTTP/3 support can
request `https://127.0.0.1:8443/`; configure trust appropriately for a local
self-signed certificate.

The example uses a capacity of 128 connections/active streams. QPACK headers,
request bodies, response metadata, response bodies, and outgoing UDP packets
all use fixed startup-allocated pools. WebSocket extended CONNECT is not part
of the alpha HTTP/3 adapter.
