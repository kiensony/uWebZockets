---
name: uwebzockets-workflow
description: Master high-performance workflow integrating all specialized skills for the µWebZockets project.
---

# µWebZockets High-Performance Master Workflow

This document outlines the unified workflow combining all specialized skills available in `.agents/skills/*` to build a blazingly fast, zero-allocation WebSocket/HTTP library.

## 1. Mindset & Optimization (`ponytail`, `caveman`, `dod`, `functional-programming-fundamentals`)
- **Functional & Pure (No OOP)**: Zero Object-Oriented Programming allowed. Emphasize pure functions, explicit state passing, and immutability where it doesn't cost performance. Never bind state and behavior into "classes".
- **Data-Oriented Design (`dod`)**: Performance starts with memory. Group data by access pattern, not by object. Use Struct of Arrays (SoA) to maximize CPU cache utilization and minimize pointer chasing. Functional pipelines must operate over these DOD-optimized structures without allocating.
- **Ponytail Mode (`ponytail`)**: Embrace extreme laziness and simplicity. Ask "Do we even need this?" before writing any code. Prefer native Zig language features over dependencies. Keep solutions minimal.
- **Caveman Mode (`caveman`)**: Keep communication dense and concise. High signal-to-noise ratio in documentation, commit messages, and PRs.

## 2. Core Architecture (`zig-0.16`)
- **Zero-Allocation Hot Paths**: The request/response cycle must not allocate memory dynamically. Allocate contiguous fixed-capacity connection, message, and output storage during application startup and reuse it for every callback.
- **Event Loop & IO**: Utilize `mitchellh/libxev` for a robust, cross-platform, non-blocking event loop.
- **Parsing**: Leverage the pinned `farbenbuilds/zslay` 0.1.5 frame state
  machine and keep µWebZockets' handshake, message, and UTF-8 limits explicit.
- **Zig 0.16 Primitives (`zig-0.16`)**: Strictly adhere to the latest `std.io` patterns and deprecations.

## 3. Implementation & Build (`zig-best-practices`, `zig-comptime`, `zig-build-system`)
- **Idiomatic Zig (`zig-best-practices`)**: Follow standard Zig naming, error handling (native error sets), and explicit memory management. Combine with our Linux-style coding conventions (early returns, minimal indentation, and strictly Linux file naming `snake_case`).
- **Compile-Time Evaluation (`zig-comptime`)**: Use `comptime` for application capacities, storage sizing, and specialization. Keep route lookup in the fixed-capacity runtime radix structure so applications can register routes during startup.
- **Build Infrastructure (`zig-build-system`, `nix-best-practices`)**: Write lean `build.zig` scripts. Utilize Nix for reproducible developer environments to ensure identical cross-platform builds.

## 4. FFI, C/C++ Ecosystem & Cross-Compilation (`zig-cinterop`, `zig-cross`, `cmake`, `ninja`, `gcc`, `c-systems-programming`, `cpp-coding-standards`, `cpp-modules`)
- **C Interoperability (`zig-cinterop`)**: Integrate `BoringSSL`, `lsquic`, and `libdeflate`. Prefer using `translate-c` to convert headers to Zig for improved type safety and faster compilation over raw `@cImport`.
- **C/C++ Build Orchestration (`cmake`, `ninja`, `gcc`)**: Utilize CMake and Ninja for building complex C/C++ dependencies (like BoringSSL and lsquic) natively from `build.zig`, ensuring correct GCC flags and cross-platform compatibility.
- **Low-Level C/C++ (`c-systems-programming`, `cpp-coding-standards`, `cpp-modules`)**: Apply strict modern C/C++ standards when modifying or wrapping any native code, utilizing C++20 modules where applicable, and understanding low-level OS interaction.
- **Targeting (`zig-cross`)**: Ensure the library can cross-compile flawlessly to diverse target architectures using Zig's native cross-compilation toolchain.

## 5. Debugging & QA (`zig-testing`, `zig-debugging`, `zig-compiler`)
- **Zero-Leak Testing (`zig-testing`)**: Use `std.testing.allocator` whenever the code under test owns allocations. Exercise fixed-buffer paths with caller-owned storage, malformed-input corpora, Autobahn, and h1spec compliance tests.
- **Compiler Optimization (`zig-compiler`)**: Distinguish between `ReleaseFast` and `ReleaseSafe`. Always ensure safe runtime checks during development, optimizing to `ReleaseFast` only for proven hot paths.
