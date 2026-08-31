#!/usr/bin/env bash
#
# build-ssh.sh — Build libssh2 + mbedTLS as a single static library for every
# Apple platform (iOS device arm64, iOS simulator arm64+x86_64, macOS arm64),
# then package them into ONE Libssh2.xcframework that a SwiftPM binaryTarget can
# consume via the CLibssh2 module.
#
# THE CRYPTO BACKEND IS mbedTLS — NOT OpenSSL. libssh2 is configured with
# CRYPTO_BACKEND=mbedTLS (the PUBLIC api headers are self-contained, so the
# consumer only needs libssh2.h / libssh2_publickey.h / libssh2_sftp.h, but the
# mbedTLS headers are staged alongside so the module can resolve any types it
# needs if a future consumer opts in).
#
# WHY ONE MERGED XCFRAMEWORK: same rationale as Binary/C-drivers/build-c-drivers.sh —
# a single XCFramework with ONE module.modulemap (declaring module CLibssh2) is
# the layout SwiftPM 6.4 can host as a binaryTarget without the
# Build/Products/<arch>/include/module.modulemap collision.
#
# PREREQUISITES:
#   - Xcode 16+ (xcrun --sdk iphoneos / iphonesimulator / macosx)
#   - cmake (brew install cmake)
#   - git, lipo, libtool, ar (bundled with Xcode / macOS)
#   - Internet (sources git-cloned once, then cached in build/.cache)
#
# USAGE:
#   ./build-ssh.sh               # build + merge all slices, write Libssh2.xcframework
#   ./build-ssh.sh clean         # remove build/ scratch + the .xcframework
#
# OUTPUT (committed):
#   Binary/SSH-libssh2/Libssh2.xcframework   -> consumed via .binaryTarget in Package.swift
#   Binary/SSH-libssh2/build/                -> scratch (cached sources, per-slice .a, headers)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX_DIR="$REPO_ROOT/Binary/SSH-libssh2"
BUILD_DIR="$PREFIX_DIR/build"
CACHE_DIR="$BUILD_DIR/.cache"
mkdir -p "$PREFIX_DIR" "$BUILD_DIR" "$CACHE_DIR"

LIBSSH2_VERSION="1.11.1"
MBEDTLS_VERSION="3.6.2"

# macOS Finder drops read-only .DS_Store files that make `rm -rf` fail
# ("Directory not empty"). Purge them before every destructive rm and chmod the
# tree writable so read-only .a files (from prior runs) don't block it.
rmds() { find "$1" -name .DS_Store -delete 2>/dev/null || true; }
rmr()  { for p in "$@"; do
           [ -e "$p" ] || continue
           rmds "$p" 2>/dev/null
           chmod -R u+w "$p" 2>/dev/null || true
           rm -rf "$p" 2>/dev/null || true
         done; }

# --- Apple platform / SDK config -------------------------------------------------
CC="$(xcrun --find clang)"
AR="$(xcrun --find ar)"

IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

IOS_DEPLOY="13.0"   # iOS device / macOS floor for the transport layer
SIM_DEPLOY="15.0"   # simulator (matches other Shell binary slices)
MACOS_DEPLOY="14.0"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- fetch / cache sources -------------------------------------------------------
# mbedTLS 3.6.x requires its `framework` submodule (mbedtls-framework), which a
# plain source tarball does NOT carry. git-clone with --recurse-submodules at the
# exact tag is the reproducible way to get a correct, matching framework commit.
fetch_sources() {
  info "fetching libssh2 $LIBSSH2_VERSION"
  if [ ! -d "$BUILD_DIR/libssh2" ]; then
    git clone --depth 1 --branch "libssh2-$LIBSSH2_VERSION" \
      https://github.com/libssh2/libssh2 "$BUILD_DIR/libssh2" >/dev/null 2>&1 \
      || die "git clone libssh2 failed"
  fi

  info "fetching mbedTLS $MBEDTLS_VERSION (with framework submodule)"
  if [ ! -d "$BUILD_DIR/mbedtls" ]; then
    git clone --depth 1 --branch "mbedtls-$MBEDTLS_VERSION" \
      --recurse-submodules --shallow-submodules \
      https://github.com/Mbed-TLS/mbedtls "$BUILD_DIR/mbedtls" >/dev/null 2>&1 \
      || die "git clone mbedTLS failed"
    [ -f "$BUILD_DIR/mbedtls/framework/CMakeLists.txt" ] \
      || die "mbedTLS framework submodule missing — re-run clone with --recurse-submodules"
  fi
}

