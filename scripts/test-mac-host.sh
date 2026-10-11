#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'Native host tests require macOS.' >&2; exit 1; }
staging="$(mktemp -d "${TMPDIR:-/tmp}/assistant-native-tests.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 6 -parse-as-library -sdk "$sdk" -target "$(uname -m)-apple-macos14.0" \
    Apps/AssistantMac/HostProfile.swift Apps/AssistantMac/HostController.swift Apps/AssistantMac/Tests/NativeHostTests.swift \
    -o "$staging/NativeHostTests"
"$staging/NativeHostTests"
