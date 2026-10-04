#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This assistant runs on a Mac with Messages.app." >&2
    exit 1
fi

if ! command -v imsg >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Install Homebrew from https://brew.sh, then rerun bash scripts/start.sh." >&2
        exit 1
    fi
    brew install steipete/tap/imsg
fi

./scripts/setup-local-model.sh

if ! .build/release/assistantctl doctor; then
    echo "Grant Full Disk Access to this terminal in System Settings > Privacy & Security," >&2
    echo "quit and reopen the terminal, then rerun bash scripts/start.sh." >&2
    exit 1
fi

config="$HOME/Library/Application Support/LocalProactiveAssistant/control-chat-id.txt"
if [[ ! -s "$config" ]]; then
    .build/release/assistantctl pair-chat
fi

if .build/release/assistantctl model-status; then
    echo "Apple's local model is ready. On the first reply, allow Automation > Messages."
    exec .build/release/assistantctl serve --model apple
fi

echo "Apple's local model is unavailable. Owner commands still work; questions need an Apple Intelligence Mac."
exec .build/release/assistantctl serve
