#!/usr/bin/env bash
#
# Fetches the two ONNX models speaker diarization needs into Nod/Core/Resources.
#
# Why a script instead of committed binaries:
#   - together they are ~35 MB, which bloats every clone and every diff of a
#     repo whose only other committed model is 640 KB (silero_vad.onnx).
#   - they are immutable upstream releases, so pinning URL + SHA-256 gives the
#     same reproducibility a commit would.
#
# Unlike the VAD xcframework, these are NOT build-time only: they are bundled
# resources and ship inside the app. A build without them still succeeds —
# `SpeakerDiarizer.bundled()` returns nil and transcripts fall back to
# source-based Me/Them labels.
#
# Licences: pyannote segmentation-3.0 is MIT (CNRS), wespeaker CAM++ is
# Apache 2.0. Both are redistributable inside a commercial app.
#
# Usage:  ./scripts/fetch-diarization-models.sh [--force]

set -euo pipefail

SEGMENTATION_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
SEGMENTATION_TARBALL_SHA256="24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
SEGMENTATION_SHA256="220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"

EMBEDDING_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_CAM++.onnx"
EMBEDDING_SHA256="c46fad10b5f81e1aa4a60c162714208577093655076c5450f8c469e522ec54ef"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/Nod/Core/Resources"
SEGMENTATION_DEST="${DEST}/pyannote_segmentation.onnx"
EMBEDDING_DEST="${DEST}/speaker_embedding.onnx"

if [ -f "$SEGMENTATION_DEST" ] && [ -f "$EMBEDDING_DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "==> diarization models already present — skipping (use --force to refetch)"
  exit 0
fi

verify() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch for $file" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST"

echo "==> downloading pyannote segmentation-3.0 (~6 MB)…"
curl -fsSL -o "${WORK}/segmentation.tar.bz2" "$SEGMENTATION_URL"
verify "${WORK}/segmentation.tar.bz2" "$SEGMENTATION_TARBALL_SHA256"
tar xjf "${WORK}/segmentation.tar.bz2" -C "$WORK"
verify "${WORK}/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$SEGMENTATION_SHA256"
cp "${WORK}/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$SEGMENTATION_DEST"

echo "==> downloading wespeaker CAM++ embedding model (~28 MB)…"
curl -fsSL -o "${WORK}/embedding.onnx" "$EMBEDDING_URL"
verify "${WORK}/embedding.onnx" "$EMBEDDING_SHA256"
cp "${WORK}/embedding.onnx" "$EMBEDDING_DEST"

echo "==> done:"
echo "    $SEGMENTATION_DEST"
echo "    $EMBEDDING_DEST"
