# µWebZockets Codebase

## Scope

µWebZockets is a Zig 0.16.0 HTTP/1.1, WebSocket, and alpha HTTP/3 server
library. It combines an event-driven POSIX transport, fixed-capacity protocol
state, a data-oriented router, and C libraries for TLS, compression, and QUIC.

The alpha release makes bounded resource use explicit. Startup allocates one
contiguous connection slab, one WebSocket message region, and one output region.
Network callbacks then reuse those regions without general-purpose allocation.
WebSocket compression and HTTP/3 allocate their fixed slabs when the feature is
configured, before listening begins. Route arrays are immutable after either
listener starts, so callbacks never observe a structural mutation.

## Design rules

1. Data is grouped by access pattern. The pool's activity bitmap and the
   router's parallel node arrays are scanned independently from cold fields.
2. Parsing and transforms are expressed as small functions with explicit input
   and output state. Stateful I/O remains localized at transport boundaries.
3. Hot paths have fixed capacity. Exhaustion returns an error or closes the
   offending peer instead of allocating.
4. POSIX non-blocking I/O and libxev drive callbacks. CMake and Ninja build the
   vendored C and C++ libraries with Zig compiler wrappers.
5. WebSocket masking operates on native SIMD vectors before handling the scalar
   tail.

## Layout

```text
uWebZockets/
├── build.zig                 # Zig and C/C++ build graph
├── build.zig.zon             # Zig 0.16 package manifest
├── flake.nix                 # native GNU/musl and macOS packages
├── src/
│   ├── root.zig              # supported public API
│   ├── core/                 # libxev loop, TCP, pool, context, timer
│   ├── crypto/               # bounded BoringSSL TLS adapter
│   ├── http/                 # strict HTTP/1.1 parser and response writer
│   ├── router/               # fixed-capacity radix router and App API
│   ├── ws/                   # zslay integration, masking, UTF-8, pub/sub
│   ├── quic/                 # bounded internal lsquic/HTTP/3 adapter
│   └── tests/                # retained aggregate tests for existing modules
├── tests/
│   ├── autobahn/             # RFC 6455 target, Deno runner, and config
│   └── h1spec/               # HTTP/1.1 compliance target
├── examples/                 # HTTP/1.1, WebSocket, and HTTP/3 examples
└── vendor/                   # pinned C/C++ and compliance submodules
```

## Runtime data flow

```text
libxev accept/read
      |
      v
fixed connection slot ----> optional bounded TLS BIO pair
      |
      v
HTTP request accumulator --> strict parser --> radix route
                                      |             |
                                      |             +--> bounded HTTP writer
                                      v
                             WebSocket upgrade
                                      |
                                      v
                          zslay frame state machine
                                      |
                     SIMD unmask + streaming UTF-8
                                      |
                                      v
                         callback / bounded pub-sub

UDP read --> lsquic engine --> bounded QPACK header set --> same radix route
                                   |                           |
                                   v                           v
                            bounded body slab          structured H3 response
```

The connection pool owns a contiguous `TcpConnection` slab and a separate
activity bitmap. `ConfiguredApp` divides contiguous message and write regions
into one slice per connection. This avoids one allocation per accepted socket
and makes cleanup deterministic. A closed slot is not returned to the freelist
until its close, read, and write completions have all drained, preventing an
old completion from observing a reused connection.

Shutdown reverses that ownership graph. The application first rejects new
work, stops recurring timers, cancels accept/read/write/UDP completions, closes
descriptors through libxev, and runs the loop until every callback is disarmed.
Only then are TLS state, QUIC state, the loop, and contiguous slabs released.

## HTTP/1.1

The TCP connection accumulates a bounded request until the parser can prove it
is complete. The parser rejects conflicting or malformed framing, excessive
request lines, headers, bodies, and unsupported expectations. Pipelined bytes
are retained and parsed again after a response completes.

The router is a fixed-capacity runtime radix tree represented by parallel
arrays for segments, child/sibling links, route bits, method handlers, and
WebSocket behaviors. It supports method-specific handlers, HEAD fallback,
OPTIONS, `Allow`, and an `any` fallback. Route strings are borrowed and must
outlive the application.

