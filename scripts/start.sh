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

model_choice="${ASSISTANT_MODEL:-apple}"
if [[ "$model_choice" == "local" ]]; then
    if [[ -z "${ASSISTANT_MODEL_NAME:-}" ]]; then
        echo "Set ASSISTANT_MODEL_NAME to a model loaded by your local server." >&2
        exit 1
    fi
    swift build -c release --product assistantctl
    model_args=(--model local --model-url "${ASSISTANT_MODEL_URL:-http://127.0.0.1:11434/v1}" --model-name "$ASSISTANT_MODEL_NAME")
elif [[ "$model_choice" == "apple" ]]; then
    ./scripts/setup-local-model.sh
    model_args=(--model apple)
else
    echo "ASSISTANT_MODEL must be apple or local." >&2
    exit 1
fi

if ! .build/release/assistantctl doctor; then
    echo "Grant Full Disk Access to this terminal in System Settings > Privacy & Security," >&2
    echo "quit and reopen the terminal, then rerun bash scripts/start.sh." >&2
    exit 1
fi

config="$HOME/Library/Application Support/LocalProactiveAssistant/control-chat-id.txt"
if [[ ! -s "$config" ]]; then
    .build/release/assistantctl pair-chat
fi

if .build/release/assistantctl model-status "${model_args[@]}"; then
    echo "Local model is ready. On the first reply, allow Automation > Messages."
    exec .build/release/assistantctl serve "${model_args[@]}"
fi

if [[ "$model_choice" == "local" ]]; then
    echo "Your local model server is unavailable. Start it and rerun this script." >&2
    exit 1
fi

echo "Apple's local model is unavailable. Owner commands still work; questions need a ready local model."
exec .build/release/assistantctl serve
