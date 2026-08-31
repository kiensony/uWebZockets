{
  description = "µWebZockets Zig WebSocket and HTTP server library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zon2nix.url = "github:jcollie/zon2nix";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        lib = pkgs.lib;
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        pkgsMusl =
          if isLinux
          then pkgs.pkgsMusl
          else null;
        nativeTarget =
          if isLinux
          then "${lib.removeSuffix "-linux" system}-linux-gnu"
          else lib.replaceStrings ["-darwin"] ["-macos"] system;
        muslTarget =
          if isLinux
          then "${lib.removeSuffix "-linux" system}-linux-musl"
          else null;

        zig = inputs.zig-overlay.packages.${system}."0.16.0" or pkgs.zig;
        zon2nixPackage = inputs.zon2nix.packages.${system}.zon2nix;
        zigPackages = pkgs.callPackage ./build.zig.zon.nix {
          zig_0_15 = zig;
        };

        source = lib.cleanSourceWith {
          src = self;
          filter = path: type: let
            name = baseNameOf path;
          in
            !lib.elem name [
              ".git"
              ".zig-cache"
              "result"
              "zig-out"
              "zig-pkg"
            ];
        };

        nativeBuildInputs = [
          zig
          pkgs.cmake
          pkgs.ninja
          pkgs.pkg-config
          pkgs.go
          pkgs.perl
          pkgs.python3
        ];

        seedZigCache = ''
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"
          cp -RL ${zigPackages}/. "$ZIG_GLOBAL_CACHE_DIR/p/"
          chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
        '';

        mkPackage = packagePkgs: targetTriple: let
          zlibPrefix = packagePkgs.symlinkJoin {
            name = "uwebzockets-zlib";
            paths = [
              packagePkgs.zlib.dev
              packagePkgs.zlib.static
            ];
          };
        in
          packagePkgs.stdenv.mkDerivation {
            pname = "uwebzockets";
            version = "1.0.0-alpha";
            src = source;
            strictDeps = true;
            inherit nativeBuildInputs;
            buildInputs = [
              packagePkgs.zlib.dev
              packagePkgs.zlib.static
            ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              ${seedZigCache}
              zig build lib \
                -Doptimize=ReleaseFast \
                -Dtarget=${targetTriple} \
                -Dzlib-prefix=${zlibPrefix} \
                --prefix "$out"
              runHook postBuild
            '';
            dontInstall = true;
          };

        mkCompileCheck = packagePkgs: targetTriple: let
          zlibPrefix = packagePkgs.symlinkJoin {
            name = "uwebzockets-zlib-check";
            paths = [
              packagePkgs.zlib.dev
              packagePkgs.zlib.static
            ];
          };
        in
          packagePkgs.stdenv.mkDerivation {
            pname = "uwebzockets-compile-tests";
            version = "1.0.0-alpha";
            src = source;
            strictDeps = true;
            inherit nativeBuildInputs;
            buildInputs = [
              packagePkgs.zlib.dev
              packagePkgs.zlib.static
            ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              ${seedZigCache}
              zig build test-compile \
                -Doptimize=ReleaseSafe \
                -Dtarget=${targetTriple} \
                -Dzlib-prefix=${zlibPrefix} \
                --prefix "$out"
              runHook postBuild
            '';
            installPhase = ''
              touch "$out"
            '';
          };

        mkDevShell = packagePkgs: let
          llvmCompilerRt = packagePkgs.llvmPackages_21.compiler-rt;
          zlibPrefix = packagePkgs.symlinkJoin {
            name = "uwebzockets-zlib-dev";
            paths = [
              packagePkgs.zlib.dev
              packagePkgs.zlib.static
            ];
          };
          supportsSanitizers =
            isLinux && packagePkgs.stdenv.hostPlatform.isGnu;
        in
          packagePkgs.mkShell (
            {
              packages = [
                zig
                packagePkgs.zls
                zon2nixPackage
                pkgs.cmake
                pkgs.ninja
                pkgs.pkg-config
                pkgs.go
                pkgs.perl
                pkgs.python3
                packagePkgs.gnutar
                packagePkgs.gzip
                packagePkgs.xz
                packagePkgs.zlib
                packagePkgs.wrk
              ]
              ++ lib.optional supportsSanitizers llvmCompilerRt;
              UWEBZOCKETS_ZLIB_PREFIX = zlibPrefix;
            }
            // lib.optionalAttrs supportsSanitizers {
              UWEBZOCKETS_SANITIZER_DYNAMIC_LINKER =
                packagePkgs.stdenv.cc.bintools.dynamicLinker;
              UWEBZOCKETS_SANITIZER_LIB_DIR =
                "${lib.getLib llvmCompilerRt}/lib/linux";
              UWEBZOCKETS_SANITIZER_LIBC_DIR =
                "${lib.getLib packagePkgs.stdenv.cc.libc}/lib";
            }
          );
      in {
        formatter = pkgs.alejandra;

        packages =
          {
            default = mkPackage pkgs nativeTarget;
            release = mkPackage pkgs nativeTarget;
          }
          // lib.optionalAttrs isLinux {
            musl = mkPackage pkgsMusl muslTarget;
          };

        checks =
          {
            compile-tests = mkCompileCheck pkgs nativeTarget;
          }
          // lib.optionalAttrs isLinux {
            compile-tests-musl = mkCompileCheck pkgsMusl muslTarget;
          };

        devShells =
          {
            default = mkDevShell pkgs;
          }
          // lib.optionalAttrs isLinux {
            musl = mkDevShell pkgsMusl;
          };
      };
    };
}
