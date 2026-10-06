#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$HOME/Applications/LocalAssistant.app"
build_only=false
open_app=true
verbose=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) build_only=true; open_app=false; shift ;;
        --no-open) open_app=false; shift ;;
        --verbose) verbose=true; shift ;;
        --output)
            [[ $# -ge 2 ]] || { echo 'Provide an absolute .app path after --output.' >&2; exit 2; }
            output="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'The native host builds on macOS.' >&2; exit 1; }
mac_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$mac_major" =~ ^[0-9]+$ && "$mac_major" -ge 14 ]] || { echo 'macOS 14 or newer is required.' >&2; exit 1; }
[[ "$output" == /* && "$output" == *.app && "$output" != *$'\n'* ]] || { echo 'Use an absolute .app output path.' >&2; exit 2; }
if [[ -L "$output" || ( -e "$output" && ! -d "$output" ) ]]; then
    echo 'The output path is not an application folder. Move it aside before installing.' >&2
    exit 1
fi
command -v swift >/dev/null && command -v xcrun >/dev/null || { echo 'Install Swift 6-compatible Xcode developer tools first.' >&2; exit 1; }
imsg_binary="$(command -v imsg || true)"
[[ -n "$imsg_binary" ]] || { echo 'Run bash scripts/start.sh once to install Messages support, choose a model, and pair your phone.' >&2; exit 1; }
while [[ -L "$imsg_binary" ]]; do
    link="$(readlink "$imsg_binary")"
    if [[ "$link" == /* ]]; then imsg_binary="$link"; else imsg_binary="$(dirname "$imsg_binary")/$link"; fi
done
[[ -f "$imsg_binary" && -x "$imsg_binary" ]] || { echo 'The installed Messages helper is not executable.' >&2; exit 1; }

parent="$(dirname "$output")"
mkdir -p "$parent"
log="$(mktemp "$parent/LocalAssistant-build.XXXXXX")"
chmod 600 "$log"
staging="$(mktemp -d "$parent/.native-install.XXXXXX")"
worker_staging=''
worker_target="$HOME/Library/Application Support/LocalProactiveAssistant/Models/LocalAssistantModel.app"
app_moved=false
worker_moved=false
app_replaced=false
worker_replaced=false
committed=false

cleanup() {
    local status=$? preserve_app=false preserve_worker=false
    set +e
    if [[ "$committed" == false ]]; then
        if [[ "$app_replaced" == true ]]; then rm -rf "$output"; fi
        if [[ "$app_moved" == true ]]; then
            if [[ ! -e "$output" && ! -L "$output" ]] && mv "$staging/previous.app" "$output"; then
                echo 'The previous native app was restored.' >&2
            else preserve_app=true; echo "The previous app is saved at $staging/previous.app." >&2; fi
        fi
        if [[ "$worker_replaced" == true ]]; then rm -rf "$worker_target"; fi
        if [[ "$worker_moved" == true ]]; then
            if [[ ! -e "$worker_target" && ! -L "$worker_target" ]] && mv "$worker_staging/previous.app" "$worker_target"; then
                echo 'The previous Apple worker was restored.' >&2
            else preserve_worker=true; echo "The previous worker is saved at $worker_staging/previous.app." >&2; fi
        fi
    fi
    [[ "$preserve_app" == true ]] || rm -rf "$staging"
    if [[ -n "$worker_staging" && "$preserve_worker" == false ]]; then rm -rf "$worker_staging"; fi
    if [[ "$status" -ne 0 ]]; then
        tail -n 30 "$log" >&2
        echo "Build details: $log" >&2
    else rm -f "$log"; fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_logged() {
    if [[ "$verbose" == true ]]; then "$@" 2>&1 | tee -a "$log"; else "$@" >>"$log" 2>&1; fi
}

cd "$repo_root"
echo 'Building native Mac host...'
run_logged swift build -c release
binary_dir="$(swift build -c release --show-bin-path 2>>"$log")"
sdk="$(xcrun --sdk macosx --show-sdk-path 2>>"$log")"
architecture="$(uname -m)"
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { echo 'Unsupported Mac architecture.' >&2; exit 1; }
app="$staging/LocalAssistant.app"
runtime="$app/Contents/Resources/Runtime"
mkdir -p "$app/Contents/MacOS" "$runtime/bin" "$runtime/Models/LocalAssistantModel.app/Contents/MacOS"
run_logged xcrun swiftc -swift-version 6 -parse-as-library -O -sdk "$sdk" -target "$architecture-apple-macos14.0" \
    Apps/AssistantMac/HostProfile.swift Apps/AssistantMac/HostController.swift Apps/AssistantMac/LocalAssistantApp.swift \
    -o "$app/Contents/MacOS/LocalAssistant"
cp Apps/AssistantMac/Info.plist "$app/Contents/Info.plist"
cp "$binary_dir/assistantctl" "$runtime/bin/assistantctl"
cp "$imsg_binary" "$runtime/bin/imsg"
# Homebrew can make its installed helper read-only. Re-sign only this private copy.
chmod u+w "$runtime/bin/imsg"
for resources in "$binary_dir"/*.bundle "$(dirname "$imsg_binary")"/*.bundle; do
    if [[ -d "$resources" ]]; then cp -R "$resources" "$runtime/bin/"; fi
done
worker="$runtime/Models/LocalAssistantModel.app"
cp "$binary_dir/assistant-model-worker" "$worker/Contents/MacOS/assistant-model-worker"
cp Configuration/ModelWorker-Info.plist "$worker/Contents/Info.plist"
run_logged codesign --force --sign - --entitlements Configuration/ModelWorker.entitlements "$worker"
run_logged codesign --force --sign - --entitlements Apps/AssistantMac/Host.entitlements "$runtime/bin/assistantctl"
run_logged codesign --force --sign - --entitlements Apps/AssistantMac/Host.entitlements "$runtime/bin/imsg"
# Sign each boundary explicitly. Deep re-signing would replace the worker's sandbox entitlement.
run_logged codesign --force --sign - --identifier org.localproactiveassistant.mac --entitlements Apps/AssistantMac/Host.entitlements "$app"
run_logged codesign --verify --deep --strict "$app"

if [[ "$build_only" == false ]]; then
    if [[ -L "$worker_target" || ( -e "$worker_target" && ! -d "$worker_target" ) ]]; then
        echo 'The existing model worker path is not an application folder. Move it aside before installing.' >&2
        exit 1
    fi
    worker_parent="$(dirname "$worker_target")"
    mkdir -p "$worker_parent"
    chmod 700 "$worker_parent"
    worker_staging="$(mktemp -d "$worker_parent/.native-install.XXXXXX")"
    cp -R "$worker" "$worker_staging/LocalAssistantModel.app"
    run_logged codesign --verify --strict "$worker_staging/LocalAssistantModel.app"
    if [[ -d "$worker_target" ]]; then mv "$worker_target" "$worker_staging/previous.app"; worker_moved=true; fi
    mv "$worker_staging/LocalAssistantModel.app" "$worker_target"
    worker_replaced=true
fi
if [[ -d "$output" ]]; then mv "$output" "$staging/previous.app"; app_moved=true; fi
mv "$app" "$output"
app_replaced=true
committed=true
echo "Native app ready: $output"
if [[ "$build_only" == false ]]; then
    echo 'Stop the Terminal host before using the app. Grant Local Assistant its own macOS access permissions.'
    echo 'The app reuses your saved model and phone pairing. Enable Start at login in its menu if desired.'
    if [[ "$open_app" == true ]] && ! open "$output"; then
        echo 'Open the installed app from Finder to start it.' >&2
    fi
fi
