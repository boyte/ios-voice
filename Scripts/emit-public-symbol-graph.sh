#!/usr/bin/env bash
set -euo pipefail

# SwiftPM's generated Xcode test target enables @testable visibility even for
# a package build. That is useful for XCTest, but it is not the shipped API.
# Emit the allowlist from a production-only swiftc invocation instead of
# trusting the test-visible graph. This repository intentionally has no root
# Xcode scheme; SwiftPM is the canonical package build and Testing/ contains
# the optional simulator XCTest host.

OUTPUT_DIR="${1:?usage: $0 OUTPUT_DIR DERIVED_DATA_DIR}"
DERIVED_DATA_DIR="${2:?usage: $0 OUTPUT_DIR DERIVED_DATA_DIR}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="${APPLOCALVOICE_SWIFT_TRIPLE:-arm64-apple-ios26.0-simulator}"

rm -rf "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
mkdir -p "$OUTPUT_DIR"

swift build \
  --package-path "$ROOT_DIR" \
  --sdk "$SDK" \
  --triple "$TRIPLE" \
  --scratch-path "$DERIVED_DATA_DIR" \
  -Xswiftc -warnings-as-errors

MODULE_DIR="$(find "$DERIVED_DATA_DIR" -type d -path '*/debug/Modules' -print -quit)"
MODULE_MAP="$(find "$DERIVED_DATA_DIR" -type f -path '*AppLocalVoiceAudioEngineSafe.build/module.modulemap' -print -quit)"

test -d "$MODULE_DIR"
test -f "$MODULE_MAP"

xcrun swiftc \
  -emit-module \
  -parse-as-library \
  -target "$TRIPLE" \
  -sdk "$SDK" \
  -I "$MODULE_DIR" \
  -Xcc -fmodule-map-file="$MODULE_MAP" \
  -Xcc -I -Xcc "$ROOT_DIR/Sources/AppLocalVoiceAudioEngineSafe/include" \
  -emit-symbol-graph \
  -emit-symbol-graph-dir "$OUTPUT_DIR" \
  -emit-module-path "$OUTPUT_DIR/AppLocalVoice.swiftmodule" \
  -module-name AppLocalVoice \
  -warnings-as-errors \
  "$ROOT_DIR"/Sources/AppLocalVoice/*.swift