# --- build one mbedTLS slice -----------------------------------------------------
# $1=name e.g. ios-device | sim-arm64 | sim-x86_64 | macos
# $2=CMAKE_SYSTEM_NAME (iOS or empty for host macOS)
# $3=sysroot   $4=osx-arch   $5=deployment target
build_mbedtls_slice() {
  local name="$1" sys_name="$2" sysroot="$3" arch="$4" deploy="$5"
  local bd="$BUILD_DIR/slices/mbedtls/$name"
  info "mbedTLS slice: $name ($arch)"
  rmr "$bd"
  local -a cfg=(-S "$BUILD_DIR/mbedtls" -B "$bd" -DCMAKE_BUILD_TYPE=Release
    -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUNSAFE_BUILD=OFF -DMBEDTLS_FATAL_WARNINGS=OFF
    -DCMAKE_C_COMPILER="$CC")
  if [ -n "$sys_name" ]; then
    cfg+=(-DCMAKE_SYSTEM_NAME="$sys_name" -DCMAKE_OSX_SYSROOT="$sysroot")
  fi
  cfg+=(-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy")
  cmake "${cfg[@]}" >/dev/null 2>&1 || die "mbedTLS configure $name"
  cmake --build "$bd" -j8 --target mbedcrypto mbedx509 mbedtls >/dev/null 2>&1 \
    || die "mbedTLS build $name"
  cmake --install "$bd" --prefix "$bd/install" >/dev/null 2>&1 || die "mbedTLS install $name"
}

# --- build one libssh2 slice against the matching mbedTLS slice -------------------
# $1=name   $2=sys_name (iOS or empty)   $3=sysroot   $4=arch   $5=deploy
build_libssh2_slice() {
  local name="$1" sys_name="$2" sysroot="$3" arch="$4" deploy="$5"
  local mt="$BUILD_DIR/slices/mbedtls/$name/install"
  [ -f "$mt/lib/libmbedcrypto.a" ] || die "missing mbedTLS slice for $name; build mbedTLS first"
  local bd="$BUILD_DIR/slices/libssh2/$name"
  info "libssh2 slice: $name ($arch, mbedTLS)"
  rmr "$bd"
  local -a cfg=(-S "$BUILD_DIR/libssh2" -B "$bd" -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
    -DCRYPTO_BACKEND=mbedTLS
    -DMBEDTLS_INCLUDE_DIR="$mt/include"
    -DMBEDCRYPTO_LIBRARY="$mt/lib/libmbedcrypto.a"
    -DCMAKE_C_COMPILER="$CC")
  if [ -n "$sys_name" ]; then
    cfg+=(-DCMAKE_SYSTEM_NAME="$sys_name" -DCMAKE_OSX_SYSROOT="$sysroot")
  fi
  cfg+=(-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy")
  cmake "${cfg[@]}" >/dev/null 2>&1 || die "libssh2 configure $name"
  cmake --build "$bd" -j8 >/dev/null 2>&1 || die "libssh2 build $name"

  # Sanity: the slice must be the requested arch and must NOT reference OpenSSL.
  local wants_arch="$arch"
  local got="$(lipo -info "$bd/src/libssh2.a" | sed 's/.*are: //')"
  case "$got" in *"$wants_arch"*) : ;; *) die "libssh2 $name arch mismatch: got '$got' expected $wants_arch";; esac
  if nm "$bd/src/libssh2.a" 2>/dev/null | grep -qiE "OPENSSL|SSL_"; then
    die "libssh2 $name references OpenSSL — mbedTLS backend not honored"
  fi

  # Merge libssh2 + mbedTLS (mbedcrypto + its x25519/P-256 helpers) into ONE
  # self-contained static archive per slice, so the consumer binaryTarget needs
  # no separate crypto library.
  libtool -static -o "$bd/libssh2_all.a" \
    "$bd/src/libssh2.a" \
    "$mt/lib/libmbedcrypto.a" \
    "$mt/lib/libmbedx509.a" \
    "$mt/lib/libmbedtls.a" \
    "$mt/lib/libeverest.a" \
    "$mt/lib/libp256m.a" 2>/dev/null \
    || die "libssh2+mbedTLS merge $name"
}