Response metadata is validated against control-character injection and
ambiguous `Content-Length` or `Transfer-Encoding`. Writes enter a bounded ring
queue and handle partial kernel writes. A fully drained ring normalizes its head
to keep the next logical write contiguous instead of creating a delayed-ACK
wrap split. Producers observe `error.WouldBlock` instead of causing unbounded
memory growth. Chunk headers, bodies, and terminators are copied into that ring
as parts, so no per-connection chunk scratch allocation or fixed 8 KiB chunk
ceiling is needed.

## WebSocket

zslay 0.1.5 validates frame structure and size limits. µWebZockets adds strict
server-side handshake validation, fragmented-message assembly, streaming UTF-8
validation, close-code handling, SIMD unmasking, and bounded writes. Control
frames use a 125-byte inline buffer. Message storage is provided by the owning
application and reused for the connection lifetime. Application message slices
are callback-scoped and outgoing text, control, and close frames are validated
before entering the transport queue.

RFC 7692 is opt-in through `WsBehavior.compression`. Extension negotiation is a
pure bounded parser that ignores malformed alternatives independently and
always selects client/server no-context-takeover. Full-window messages use
libdeflate; negotiated 9-14 bit server windows use preinitialized zlib streams
backed by fixed arenas. Incoming 8-15 bit client windows are decoded by the
bounded libdeflate path. Compressed input and decompressed output are capped by
per-connection receive scratch, send scratch, and message slices, so expansion
never causes a hot-path allocation and an outbound callback cannot corrupt an
in-progress compressed receive.

Pub/sub copies topic names into fixed internal storage, caps subscriptions, and
removes connection references during close. Published message bytes are never
retained after the callback returns.

## TLS and HTTP/3

HTTPS uses BoringSSL TLS 1.3 with an in-memory BIO pair sized to match the
bounded output policy. The adapter validates context creation, propagates
backpressure, performs shutdown, and advertises HTTP/1.1 through ALPN.

`init_http3` creates transport-isolated TLS 1.3 contexts: the TCP context
advertises only `http/1.1`, and the QUIC context advertises only `h3`.
`listen_udp` constructs the lsquic engine in place only after the `App` has a
stable address. The engine uses contiguous freelist pools for streams, header
sets, and outgoing packets, plus parallel byte regions for decoded QPACK data,
request bodies, response headers, and response bodies. Pool capacity is the
configured connection count; packet capacity is
`max(16, connections * 4)`.

The header decoder validates pseudo-header ordering and uniqueness, lowercase
HTTP/3 names, URI targets, authority/Host agreement, connection-specific
fields, and content-length. It fills the existing `Request` directly rather
than producing temporary HTTP/1.1 text. Responses reuse the public `Response`
API and emit structured QPACK headers while preserving partial stream writes. QUIC global
initialization is reference-counted under a small atomic lock. HTTP/3 internals
remain unexported so applications use only `init_http3`, `listen_udp`, routes,
and `Response`.

## Build graph

`build.zig` maps Zig optimization modes to CMake build types and invokes Ninja
for BoringSSL, lsquic, and libdeflate. The `zig-cc` and `zig-c++` wrappers pass
the selected target triple to cross builds. Vendor caches are separated by
target and optimization mode. Sanitizer mode adds another isolated cache,
instruments BoringSSL, lsquic, libdeflate, and the ABI shim with ASan/UBSan,
enables Zig's full C-UB checks, and preserves frame pointers.

The Nix flake pins Nixpkgs 26.05, seeds Zig package dependencies
deterministically, and defines native and musl compile checks. Release archives
contain the µWebZockets, BoringSSL, lsquic, and libdeflate static libraries plus
their license texts.

## Supported and internal API

The supported surface is exported from `src/root.zig`: `App`, `ConfiguredApp`,
`ConfiguredAppWithTimeout`, `Request`, `Response`, `WebSocket`, `WsBehavior`,
`Opcode`, TLS configuration, chunked HTTP helpers, and WebSocket masking. The
surface also includes `WsCompression`, `http3_available`, `init_http3`, and
`listen_udp` through the application type. Files under `src/quic` are internal
and must not be imported by consumers.

New Zig tests live inline beside the implementation they validate. The
existing `src/tests` aggregate remains for compatibility and is not a target
for moving inline tests.
