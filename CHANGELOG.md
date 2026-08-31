# Changelog

All notable changes to µWebZockets are documented in this file. The project
uses Semantic Versioning, with prerelease stability rules applying to alpha
versions.

## [Unreleased]

## [1.0.0-alpha] - 2026-08-31

### Added

- Added bounded `ConfiguredApp` storage for per-connection WebSocket messages
  and output queues.
- Added method-aware HTTP routes for GET, HEAD, POST, PUT, DELETE, PATCH,
  OPTIONS, and fallback handlers.
- Added query/path separation, duplicate-header inspection, HEAD fallback,
  automatic OPTIONS and `Allow`, `100 Continue`, and chunked responses.
- Added WebSocket upgrade authorization, frame/message limits, close handling,
  drain notification, buffered-byte reporting, streaming UTF-8 validation, and
  SIMD masking.
- Added RFC 7692 per-message deflate with strict offer parsing, mandatory
  client/server no-context-takeover, 9-15 bit server and 8-15 bit client window
  negotiation, bounded decompression, and startup-allocated per-connection
  scratch storage.
- Added HTTPS with BoringSSL TLS 1.3 and HTTP/1.1 ALPN.
- Added a bounded HTTP/3 server adapter over lsquic with direct QPACK-to-Request
  decoding, structured response headers, fixed stream/header/packet pools,
  partial-write handling, and shared HTTP route dispatch.
- Added `ConfiguredAppWithTimeout`, a 120-second default idle policy, and the
  option to disable idle sweeping with a zero timeout.
- Added Autobahn and h1spec compliance servers and GitHub Actions workflows,
  including a Deno-orchestrated Autobahn runner with deterministic cleanup and
  report gating.
- Added bounded HTTP, HTTP/3 metadata, zslay, and WebSocket extension fuzz
  targets, plus a nightly/PR HTTP throughput regression workflow with a
  dedicated `Benchmarking` environment.
- Added Nix native/musl packages, six-target publishing, checksums, deployment
  environments, and third-party license packaging.
- Added native-Linux ASan, UBSan, LeakSanitizer, and Zig C-UB test mode for the
  Zig/C/C++ graph, with an isolated sanitizer vendor cache.

### Changed

- Updated zslay from 0.1.1 to 0.1.5 using the immutable v0.1.5 source archive.
- Migrated WebSocket parsing to zslay 0.1.5's role, frame-node, length-limit,
  and error APIs.
- Reworked connection ownership into a contiguous slab with an activity bitmap
  and deterministic release.
- Reworked application shutdown into an idempotent completion-driven drain;
  new work is rejected before accept, TCP, timer, UDP, and QUIC resources are
  stopped and released in ownership order.
- Reworked routing as fixed-capacity parallel arrays and made duplicate,
  invalid, or excessive routes return errors. Route mutation is locked after
  either listener starts.
- Reworked TCP and TLS writes to preserve partial writes in bounded queues and
  signal backpressure.
- Reworked pub/sub to own bounded topic names and remove stale subscribers.
- Mapped Zig optimization modes and target triples into isolated CMake/Ninja
  builds for BoringSSL, lsquic, and libdeflate.
- Pinned Nixpkgs 26.05 so GNU/Linux, musl/Linux, Apple Silicon macOS, and Intel
  macOS release outputs evaluate from one flake.
- Pinned the Autobahn image by digest and used Deno's native process API so the
  compliance runner has no runtime JavaScript dependency graph.
- Run the Autobahn container with the invoking POSIX UID/GID so generated
  reports remain replaceable across repeated local runs.
- Disabled BoringSSL's unused test/benchmark targets in the embedded build and
  passed the selected Ninja executable directly to every CMake configure.

### Fixed

- Fixed connection-pool initialization, double release, stale-slot reuse, and
  inactive-slot sweeping defects. Pool reuse now waits for outstanding read,
  write, and close completions.
- Fixed application teardown leaks across sockets, TLS objects, timers,
  message storage, write storage, and pub/sub state.
- Fixed a high-severity use-after-free where application teardown could free
  the connection slab, timers, event loop, and I/O buffers while libxev
  completions still retained pointers into them.
- Fixed a recurring io_uring timer rearm that reused an expired absolute
  deadline and could spin a CPU core.
