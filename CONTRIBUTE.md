# Contributing to µWebZockets

µWebZockets accepts focused changes that preserve bounded resource use,
protocol correctness, and a shallow data-oriented design.

Read [CODEBASE.md](CODEBASE.md), [CODING_CONVENTION.md](CODING_CONVENTION.md),
and [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md) before changing the transport or
protocol paths. Report security defects privately as described in
[SECURITY.md](SECURITY.md).

## Development environment

Clone every submodule and use the pinned Nix shell when possible:

```sh
git clone --recurse-submodules https://github.com/kiensony/uWebZockets.git
cd uWebZockets
nix develop
```

The flake pins Nixpkgs 26.05. The non-Nix toolchain requires Zig 0.16.0, CMake,
Ninja, Go, Python, Perl, and zlib development files.

## Engineering requirements

- Do not allocate in request parsing, frame parsing, masking, routing, or
  network write callbacks. Allocate fixed application storage at startup.
- Cap every peer-controlled length, count, queue, and subscription.
- Prefer parallel arrays or compact slabs when a hot loop reads only a subset
  of fields. Do not force Struct of Arrays onto small one-off records.
- Keep parsing and validation functions pure where practical. Pass mutable I/O
  state explicitly at the event-loop boundary.
- Finish route registration before starting either listener; route arrays are
  immutable once `listen` or `listen_udp` succeeds.
- Use early returns and short error paths. Never silently swallow an error.
- Use `snake_case` for project files, functions, and variables. Preserve raw C
  identifiers only at the FFI boundary.
- Keep comments concise and explain constraints or non-obvious tradeoffs.
- Do not add emoji characters anywhere in the repository.
- Keep new Zig unit tests inline in the implementation module. Do not move or
  consolidate existing inline `test` blocks into `src/tests`.
- Preserve upstream style in vendored submodules; update those through their
  upstream project rather than rewriting vendored files.

## Local checks

Run all relevant checks before opening a pull request:

```sh
zig fmt --check build.zig src examples tests
sh scripts/check_conventions.sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build lib -Doptimize=ReleaseFast --summary all
```

The sanitizer command requires native Linux. `nix develop` exports matching
sanitizer, glibc, and dynamic-linker paths automatically. Non-Nix setups must
pass `-Dsanitizer-lib-dir=/path/to/compiler/runtime/lib`. When that runtime
uses a different glibc than the host, also pass matching
`-Dsanitizer-libc-dir` and `-Dsanitizer-dynamic-linker` paths.

Changes to WebSocket parsing or I/O must also run the Autobahn target. Changes
to HTTP parsing, dispatch, or response framing must run h1spec. Changes to
HTTP/3 must compile `http3_server`, exercise the inline QPACK/framing tests, and
perform an interoperability check when a compatible client is available. The
exact CI commands and report gate are documented in
[CI_CD_PIPELINE.md](CI_CD_PIPELINE.md).

Tests should use fixed caller-owned storage for hot paths. If the unit under
test allocates, use `std.testing.allocator` or another leak-detecting allocator
and prove all success and error paths release ownership.

New external-byte parsers or framing transformations must have a bounded Zig
fuzz target compatible with the existing libFuzzer-backed `zig build fuzz`
step. FFI changes must preserve exact C layout checks and include malformed and
capacity-exhaustion cases.

## Pull requests

- Explain the protocol, ownership, or performance invariant being changed.
- Include regression tests for bugs and malformed-input tests for parsers.
- Document API, limit, configuration, or compatibility changes.
- Separate measured performance results from estimates.
- Note breaking changes explicitly in the pull request and changelog.
- Keep commits concise and follow
  [.github/COMMIT_CONVENTION.md](.github/COMMIT_CONVENTION.md).

## Dependency updates

For Zig dependencies, update all generated package views together:

- `build.zig.zon`
- `build.zig.zon.json`
- `build.zig.zon.nix`
- `build.zig.zon.txt`

Record the upstream version, immutable URL or revision, Zig package hash, Nix
hash, license, and any API migration. Rebuild from an empty Zig/vendor cache so
a stale artifact cannot hide a dependency problem.

For C/C++ submodules, retain CMake target-based builds, Ninja execution, the
Zig compiler wrappers, target-specific cache directories, and static-library
outputs. Do not add global compiler or linker flags when target-local settings
work.

## Releasing

1. Set the same version in `build.zig.zon` and `flake.nix`.
2. Add a dated `CHANGELOG.md` section with breaking changes and limitations.
3. Verify `THIRD_PARTY_NOTICES.md` and every packaged license.
4. Pass local formatting, convention, test, and build checks.
5. Pass sanitizer, fuzz, Autobahn, and h1spec checks on the release commit.
6. Tag the final commit as `v<version>` and push the tag.
7. Review all six `Publish` environment deployments, archives, and
   `SHA256SUMS` before announcing the release.
