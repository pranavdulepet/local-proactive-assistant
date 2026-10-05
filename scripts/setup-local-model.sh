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
installed=false
previous_moved=false
install_target="$install_root/LocalAssistantModel.app"
cleanup() {
    local install_status=$? preserve_backup=false
    if [[ "$installed" == false && "$previous_moved" == true && -d "$staging/previous.app" ]]; then
        if [[ ! -e "$install_target" && ! -L "$install_target" ]] \
            && mv "$staging/previous.app" "$install_target"; then
            echo "Installation stopped. The previous Apple model worker was restored." >&2
        else
            preserve_backup=true
            echo "Installation stopped. The previous worker is saved at $staging/previous.app." >&2
        fi
    fi
    if [[ "$preserve_backup" == false ]]; then rm -rf "$staging"; fi
    return "$install_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -L "$install_target" || ( -e "$install_target" && ! -d "$install_target" ) ]]; then
    echo "The model worker path is not an application folder. Move it aside before installing." >&2
    exit 1
fi
bundle="$staging/LocalAssistantModel.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/assistant-model-worker" "$bundle/Contents/MacOS/"
cp Configuration/ModelWorker-Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - --entitlements Configuration/ModelWorker.entitlements "$bundle"
codesign --verify --strict "$bundle"
if [[ -d "$install_target" ]]; then
    mv "$install_target" "$staging/previous.app"
    previous_moved=true
fi
mv "$bundle" "$install_target"
installed=true

echo "Apple model worker installed."