- Fixed benchmark candidate and baseline builds running from the parent
  workspace where Zig could not discover either checkout's `build.zig`.
- Fixed drained TCP write rings retaining a tail offset that split later small
  responses across the wrap boundary and triggered delayed-ACK stalls.
- Added bounded benchmark build retries for transient immutable dependency
  fetch failures.
- Fixed HTTP request accumulation, pipelining, partial writes, close-after-drain,
  duplicate framing headers, oversized metadata/body handling, and response
  header injection. Empty header names, invalid chunk-size grammar, oversized
  trailers, invalid response statuses, and bodies on 204/304 are rejected.
- Fixed WebSocket masking, fragmented empty-final frames, fragmented large
  messages, invalid UTF-8 across frame boundaries, invalid close payloads,
  unbounded writes, and masked server output.
- Fixed plaintext handling in HTTPS mode and bounded the TLS BIO pair.
- Rejected sockets now close immediately before any I/O registration, avoiding
  completion-storage exhaustion.
- Removed the per-connection chunk scratch buffer and its 8 KiB chunk ceiling;
  chunk parts now enter the bounded output ring directly.
- Fixed outbound WebSocket UTF-8, control-length, close-code, and close-reason
  validation, including the RFC 6455 distinction between protocol errors and
  invalid UTF-8 close reasons.
- Fixed compressed fragmented messages, RSV1 validation, malformed extension
  alternatives, compressed expansion bombs, and negotiated small-window
  server output.
- Separated inbound and outbound compression scratch so a drain callback or
  pub/sub send cannot overwrite a fragmented compressed message in progress.
- Closed TCP descriptors when listener binding or activation fails.
- Fixed HTTP/3 header ordering, duplicate pseudo-headers and content lengths,
  URI target and authority validation, connection-specific metadata,
  request-body framing, bounded response buffering, packet ownership, and
  global lsquic initialization lifetime.

### Security

- Added strict WebSocket handshake validation for method, upgrade tokens,
  version, unique key headers, and optional application authorization.
- Added finite limits for every peer-controlled HTTP and WebSocket buffer used
  by the public server path.
- Reject ambiguous HTTP framing and control characters in response status or
  header metadata.
- Added strict HTTP/3 pseudo-header, lowercase-name, connection-metadata,
  content-length, QPACK storage, request-body, response, and UDP packet bounds.
- Added sanitizer CI with leak detection across the connection slab,
  completion-driven teardown, compression engines, and C/C++ FFI boundaries.
- Added strict RFC 7692 negotiation and no-context-takeover so compressed state
  is never retained across application messages.

### Breaking changes

- Route and WebSocket registration return errors and must be called with
  `try`, `catch`, or equivalent handling.
- Route registration returns `error.RoutesLocked` after `listen` or
  `listen_udp` succeeds.
- Applications that need messages larger than 16 KiB must use
  `ConfiguredApp` and set matching `WsBehavior` limits.
- Output can now return `error.WouldBlock`; WebSocket producers should resume
  from the `drain` callback.
- `WebSocket.send` rejects continuation opcodes because the public API emits
  complete final messages. `send_close` closes the transport after the close
  frame drains; use `terminate` for an immediate close.
- `http3_available` is now true. `init_http3` creates transport-isolated
  HTTP/1.1 and HTTP/3 TLS contexts, and HTTP/3 servers must call `listen_udp`
  before `run`.
- `WsBehavior` now exposes `.compression`; its default remains `.disabled`.
- Request route matching uses `Request.path`; the original request target and
  query are available separately as `Request.target` and `Request.query`.

### Known limitations

- HTTP/2, Windows, route parameters, middleware, async handlers, and a stable C
  ABI are not available in this alpha.
- HTTP/3 does not yet expose WebSocket extended CONNECT, server push,
  WebTransport, 0-RTT application handling, or a cross-implementation
  compliance gate.
- RFC 7692 deliberately requires no-context-takeover and declines offers that
  require an 8-bit server compression window. An 8-bit client window remains
  supported for bounded decompression.
- The no-exclusion Autobahn run covers all 517 selected cases with 514 `OK`
  and 3 `INFORMATIONAL` results for both protocol and close behavior. The
  compliance gate passes groups 1-7 and 9-13, including compression.