# --- stage unified headers + ONE module.modulemap -------------------------------
stage_headers() {
  local hdr="$BUILD_DIR/headers"
  info "staging headers + module.modulemap"
  rmr "$hdr"; mkdir -p "$hdr"
  # libssh2 public API headers (self-contained; they expose the CLibssh2 module)
  cp "$BUILD_DIR/libssh2/include"/libssh2.h \
     "$BUILD_DIR/libssh2/include"/libssh2_publickey.h \
     "$BUILD_DIR/libssh2/include"/libssh2_sftp.h "$hdr/"
  # mbedTLS headers (staged so the module can resolve any needed types; the
  # public libssh2 API does not require them at consume time, but keeping them
  # makes the module self-sufficient).
  cp -R "$BUILD_DIR/mbedtls/include/mbedtls" "$BUILD_DIR/mbedtls/include/psa" "$hdr/"
  cat > "$hdr/module.modulemap" <<'EOF'
module CLibssh2 [system] {
    header "libssh2.h"
    export *
}
EOF
}

# --- package the merged per-slice archives into ONE XCFramework ------------------
package_xcframework() {
  local out="$PREFIX_DIR/Libssh2.xcframework"
  local hdr="$BUILD_DIR/headers"
  local merged="$BUILD_DIR/merge"
  info "packaging Libssh2.xcframework"
  rmr "$merged" "$out"; mkdir -p "$merged"

  # libssh2 (and the merged crypto) is already the complete slice archive.
  local dev="$BUILD_DIR/slices/libssh2/ios-device/libssh2_all.a"
  local sim="$merged/libssh2_sim.a"
  local mac="$BUILD_DIR/slices/libssh2/macos/libssh2_all.a"

  # lipo-merge the two simulator slices into one fat archive.
  lipo -create -output "$sim" \
    "$BUILD_DIR/slices/libssh2/sim-arm64/libssh2_all.a" \
    "$BUILD_DIR/slices/libssh2/sim-x86_64/libssh2_all.a" \
    || die "lipo merge simulator slices"

  xcodebuild -create-xcframework \
    -library "$dev" -headers "$hdr" \
    -library "$sim" -headers "$hdr" \
    -library "$mac" -headers "$hdr" \
    -output "$out" 2>&1 | tail -2
  info "Libssh2.xcframework written"
}

# --- main -----------------------------------------------------------------------
main() {
  local want="${1:-all}"
  case "$want" in
    clean)
      rmr "$PREFIX_DIR/Libssh2.xcframework" "$BUILD_DIR"; info "cleaned";;
    all)
      fetch_sources
      build_mbedtls_slice ios-device   iOS "$IPHONEOS_SDK"   arm64 "$IOS_DEPLOY"
      build_mbedtls_slice sim-arm64    iOS "$IPHONESIM_SDK"  arm64 "$SIM_DEPLOY"
      build_mbedtls_slice sim-x86_64   iOS "$IPHONESIM_SDK"  x86_64 "$SIM_DEPLOY"
      build_mbedtls_slice macos        ""  "$MACOS_SDK"      arm64 "$MACOS_DEPLOY"

      build_libssh2_slice ios-device   iOS "$IPHONEOS_SDK"   arm64 "$IOS_DEPLOY"
      build_libssh2_slice sim-arm64    iOS "$IPHONESIM_SDK"  arm64 "$SIM_DEPLOY"
      build_libssh2_slice sim-x86_64   iOS "$IPHONESIM_SDK"  x86_64 "$SIM_DEPLOY"
      build_libssh2_slice macos        ""  "$MACOS_SDK"      arm64 "$MACOS_DEPLOY"

      stage_headers
      package_xcframework;;
    *)
      die "unknown '$want' (all|clean)";;
  esac
  info "done. XCFramework: $PREFIX_DIR/Libssh2.xcframework"
}
main "$@"
