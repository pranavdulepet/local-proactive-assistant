#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
if [[ -z "$xcode_major" || "$xcode_major" -lt 26 ]]; then
    echo "Select Xcode 26+ as the developer directory before running this setup." >&2
    exit 1
fi

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
install_root="$HOME/Library/Application Support/LocalProactiveAssistant/Models"
mkdir -p "$install_root"
chmod 700 "$install_root"
staging="$(mktemp -d "$install_root/.install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/LocalAssistantModel.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/assistant-model-worker" "$bundle/Contents/MacOS/"
cp Configuration/ModelWorker-Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - --entitlements Configuration/ModelWorker.entitlements "$bundle"
codesign --verify --strict "$bundle"
if [[ -d "$install_root/LocalAssistantModel.app" ]]; then
    mv "$install_root/LocalAssistantModel.app" "$staging/previous.app"
fi
mv "$bundle" "$install_root/LocalAssistantModel.app"

echo "Installed the signed, sandboxed local model worker. No extra model weights downloaded."
echo "Next: .build/release/assistantctl model-status"
echo "Then: .build/release/assistantctl serve --control-chat-id 955 --model apple"
