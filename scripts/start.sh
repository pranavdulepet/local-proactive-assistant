#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/startup-common.sh

choose_again=false
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --choose-model) choose_again=true ;;
        --verbose) export ASSISTANT_VERBOSE=1 ;;
        --help)
            echo "Usage: bash scripts/start.sh [--choose-model] [--verbose]"
            echo "Start Messages chat with a saved local model, or choose one on the first run."
            exit 0 ;;
        *) echo "Usage: bash scripts/start.sh [--choose-model] [--verbose]" >&2; exit 1 ;;
    esac
    shift
done
assistant_require_mac
assistant_start_session
if [[ "${ASSISTANT_STARTUP_CHECKED:-0}" != 1 ]]; then
    assistant_stage 'Checking this Mac...'
fi
assistant_require_prerequisites
export ASSISTANT_STARTUP_CHECKED=1
check_args=(--quiet)
if assistant_verbose; then check_args=(--verbose); fi
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

if [[ "${ASSISTANT_STARTUP_MODEL_SHOWN:-0}" != 1 ]]; then
    printf 'Model: %s\n' "$(assistant_model_label)"
    export ASSISTANT_STARTUP_MODEL_SHOWN=1
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
        assistant_stage 'Preparing the assistant...'
        if ! assistant_capture swift build -c release --product assistantctl; then
            echo "The assistant could not be built. Follow the compiler details above, then rerun." >&2
            assistant_log_hint
            exit 1
        fi
        model_args=(--model local --model-url "$model_url" --model-name "$model_name") ;;
    apple)
        if ! assistant_apple_eligible; then
            echo "Apple inference requires Apple silicon, macOS 26+, and Xcode 26+." >&2
            echo "Choose Ollama with bash scripts/start.sh --choose-model." >&2
            exit 1
        fi
        assistant_stage 'Preparing the assistant...'
        if ! assistant_capture bash scripts/setup-local-model.sh; then
            echo "Apple model setup did not finish. Follow the details above, then rerun." >&2
            assistant_log_hint
            exit 1
        fi
        model_args=(--model apple) ;;
    *) echo "ASSISTANT_MODEL must be apple, local, or ollama." >&2; exit 1 ;;
esac

assistant_stage 'Checking Messages access...'
if ! assistant_capture .build/release/assistantctl doctor "${check_args[@]}"; then
    echo "Messages access needs attention. For a permission error, allow this terminal under" >&2
    echo "System Settings > Privacy & Security > Full Disk Access, then quit and reopen it." >&2
    echo "Rerun bash scripts/start.sh. Your model choice is saved." >&2
    assistant_log_hint
    exit 1
fi

control_config="$assistant_support_dir/control-chat-id.txt"
if [[ ! -s "$control_config" ]]; then
    if [[ ! -t 0 ]]; then
        echo "Messages pairing needs your confirmation. Run this starter in Terminal once." >&2
        exit 1
    fi
    .build/release/assistantctl pair-chat
fi

if ! assistant_access_prepared && [[ "${ASSISTANT_SKIP_ACCESS_SETUP:-0}" != 1 ]]; then
    echo "Mail, Notes, and Reminders can answer personal questions after you allow access."
    connect_sources=y
    if [[ -t 0 ]]; then
        IFS= read -r -p "Connect them now? [Y/n]: " connect_sources || connect_sources=n
    fi
    if [[ "${connect_sources:-y}" != n && "${connect_sources:-y}" != N ]]; then
        assistant_stage 'Connecting personal sources...'
        if assistant_capture .build/release/assistantctl prepare-access "${check_args[@]}"; then
            assistant_mark_access_prepared || true
        else
            echo "Chat will use the connected sources. To connect the others later:"
            echo ".build/release/assistantctl prepare-access"
        fi
    fi
fi

assistant_stage 'Checking the model...'
if ! assistant_capture .build/release/assistantctl model-status "${model_args[@]}" "${check_args[@]}"; then
    echo "The selected local model is not ready. Fix the status above or choose another model:" >&2
    echo "bash scripts/start.sh --choose-model" >&2
    assistant_log_hint
    exit 1
fi

assistant_stage 'Starting Messages chat...'
serve_args=("${model_args[@]}")
if assistant_verbose; then serve_args+=(--verbose); else serve_args+=(--quiet); fi
if [[ -n "${ASSISTANT_READ_ROOT:-}" ]]; then
    serve_args+=(--read-root "$ASSISTANT_READ_ROOT")
fi
if command -v caffeinate >/dev/null 2>&1; then
    # Keep the open Mac awake while serving; this does not prevent closed-lid sleep.
    exec caffeinate -i .build/release/assistantctl serve "${serve_args[@]}"
fi
exec .build/release/assistantctl serve "${serve_args[@]}"
