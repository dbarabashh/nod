#!/usr/bin/env bash
#
# Builds Vendor/sherpa-onnx.xcframework — the on-device Silero VAD dependency.
#
# Why a script instead of a committed binary or an SPM package:
#   - sherpa-onnx has no Swift Package Manager support (no Package.swift).
#   - The universal (arm64 + x86_64) static lib with onnxruntime bundled is
#     ~168 MB and contains a file >100 MB, which GitHub refuses to store. So we
#     keep it out of git (see .gitignore) and regenerate it here, pinned by
#     version + checksum for reproducibility.
#
# The xcframework is BUILD-TIME only: it is statically linked into the Nod
# binary, so nothing produced here ships to end users.
#
# Usage:  ./scripts/fetch-vad-xcframework.sh [--force]
#
# To bump sherpa-onnx: update SHERPA_VERSION + SHA256 below, run with --force.

set -euo pipefail

SHERPA_VERSION="1.13.2"
TARBALL="sherpa-onnx-v${SHERPA_VERSION}-osx-universal2-static.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${TARBALL}"
SHA256="11c56c6577812e30ad3422a826a07f2a4a04b20d926af45b17e7dd9af99dd035"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/Vendor/sherpa-onnx.xcframework"

if [ -d "$DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "==> VAD xcframework already present ($DEST) — skipping (use --force to rebuild)"
  exit 0
fi

echo "==> Building sherpa-onnx VAD xcframework v${SHERPA_VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "    downloading ${TARBALL} (~425 MB)…"
curl -fsSL -o pkg.tar.bz2 "$URL"

echo "    verifying checksum…"
echo "${SHA256}  pkg.tar.bz2" | shasum -a 256 -c - >/dev/null \
  || { echo "❌ checksum mismatch — refusing to use this artifact" >&2; exit 1; }

echo "    extracting…"
tar xjf pkg.tar.bz2
SRC="${WORK}/sherpa-onnx-v${SHERPA_VERSION}-osx-universal2-static"
LIB="${SRC}/lib"
INC="${SRC}/include"

# Combine sherpa-onnx's own static libs AND onnxruntime into a single universal
# archive so the resulting xcframework is fully self-contained (we only need
# VAD, but the C API references the whole set; the linker dead-strips unused
# code from the final app binary).
echo "    combining sherpa-onnx + onnxruntime into one universal static lib…"
libtool -static -o "${WORK}/libsherpa-onnx.a" \
  "${LIB}/libsherpa-onnx-c-api.a" "${LIB}/libsherpa-onnx-core.a" \
  "${LIB}/libkaldi-native-fbank-core.a" "${LIB}/libkissfft-float.a" \
  "${LIB}/libsherpa-onnx-fstfar.a" "${LIB}/libsherpa-onnx-fst.a" \
  "${LIB}/libsherpa-onnx-kaldifst-core.a" "${LIB}/libkaldi-decoder-core.a" \
  "${LIB}/libucd.a" "${LIB}/libpiper_phonemize.a" "${LIB}/libespeak-ng.a" \
  "${LIB}/libssentencepiece_core.a" "${LIB}/libonnxruntime.a"

echo "    creating xcframework…"
rm -rf "$DEST"
mkdir -p "${ROOT}/Vendor"
xcodebuild -create-xcframework \
  -library "${WORK}/libsherpa-onnx.a" \
  -headers "${INC}" \
  -output "$DEST" >/dev/null

echo "✅ Wrote ${DEST}"
