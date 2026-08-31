# µWebZockets CI/CD Pipeline

The pipeline verifies formatting, bounded protocol behavior, multiple
optimization modes, standards compliance, cross-target compilation, and
release metadata. A passing pipeline is evidence for the tested configurations;
it is not a proof that all memory or security defects are absent.

## Workflows

| Workflow | Trigger | Environment | Purpose |
| --- | --- | --- | --- |
| `lint.yml` | pushes and pull requests to `main`, manual | `Linting` | Zig formatting and repository conventions |
| `test.yml` | pushes and pull requests to `main`, manual | `Testing` | Debug, sanitizer, fuzz, ReleaseSafe, and ReleaseFast verification |
| `autobahn-compliance.yml` | pushes and pull requests to `main`, manual | `autobahn Compliance` | RFC 6455 server compliance |
| `h1spec-compliance.yml` | pushes and pull requests to `main`, manual | `h1spec Compliance` | HTTP/1.1 compliance |
| `benchmark.yml` | pull requests to `main`, nightly, manual | `Benchmarking` | HTTP throughput regression |
| `publish.yml` | `v*` tag push | `Publish` | Six-target static-library release |

Every workflow uses a GitHub environment so repository deployments and any
environment protection rules remain visible in GitHub.

## Lint

The lint job uses Zig 0.16.0 and runs:

```sh
zig fmt --check build.zig src examples tests
sh scripts/check_conventions.sh
```

The convention scanner checks project source filenames, Zig function and
variable names, and text files for prohibited emoji code points. Vendored
sources are excluded because their upstream conventions are preserved.

## Unit and build verification

The test job checks out all submodules and enters the Nix development shell.
It then runs:

```sh
zig build test --summary all
zig build test -Dsanitize=true -Doptimize=ReleaseSafe --summary all
zig build test-compile -Doptimize=ReleaseSafe --summary all
zig build fuzz --fuzz=100K -Doptimize=ReleaseSafe
zig build lib -Doptimize=ReleaseFast --summary all
```

Debug tests cover parser limits, malformed framing, partial reads and writes,
pool ownership, router method behavior, handshake validation, close codes,
fragmentation, streaming UTF-8, SIMD masking, pub/sub cleanup, and large
WebSocket messages. Code that allocates in tests uses leak-detecting test
allocators where applicable. Most hot-path tests use caller-provided fixed
storage and therefore allocate nothing to begin with.

ReleaseSafe compiles the same test graph with safety checks and optimization.
ReleaseFast proves the production static-library graph and all vendored C/C++
dependencies compile at the speed-oriented mode.

The sanitizer pass is native Linux only. The Nix shell supplies matching LLVM
sanitizer, glibc, and dynamic-linker paths. `build.zig` sets coherent RPATHs
and launches sanitizer executables through that matching loader, instruments
BoringSSL, lsquic, libdeflate, and the local C ABI shim with ASan/UBSan, enables
Zig's full C-UB checks, preserves frame pointers, and isolates the vendor cache.
CI enables ASan leak detection and makes both ASan and UBSan fail fast.

The test job also runs Zig's native fuzzer for 100,000 iterations over bounded
HTTP, HTTP/3 metadata, WebSocket extension, and zslay receive-state targets.
Seed corpora include valid, fragmented, malformed, and control-frame inputs.

## Autobahn WebSockets compliance

The Autobahn job builds `autobahn_server` in ReleaseSafe, then the Deno runner
starts it, waits until port 9001 is accepting connections, and launches the
digest-pinned
`crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`
container as a fuzzing client. The runner uses Deno's native process API and
has no runtime JavaScript dependencies. It always terminates the server, and
the container writes reports as the invoking POSIX user so repeated local runs
can replace them safely. The workflow uploads the complete HTML/JSON report
even when the gate fails.

The configuration selects groups 1-7, 9-13 with no exclusions. The report
gate permits `OK`, `INFORMATIONAL`, and `NON-STRICT` for both protocol and close
behavior; every other outcome fails the job.

The verified alpha baseline covers all 517 cases with 514 `OK` and 3
`INFORMATIONAL` results for both protocol and close behavior. RFC 7692 groups
12 and 13 pass through negotiated no-context-takeover per-message deflate; no
case is excluded or suppressed.

## h1spec compliance

The h1spec job builds the HTTP target in ReleaseSafe, waits for port 8000, and
runs the pinned repository submodule with Deno. On failure it uploads the
server log. Deterministic HTTP adversarial cases also remain in the Zig unit
suite so malformed-input coverage does not depend solely on an external tool.

## Cross-target checks

`flake.nix` defines native GNU or macOS packages and Linux musl packages. Its
Nixpkgs input is pinned to the 26.05 release so all four supported host systems,
including x86_64-darwin, remain evaluable. Checks compile tests for both native
and musl targets without attempting to execute foreign binaries. The publish
matrix runs natively on these GitHub-hosted architectures:

- x86_64-linux-gnu
- x86_64-linux-musl
- aarch64-linux-gnu
- aarch64-linux-musl
- x86_64-macos
- aarch64-macos

Windows is not supported in `1.0.0-alpha` and is intentionally absent from the
matrix.

The default build also compiles the bounded `http3_server` example, and inline
tests cover QPACK header validation and HTTP/3 framing. A cross-implementation
HTTP/3 compliance job is not yet part of the alpha gate.

## Performance regression

The benchmark workflow checks the pull request and its `main` base out into
separate directories, then builds each checkout from its own working directory
with ReleaseFast on the same Ubuntu runner. Candidate and baseline builds use
three bounded attempts with 10- and 20-second backoff so a transient immutable
dependency fetch does not discard the comparison. The workflow runs three
10-second `wrk` samples against each `hello_world` server, compares median
requests per second, and fails when the candidate falls below 90 percent of the
baseline. Raw latency and throughput reports are retained for 30 days. The
tolerance accounts for shared-runner variance; benchmark results are regression
evidence, not a portable capacity claim.

## Publishing

A `v*` tag starts two stages.

1. Each matrix job enters the `Publish` environment, checks that the tag
   is valid Semantic Versioning, equals `build.zig.zon`'s version, and has a
   matching `CHANGELOG.md` section, then builds the appropriate Nix package.
2. Each target is packaged as one `.tar.gz` containing the µWebZockets,
   BoringSSL, lsquic, and libdeflate static archives, metadata, and all relevant
   licenses.
3. The release job enters the `Publish` environment, requires exactly six
   archives, writes `SHA256SUMS`, extracts matching changelog notes, and creates
   or updates the GitHub release through `gh`.
4. Versions containing a hyphen, including `1.0.0-alpha`, are marked as
   prereleases. Stable versions are marked latest.

Release uploads are idempotent: rerunning a tag workflow updates notes and
replaces assets with the same names.

## Release checklist

- Update `build.zig.zon`, `flake.nix`, and `CHANGELOG.md` to the same version.
- Run formatting and convention checks.
- Run Debug tests and ReleaseSafe/ReleaseFast build checks.
- Run the native Linux ASan/UBSan/LeakSanitizer pass.
- Run Autobahn and h1spec compliance.
- Verify third-party revisions and licenses.
- Create and push `v<version>` only after the release commit is final.
- Review the `Publish` environment deployment and generated checksums.

The benchmark workflow is advisory for release tags because it runs on pull
requests and nightly rather than on `publish.yml`. Performance claims must cite
the retained configuration and raw results.
