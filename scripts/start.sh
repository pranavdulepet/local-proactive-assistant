#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/startup-common.sh

choose_again=false
case "${1:-}" in
    --choose-model) choose_again=true; shift ;;
    --help)
        echo "Usage: bash scripts/start.sh [--choose-model]"
        echo "First run installs prerequisites, remembers your local model choice, and pairs Messages."
        exit 0 ;;
    "") ;;
    *) echo "Usage: bash scripts/start.sh [--choose-model]" >&2; exit 1 ;;
esac
[[ "$#" -eq 0 ]] || { echo "Unexpected startup argument." >&2; exit 1; }

assistant_require_prerequisites
model_name=""
model_url=""
if [[ "$choose_again" == true ]]; then
    assistant_choose_model
elif [[ -n "${ASSISTANT_MODEL:-}" ]]; then
    model_choice="$ASSISTANT_MODEL"
    model_name="${ASSISTANT_MODEL_NAME:-}"
    model_url="${ASSISTANT_MODEL_URL:-http://127.0.0.1:11434/v1}"
elif ! assistant_load_profile; then
    assistant_choose_model
fi

case "$model_choice" in
    ollama)
        export ASSISTANT_OPEN_MODEL="$model_name"
        exec bash scripts/start-open-model.sh ;;
    local)
        if ! assistant_valid_model_name "$model_name" || ! assistant_valid_endpoint "$model_url"; then
            echo "Choose a loaded model and a literal loopback http://127.0.0.1:<port>/v1 endpoint." >&2
            exit 1
        fi
        swift build -c release --product assistantctl
        model_args=(--model local --model-url "$model_url" --model-name "$model_name") ;;
    apple)
        if ! assistant_apple_eligible; then
            echo "Apple inference requires Apple silicon, macOS 26+, and Xcode 26+." >&2
            echo "Choose Ollama with bash scripts/start.sh --choose-model." >&2
            exit 1
        fi
        bash scripts/setup-local-model.sh
        model_args=(--model apple) ;;
    *) echo "ASSISTANT_MODEL must be apple, local, or ollama." >&2; exit 1 ;;
esac

if ! .build/release/assistantctl doctor; then
    echo "Allow this terminal in System Settings > Privacy & Security > Full Disk Access." >&2
    echo "Quit and reopen the terminal, then rerun bash scripts/start.sh. Your model choice is saved." >&2
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles' || true
    exit 1
fi

control_config="$assistant_support_dir/control-chat-id.txt"
if [[ ! -s "$control_config" ]]; then
    .build/release/assistantctl pair-chat
fi

access_config="$assistant_support_dir/access-prepared-v1.txt"
if [[ ! -s "$access_config" && "${ASSISTANT_SKIP_ACCESS_SETUP:-0}" != 1 ]]; then
    echo "Connect Mail, Notes, and Reminders on this Mac so questions can use them."
    echo "macOS may show access prompts. Denying a source keeps that source unavailable."
    connect_sources=y
    if [[ -t 0 ]]; then
        IFS= read -r -p "Connect these sources now? [Y/n, skip for now]: " connect_sources || connect_sources=n
    fi
    if [[ "${connect_sources:-y}" != n && "${connect_sources:-y}" != N ]]; then
        if .build/release/assistantctl prepare-access; then
            mkdir -p "$assistant_support_dir"
            printf '1\n' > "$access_config"
            chmod 600 "$access_config"
        else
            echo "Some sources are unavailable. Messages chat can still start."
            echo "Finish access later with .build/release/assistantctl prepare-access."
        fi
    fi
fi

if ! .build/release/assistantctl model-status "${model_args[@]}"; then
    echo "The selected local model is not ready. Fix the status above or choose another model:" >&2
    echo "bash scripts/start.sh --choose-model" >&2
    exit 1
fi

echo "Ready to answer from your Mac. Allow Automation > Messages on the first reply."
echo "Text your paired self-chat naturally from your iPhone, or send /status."
echo "Leave this window open. Control-C stops the assistant; rerun this script to resume."
serve_args=("${model_args[@]}")
if [[ -n "${ASSISTANT_READ_ROOT:-}" ]]; then
    serve_args+=(--read-root "$ASSISTANT_READ_ROOT")
fi
if command -v caffeinate >/dev/null 2>&1; then
    # Keep the open Mac awake while serving; this does not prevent closed-lid sleep.
    exec caffeinate -i .build/release/assistantctl serve "${serve_args[@]}"
fi
exec .build/release/assistantctl serve "${serve_args[@]}"
