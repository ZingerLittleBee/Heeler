#!/usr/bin/env bash
# Builds libheeler_jni.so for Android.
#
# On Linux (CI): runs Zig directly. On macOS: Zig 0.15.2 cannot link its own
# build runner against the macOS 26 SDK, so the build runs inside a Linux
# container (docker/OrbStack) with this directory and the NDK sysroot mounted.
# Only NDK sysroot *files* are used (headers + stub libs — host-independent);
# Zig compiles and links with its own toolchain.
#
# Usage: build-native.sh [zig-build-args...]
#   default args: jni -Doptimize=ReleaseSmall   (all four ABIs, copied to
#   ../app/src/main/jniLibs/<abi>/libheeler_jni.so)
# Env:
#   ZIG_VERSION   (default 0.15.2 — must match the ghostty pin)
#   ANDROID_NDK_HOME / ANDROID_NDK_ROOT (required)

set -euo pipefail
cd "$(dirname "$0")"

ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[ -n "$NDK" ] || { echo "error: set ANDROID_NDK_HOME" >&2; exit 1; }
ARGS=("$@")
[ ${#ARGS[@]} -gt 0 ] || ARGS=(jni -Doptimize=ReleaseSmall)

if [ "$(uname -s)" = "Linux" ]; then
    if ! command -v zig >/dev/null || [ "$(zig version)" != "$ZIG_VERSION" ]; then
        arch="$(uname -m)"
        case "$arch" in aarch64|arm64) zarch=aarch64 ;; *) zarch=x86_64 ;; esac
        tool="$HOME/.cache/heeler-zig/zig-${zarch}-linux-${ZIG_VERSION}"
        if [ ! -x "$tool/zig" ]; then
            mkdir -p "$HOME/.cache/heeler-zig"
            curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
                | tar -xJ -C "$HOME/.cache/heeler-zig"
        fi
        export PATH="$tool:$PATH"
    fi

    # Some dependency build scripts (openssl-zig) hardcode
    # `toolchains/llvm/prebuilt/linux-<arch>` while a mounted macOS NDK ships
    # `darwin-x86_64`. The prebuilt sysroot files are host-independent, so
    # expose an NDK view that answers to every expected host name.
    real_prebuilt="$(find "$NDK/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -1)"
    want_prebuilt="$NDK/toolchains/llvm/prebuilt/linux-$(uname -m | sed 's/arm64/aarch64/')"
    if [ -n "$real_prebuilt" ] && [ ! -e "$want_prebuilt" ]; then
        shim="$HOME/.cache/heeler-ndk-shim"
        rm -rf "$shim" && mkdir -p "$shim/toolchains/llvm/prebuilt"
        for entry in "$NDK"/*; do
            [ "$(basename "$entry")" = "toolchains" ] || ln -s "$entry" "$shim/$(basename "$entry")"
        done
        for entry in "$NDK"/toolchains/*; do
            [ "$(basename "$entry")" = "llvm" ] || ln -s "$entry" "$shim/toolchains/$(basename "$entry")"
        done
        for entry in "$NDK"/toolchains/llvm/*; do
            [ "$(basename "$entry")" = "prebuilt" ] || ln -s "$entry" "$shim/toolchains/llvm/$(basename "$entry")"
        done
        for host in linux-aarch64 linux-x86_64 "$(basename "$real_prebuilt")"; do
            [ -e "$shim/toolchains/llvm/prebuilt/$host" ] || ln -s "$real_prebuilt" "$shim/toolchains/llvm/prebuilt/$host"
        done
        export ANDROID_NDK_HOME="$shim" ANDROID_NDK_ROOT="$shim"
    fi
    exec zig build "${ARGS[@]}"
fi

# macOS: delegate into a Linux container. Zig's caches must live on a
# Linux-native filesystem (its cache locking misbehaves on virtiofs bind
# mounts), so they go in a named docker volume; likewise the build tree's
# .zig-cache is redirected there via ZIG_LOCAL_CACHE_DIR.
command -v docker >/dev/null || { echo "error: docker required on macOS (OrbStack works)" >&2; exit 1; }
exec docker run --rm --ulimit nofile=65536:65536 \
    -v "$PWD/..":/work \
    -v "$NDK":/ndk:ro \
    -v heeler-zig-cache:/root/.cache \
    -w /work/native \
    -e ANDROID_NDK_HOME=/ndk \
    -e ZIG_VERSION="$ZIG_VERSION" \
    -e ZIG_LOCAL_CACHE_DIR=/root/.cache/heeler-local-zig-cache \
    -e ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig \
    ubuntu:24.04 \
    bash -c 'apt-get -qq update >/dev/null && apt-get -qq install -y curl xz-utils >/dev/null && exec ./build-native.sh '"${ARGS[*]}"
