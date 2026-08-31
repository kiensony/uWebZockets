const std = @import("std");

const SanitizerRunConfig = struct {
    enabled: bool,
    dynamic_linker: ?[]const u8,
    library_path: []const u8,
    shared_object: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_is_native = target.query.isNative();
    const optimize = b.standardOptimizeOption(.{});
    const sanitize = b.option(
        bool,
        "sanitize",
        "Enable native Linux ASan and UBSan instrumentation",
    ) orelse false;
    const sanitizer_lib_dir = b.option(
        []const u8,
        "sanitizer-lib-dir",
        "Directory containing the LLVM ASan runtime library",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIB_DIR");
    const sanitizer_libc_dir = b.option(
        []const u8,
        "sanitizer-libc-dir",
        "Directory containing the libc used by the sanitizer runtimes",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_LIBC_DIR");
    const sanitizer_dynamic_linker = b.option(
        []const u8,
        "sanitizer-dynamic-linker",
        "Dynamic linker used by native sanitizer executables",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_SANITIZER_DYNAMIC_LINKER");
    if (sanitize and (!target_is_native or target.result.os.tag != .linux)) {
        @panic("-Dsanitize=true requires a native Linux target");
    }
    if (sanitize and sanitizer_lib_dir == null) {
        @panic("-Dsanitize=true requires -Dsanitizer-lib-dir or UWEBZOCKETS_SANITIZER_LIB_DIR");
    }
    if (sanitize and (sanitizer_libc_dir == null) != (sanitizer_dynamic_linker == null)) {
        @panic("sanitizer libc directory and dynamic linker must be configured together");
    }
    const sanitizer_runtime_name = if (sanitize)
        switch (target.result.cpu.arch) {
            .x86_64 => "clang_rt.asan-x86_64",
            .aarch64 => "clang_rt.asan-aarch64",
            else => @panic("-Dsanitize=true supports x86_64 and aarch64"),
        }
    else
        "";
    const sanitizer_shared_object = if (sanitize)
        b.pathJoin(&.{
            sanitizer_lib_dir.?,
            b.fmt("lib{s}.so", .{sanitizer_runtime_name}),
        })
    else
        "";
    const sanitizer_library_path = if (!sanitize)
        ""
    else if (sanitizer_libc_dir) |libc_dir|
        b.fmt("{s}:{s}", .{ sanitizer_lib_dir.?, libc_dir })
    else
        sanitizer_lib_dir.?;
    const sanitizer_run_config: SanitizerRunConfig = .{
        .enabled = sanitize,
        .dynamic_linker = sanitizer_dynamic_linker,
        .library_path = sanitizer_library_path,
        .shared_object = sanitizer_shared_object,
    };
    const zlib_prefix = b.option(
        []const u8,
        "zlib-prefix",
        "Path containing zlib include/ and lib/ directories",
    ) orelse b.graph.environ_map.get("UWEBZOCKETS_ZLIB_PREFIX");
    const cmake_exe = b.option([]const u8, "cmake", "CMake executable") orelse "cmake";
    const ninja_exe = b.option([]const u8, "ninja", "Ninja executable") orelse "ninja";
    const c_compiler = b.option(
        []const u8,
        "c-compiler",
        "C compiler used for vendored dependencies",
    ) orelse b.pathFromRoot("zig-cc");
    const cxx_compiler = b.option(
        []const u8,
        "cxx-compiler",
        "C++ compiler used for vendored dependencies",
    ) orelse b.pathFromRoot("zig-c++");
    const asm_compiler = b.option(
        []const u8,
        "asm-compiler",
        "Assembler compiler used for vendored dependencies",
    ) orelse c_compiler;

    const mod = b.addModule("uWebZockets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (sanitize) false else null,
    });

    mod.link_libc = true;
    mod.link_libcpp = true;
    // --- Zig Dependencies ---
    const zslay_dep = b.dependency("zslay", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zslay", zslay_dep.module("zslay"));

    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("xev", libxev_dep.module("xev"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uWebZockets",
        .root_module = mod,
    });

    // --- Vendor Dependencies Orchestration ---
    const target_triple = target.result.zigTriple(b.allocator) catch @panic("out of memory");
    const target_key = b.fmt(
        "{s}-{s}-{s}",
        .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        },
    );
    const cmake_build_type = cmake_build_type_name(optimize);
    const vendor_build = if (sanitize)
        b.fmt(
            ".zig-cache/vendor-build/{s}-{s}-sanitize",
            .{ target_key, @tagName(optimize) },
        )
    else
        b.fmt(
            ".zig-cache/vendor-build/{s}-{s}",
            .{ target_key, @tagName(optimize) },
        );
    const cmake_c = b.fmt("-DCMAKE_C_COMPILER={s}", .{c_compiler});
    const cmake_cxx = b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cxx_compiler});
    const cmake_asm = b.fmt("-DCMAKE_ASM_COMPILER={s}", .{asm_compiler});
    const cmake_type = b.fmt("-DCMAKE_BUILD_TYPE={s}", .{cmake_build_type});
    const cmake_make = b.fmt("-DCMAKE_MAKE_PROGRAM={s}", .{ninja_exe});
    const sanitizer_link_flags = if (!sanitize)
        ""
    else if (sanitizer_libc_dir) |libc_dir|
        b.fmt(
            "-DCMAKE_EXE_LINKER_FLAGS=-L{s} -Wl,-rpath,{s} -Wl,-rpath,{s} -Wl,--no-as-needed -l{s}",
            .{
                sanitizer_lib_dir.?,
                sanitizer_lib_dir.?,
                libc_dir,
                sanitizer_runtime_name,
            },
        )
    else
        b.fmt(
            "-DCMAKE_EXE_LINKER_FLAGS=-L{s} -Wl,-rpath,{s} -Wl,--no-as-needed -l{s}",
            .{ sanitizer_lib_dir.?, sanitizer_lib_dir.?, sanitizer_runtime_name },
        );

    // 1. BoringSSL
    const bssl_src = "vendor/boringssl";
    const bssl_build_dir = b.pathJoin(&.{ vendor_build, "boringssl" });
    const bssl_cmake = b.addSystemCommand(&.{ cmake_exe, "-B", bssl_build_dir, "-S", bssl_src, "-GNinja", cmake_make, cmake_type, "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", cmake_c, cmake_cxx, cmake_asm });
    if (sanitize) {
        bssl_cmake.addArgs(&.{
            "-DASAN=ON",
            "-DUBSAN=ON",
            "-DUBSAN_RECOVER=OFF",
            sanitizer_link_flags,
        });
    }
    add_cross_cmake_args(b, bssl_cmake, target, target_is_native, sanitize);
    set_vendor_environment(b, bssl_cmake, target_is_native, target_triple);
    const bssl_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", bssl_build_dir, "ssl", "crypto" });
    set_vendor_environment(b, bssl_ninja, target_is_native, target_triple);
    bssl_ninja.step.dependOn(&bssl_cmake.step);

    // 2. lsquic
    const lsquic_src = "vendor/lsquic";
    const lsquic_build_dir = b.pathJoin(&.{ vendor_build, "lsquic" });
    const lsquic_cmake = b.addSystemCommand(&.{
        cmake_exe, "-B",       lsquic_build_dir,   "-S",                      lsquic_src,
        "-GNinja", cmake_make, cmake_type,         "-DBUILD_SHARED_LIBS=OFF", cmake_c,
        cmake_cxx, cmake_asm,  "-DLSQUIC_BIN=OFF", "-DLSQUIC_TESTS=OFF",      b.fmt("-DBORINGSSL_DIR={s}", .{b.pathFromRoot(bssl_src)}),
    });
    if (sanitize) {
        lsquic_cmake.addArgs(&.{
            "-DLSQUIC_ASAN=OFF",
            "-DCMAKE_C_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            "-DCMAKE_CXX_FLAGS=-fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer",
            sanitizer_link_flags,
        });
    }
    add_cross_cmake_args(b, lsquic_cmake, target, target_is_native, sanitize);
    set_vendor_environment(b, lsquic_cmake, target_is_native, target_triple);
    if (zlib_prefix) |prefix| {
        lsquic_cmake.addArg(b.fmt("-DZLIB_INCLUDE_DIR={s}/include", .{prefix}));
        lsquic_cmake.addArg(b.fmt("-DZLIB_LIB={s}/lib/libz.a", .{prefix}));
    }
    const lsquic_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", lsquic_build_dir });
    set_vendor_environment(b, lsquic_ninja, target_is_native, target_triple);
    lsquic_cmake.step.dependOn(&bssl_ninja.step);
    lsquic_ninja.step.dependOn(&lsquic_cmake.step);
    lsquic_ninja.step.dependOn(&bssl_ninja.step);

    // 3. libdeflate
    const deflate_src = "vendor/libdeflate";
    const deflate_build_dir = b.pathJoin(&.{ vendor_build, "libdeflate" });
    const deflate_c_flags = if (sanitize)
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI -fsanitize=address -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"
    else
        "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ -DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI";
    const deflate_cmake = b.addSystemCommand(&.{ cmake_exe, "-B", deflate_build_dir, "-S", deflate_src, "-GNinja", cmake_make, cmake_type, "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_TESTS=OFF", "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF", b.fmt("-DCMAKE_C_FLAGS={s}", .{deflate_c_flags}), cmake_c, cmake_cxx, cmake_asm });
    if (sanitize) deflate_cmake.addArg(sanitizer_link_flags);
    add_cross_cmake_args(b, deflate_cmake, target, target_is_native, sanitize);
    set_vendor_environment(b, deflate_cmake, target_is_native, target_triple);
    const deflate_ninja = b.addSystemCommand(&.{ ninja_exe, "-C", deflate_build_dir });
    set_vendor_environment(b, deflate_ninja, target_is_native, target_triple);
    deflate_ninja.step.dependOn(&deflate_cmake.step);

    // --- Linking to uWebZockets ---
    lib.step.dependOn(&bssl_ninja.step);
    lib.step.dependOn(&lsquic_ninja.step);
    lib.step.dependOn(&deflate_ninja.step);

    // Library paths (where the .a files are generated)
    mod.addLibraryPath(b.path(bssl_build_dir));
    mod.addLibraryPath(b.path(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic" })));
    mod.addLibraryPath(b.path(deflate_build_dir));
    if (zlib_prefix) |prefix| {
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    // LLVM ASan must precede libc and every instrumented dependency.
    if (sanitize) {
        const runtime_path: std.Build.LazyPath = .{ .cwd_relative = sanitizer_lib_dir.? };
        mod.addLibraryPath(runtime_path);
        mod.addRPath(runtime_path);
        if (sanitizer_libc_dir) |libc_dir| {
            const libc_path: std.Build.LazyPath = .{ .cwd_relative = libc_dir };
            mod.addLibraryPath(libc_path);
            mod.addRPath(libc_path);
        }
        mod.linkSystemLibrary(sanitizer_runtime_name, .{
            .needed = true,
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .no_fallback,
        });
    }

    // System libraries
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});
    mod.linkSystemLibrary("lsquic", .{});
    mod.linkSystemLibrary("deflate", .{});
    mod.linkSystemLibrary("z", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path(b.pathJoin(&.{ bssl_src, "include" })));
    translate_c.addIncludePath(b.path(b.pathJoin(&.{ lsquic_src, "include" })));
    translate_c.addIncludePath(b.path(deflate_src));
    if (zlib_prefix) |prefix| {
        translate_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }

    mod.addIncludePath(b.path(b.pathJoin(&.{ bssl_src, "include" })));
    mod.addIncludePath(b.path(b.pathJoin(&.{ lsquic_src, "include" })));
    mod.addIncludePath(b.path(deflate_src));
    if (zlib_prefix) |prefix| {
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }
    mod.addCSourceFile(.{
        .file = b.path("src/quic/lsquic_shim.c"),
        .flags = if (sanitize)
            &.{ "-std=c11", "-fsanitize=address", "-fsanitize=undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer" }
        else
            &.{"-std=c11"},
    });

    const c_module = translate_c.createModule();
    mod.addImport("c", c_module);

    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);
    const library_step = b.step("lib", "Build and install only the static library");
    library_step.dependOn(&install_lib.step);

    const install_ssl = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ bssl_build_dir, "libssl.a" })) },
        "libssl.a",
    );
    install_ssl.step.dependOn(&bssl_ninja.step);
    b.getInstallStep().dependOn(&install_ssl.step);
    library_step.dependOn(&install_ssl.step);

    const install_crypto = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ bssl_build_dir, "libcrypto.a" })) },
        "libcrypto.a",
    );
    install_crypto.step.dependOn(&bssl_ninja.step);
    b.getInstallStep().dependOn(&install_crypto.step);
    library_step.dependOn(&install_crypto.step);

    const install_lsquic = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ lsquic_build_dir, "src", "liblsquic", "liblsquic.a" })) },
        "liblsquic.a",
    );
    install_lsquic.step.dependOn(&lsquic_ninja.step);
    b.getInstallStep().dependOn(&install_lsquic.step);
    library_step.dependOn(&install_lsquic.step);

    const install_deflate = b.addInstallLibFile(
        .{ .cwd_relative = b.pathFromRoot(b.pathJoin(&.{ deflate_build_dir, "libdeflate.a" })) },
        "libdeflate.a",
    );
    install_deflate.step.dependOn(&deflate_ninja.step);
    b.getInstallStep().dependOn(&install_deflate.step);
    library_step.dependOn(&install_deflate.step);

    // --- Examples ---
    const hello_world_exe = b.addExecutable(.{
        .name = "hello_world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_world.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello_world_exe.root_module.addImport("uWebZockets", mod);
    hello_world_exe.step.dependOn(&bssl_ninja.step);
    hello_world_exe.step.dependOn(&lsquic_ninja.step);
    hello_world_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(hello_world_exe);

    const run_hello_world = add_run_artifact(b, hello_world_exe, sanitizer_run_config);
    const hello_world_step = b.step("hello_world", "Run the hello_world example");
    hello_world_step.dependOn(&run_hello_world.step);

    const chat_server_exe = b.addExecutable(.{
        .name = "chat_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chat_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    chat_server_exe.root_module.addImport("uWebZockets", mod);
    chat_server_exe.step.dependOn(&bssl_ninja.step);
    chat_server_exe.step.dependOn(&lsquic_ninja.step);
    chat_server_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(chat_server_exe);

    const run_chat_server = add_run_artifact(b, chat_server_exe, sanitizer_run_config);
    const chat_server_step = b.step("chat_server", "Run the chat_server example");
    chat_server_step.dependOn(&run_chat_server.step);

    const http3_server_exe = b.addExecutable(.{
        .name = "http3_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http3_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http3_server_exe.root_module.addImport("uWebZockets", mod);
    http3_server_exe.step.dependOn(&bssl_ninja.step);
    http3_server_exe.step.dependOn(&lsquic_ninja.step);
    http3_server_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(http3_server_exe);
    const run_http3_server = add_run_artifact(b, http3_server_exe, sanitizer_run_config);
    const http3_server_step = b.step("http3_server", "Run the HTTP/3 example server");
    http3_server_step.dependOn(&run_http3_server.step);

    const h1spec_exe = b.addExecutable(.{
        .name = "h1spec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/h1spec/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    h1spec_exe.root_module.addImport("uWebZockets", mod);
    h1spec_exe.step.dependOn(&bssl_ninja.step);
    h1spec_exe.step.dependOn(&lsquic_ninja.step);
    h1spec_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(h1spec_exe);

    const run_h1spec = add_run_artifact(b, h1spec_exe, sanitizer_run_config);
    const h1spec_step = b.step("h1spec", "Run the h1spec compliance server");
    h1spec_step.dependOn(&run_h1spec.step);

    const autobahn_exe = b.addExecutable(.{
        .name = "autobahn_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/autobahn/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    autobahn_exe.root_module.addImport("uWebZockets", mod);
    autobahn_exe.step.dependOn(&bssl_ninja.step);
    autobahn_exe.step.dependOn(&lsquic_ninja.step);
    autobahn_exe.step.dependOn(&deflate_ninja.step);
    b.installArtifact(autobahn_exe);

    const run_autobahn = add_run_artifact(b, autobahn_exe, sanitizer_run_config);
    const autobahn_step = b.step("autobahn", "Run the Autobahn compliance server");
    autobahn_step.dependOn(&run_autobahn.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.step.dependOn(&bssl_ninja.step);
    mod_tests.step.dependOn(&lsquic_ninja.step);
    mod_tests.step.dependOn(&deflate_ninja.step);
    const run_mod_tests = add_run_artifact(b, mod_tests, sanitizer_run_config);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });
    lib_tests.step.dependOn(&bssl_ninja.step);
    lib_tests.step.dependOn(&lsquic_ninja.step);
    lib_tests.step.dependOn(&deflate_ninja.step);
    const run_lib_tests = add_run_artifact(b, lib_tests, sanitizer_run_config);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_lib_tests.step);

    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&mod_tests.step);
    test_compile_step.dependOn(&lib_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = if (sanitize) .full else null,
        .omit_frame_pointer = if (sanitize) false else null,
    });
    const fuzz_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/http/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_handshake_mod = b.createModule(.{
        .root_source_file = b.path("src/ws/handshake.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_quic_validation_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("http_parser", fuzz_parser_mod);
    fuzz_mod.addImport("ws_handshake", fuzz_handshake_mod);
    fuzz_mod.addImport("quic_validation", fuzz_quic_validation_mod);
    fuzz_mod.addImport("zslay", zslay_dep.module("zslay"));

    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });
    const run_fuzz_tests = add_run_artifact(b, fuzz_tests, sanitizer_run_config);
    const fuzz_step = b.step("fuzz", "Fuzz HTTP and WebSocket parsers");
    fuzz_step.dependOn(&run_fuzz_tests.step);
}

fn cmake_build_type_name(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast, .ReleaseSmall => "Release",
    };
}

fn add_cross_cmake_args(
    b: *std.Build,
    command: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
    target_is_native: bool,
    sanitize: bool,
) void {
    if (target_is_native) {
        if (sanitize) command.addArg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
        return;
    }

    const system_name: []const u8 = switch (target.result.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .windows => "Windows",
        else => return,
    };
    const processor: []const u8 = switch (target.result.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm",
        .aarch64 => "aarch64",
        else => @tagName(target.result.cpu.arch),
    };

    command.addArg(b.fmt("-DCMAKE_SYSTEM_NAME={s}", .{system_name}));
    command.addArg(b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{processor}));
    command.addArg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
}

fn set_vendor_environment(
    b: *std.Build,
    command: *std.Build.Step.Run,
    target_is_native: bool,
    target_triple: []const u8,
) void {
    command.setEnvironmentVariable("UWEBZOCKETS_ZIG", b.graph.zig_exe);
    if (!target_is_native) {
        command.setEnvironmentVariable("UWEBZOCKETS_TARGET", target_triple);
    }
}

fn add_run_artifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    sanitizer: SanitizerRunConfig,
) *std.Build.Step.Run {
    if (!sanitizer.enabled) return b.addRunArtifact(artifact);

    const dynamic_linker = sanitizer.dynamic_linker orelse {
        const command = b.addRunArtifact(artifact);
        command.setEnvironmentVariable("LD_PRELOAD", sanitizer.shared_object);
        return command;
    };
    if (artifact.kind == .@"test") {
        artifact.setExecCmd(&.{
            dynamic_linker,
            "--library-path",
            sanitizer.library_path,
            "--preload",
            sanitizer.shared_object,
            null,
        });
        return b.addRunArtifact(artifact);
    }

    const command = b.addSystemCommand(&.{
        dynamic_linker,
        "--library-path",
        sanitizer.library_path,
        "--preload",
        sanitizer.shared_object,
    });
    command.addArtifactArg(artifact);
    return command;
}
