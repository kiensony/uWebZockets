# Security Policy

## Supported versions

`1.0.0-alpha` is the only supported line while the project is in alpha. Fixes
are applied to the latest alpha release; older snapshots and unsupported raw
transport internals do not receive backports.

| Version | Supported |
| --- | --- |
| 1.0.0-alpha | Yes |
| Earlier snapshots | No |

## Reporting a vulnerability

Do not open a public issue, pull request, discussion, or Autobahn report that
contains an undisclosed vulnerability.

Send a private report to
[trananhquan1009@gmail.com](mailto:trananhquan1009@gmail.com) or
[noah1109.tran@gmail.com](mailto:noah1109.tran@gmail.com). Include:

- the affected revision and target platform;
- a minimal reproducer or packet sequence;
- expected and observed behavior;
- impact and preconditions;
- logs or sanitizer output with secrets removed; and
- any suggested mitigation.

The maintainers will acknowledge the report, reproduce and assess it, prepare a
fix and regression test, and coordinate disclosure. Response time depends on
severity and maintainer availability; no fixed service-level agreement is
offered during alpha.

## Security boundaries

The supported network surface is HTTP/1.1, RFC 6455 WebSockets, RFC 7692
per-message deflate, HTTPS, and the bounded alpha HTTP/3 server API exported by
`src/root.zig`. Raw QUIC engine, stream, packet, and QPACK callbacks under
`src/quic` are internal and are not a supported consumer interface.

Deployments must set connection, WebSocket message, write-queue, and HTTP/3
response capacities appropriate for their traffic, select an appropriate idle
timeout, and apply normal operating-system resource limits. The default idle
timeout is 120 seconds; `ConfiguredAppWithTimeout` can change it or disable
idle sweeping with zero. HTTP/3 additionally bounds decoded headers, request
bodies, packet buffers, connections, and active streams.

Per-message deflate is disabled by default. When enabled, negotiation requires
client and server no-context-takeover, compressed input and output use separate
caller-owned scratch slices, and decompression cannot exceed the configured
message capacity. An 8-bit server compression window is declined because zlib
cannot emit it reliably; incoming 8-bit client streams retain the same
decompression bound.

Request and WebSocket message slices are borrowed from fixed connection
storage and must not escape their callback. The application value itself must
remain at a stable address after `listen`.

The project uses bounded buffers and protocol compliance tests to reduce risk,
but these controls do not guarantee the absence of defects. Consumers should
pin release hashes, review `THIRD_PARTY_NOTICES.md`, and test the library under
their own workload before production deployment.

Application teardown is completion-driven: stop accepting new work, cancel and
drain registered libxev operations, then release TLS, QUIC, event-loop, and slab
storage. Consumers should call `deinit` through `defer` and must not copy or move
an `App` after `listen` or `listen_udp` has registered callbacks.

The CI sanitizer mode covers the Zig/C/C++ graph with ASan, UBSan, and leak
detection on native Linux. HTTP/3 remains alpha and does not yet have an
external cross-implementation compliance gate, so deployments should perform
their own QUIC interoperability and load testing.

## Disclosure

Please allow a reasonable remediation and release window before publication.
Security advisories will credit reporters who request attribution and will
describe affected versions, impact, and upgrade guidance without exposing
unnecessary exploit detail before a fix is available.
