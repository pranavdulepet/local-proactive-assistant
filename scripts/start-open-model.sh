#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/startup-common.sh
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --verbose) export ASSISTANT_VERBOSE=1 ;;
        --help)
            echo "Usage: bash scripts/start-open-model.sh [--verbose]"
            echo "Start an Ollama model locally; ASSISTANT_OPEN_MODEL selects a different local tag."
            exit 0 ;;
        *) echo "Usage: bash scripts/start-open-model.sh [--verbose]" >&2; exit 1 ;;
    esac
    shift
done
assistant_require_mac
assistant_start_session
suggested_model="$(assistant_suggest_model)"
model_name="${ASSISTANT_OPEN_MODEL:-$suggested_model}"
if ! assistant_valid_tag "$model_name"; then
    echo "Use a local Ollama model tag. Cloud tags and invalid model names are not accepted." >&2
    exit 1
fi
if [[ "${ASSISTANT_STARTUP_CHECKED:-0}" != 1 ]]; then
    assistant_stage 'Checking this Mac...'
    assistant_require_prerequisites
    export ASSISTANT_STARTUP_CHECKED=1
fi
if [[ "${ASSISTANT_STARTUP_MODEL_SHOWN:-0}" != 1 ]]; then
    printf 'Model: %s\n' "$model_name"
    export ASSISTANT_STARTUP_MODEL_SHOWN=1
fi

owned_runtime="$assistant_support_dir/Runtime/Ollama.app"
ollama_pid=""
pull_log=""
list_log=""
assistant_install_staging=""
stop_server() {
    if [[ -n "$ollama_pid" ]]; then
        # Signal only our own child; finish cleanup even if it ignores SIGTERM.
        if jobs -pr | grep -Fxq -- "$ollama_pid"; then
            kill "$ollama_pid" 2>/dev/null || true
            for _ in {1..50}; do
                if ! kill -0 "$ollama_pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if jobs -pr | grep -Fxq -- "$ollama_pid"; then
                kill -KILL "$ollama_pid" 2>/dev/null || true
            fi
        fi
        wait "$ollama_pid" 2>/dev/null || true
        ollama_pid=""
    fi
}
cleanup() {
    stop_server
    if [[ -n "$pull_log" ]]; then rm -f "$pull_log"; fi
    if [[ -n "$list_log" ]]; then rm -f "$list_log"; fi
    if [[ -n "$assistant_install_staging" ]]; then rm -rf "$assistant_install_staging"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if command -v ollama >/dev/null 2>&1; then
    ollama_bin="$(command -v ollama)"
elif [[ -x "$owned_runtime/Contents/Resources/ollama" ]]; then
    ollama_bin="$owned_runtime/Contents/Resources/ollama"
elif [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    ollama_bin=/Applications/Ollama.app/Contents/Resources/ollama
elif assistant_find_brew; then
    assistant_stage 'Installing Ollama...'
    if ! assistant_capture brew install ollama; then assistant_log_hint; exit 1; fi
    ollama_bin="$(command -v ollama)"
else
    assistant_install_owned_ollama
    ollama_bin="$owned_runtime/Contents/Resources/ollama"
fi
brew_ollama=false
if command -v brew >/dev/null 2>&1 && brew list --formula --versions ollama >/dev/null 2>&1; then
    brew_ollama=true
    ollama_bin="$(brew --prefix ollama)/bin/ollama"
fi

# An owned server avoids stale desktop/service versions and inherited remote endpoints.
export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_NO_CLOUD=1
export NO_PROXY=localhost,127.0.0.1,::1
ollama_url="http://$OLLAMA_HOST"
ollama_log="$(mktemp "$assistant_support_dir/Logs/ollama.XXXXXX")"
start_server() {
    if ! command -v lsof >/dev/null 2>&1; then
        echo "The macOS lsof command is unavailable. Restore it to PATH and rerun." >&2
        return 1
    fi
    if lsof -nP -iTCP:11435 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "Port 11435 is already in use. Stop the other local assistant before restarting." >&2
        return 1
    fi
    "$ollama_bin" serve >>"$ollama_log" 2>&1 &
    ollama_pid=$!
    for _ in {1..40}; do
        if ! kill -0 "$ollama_pid" 2>/dev/null; then break; fi
        # Health alone is insufficient: another server could win the port race.
        if lsof -nP -a -p "$ollama_pid" -iTCP:11435 -sTCP:LISTEN -t >/dev/null 2>&1 \
            && curl --noproxy '*' --silent --fail --max-time 2 "$ollama_url/api/version" >/dev/null; then
            if assistant_verbose; then
                echo "Ollama executable: $ollama_bin"
                echo "Local server: $(curl --noproxy '*' --silent --fail --max-time 2 "$ollama_url/api/version")"
            fi
            return 0
        fi
        sleep 0.5
    done
    tail -n 12 "$ollama_log" >&2
    echo "Ollama did not start. Details: $ollama_log" >&2
    return 1
}
assistant_stage 'Starting the local model...'
start_server
list_log="$(mktemp "$assistant_support_dir/Logs/models.XXXXXX")"
if ! "$ollama_bin" list >"$list_log" 2>&1; then
    cat "$list_log" >>"$ASSISTANT_STARTUP_LOG"
    tail -n 12 "$list_log" >&2
    echo "Installed models could not be checked. Restart the assistant." >&2
    assistant_log_hint
    exit 1
fi
cat "$list_log" >>"$ASSISTANT_STARTUP_LOG"

pull_model() {
    local pull_status=0
    if assistant_verbose; then
        "$ollama_bin" pull "$model_name" 2>&1 | tee "$pull_log" || pull_status=$?
    else
        "$ollama_bin" pull "$model_name" >"$pull_log" 2>&1 || pull_status=$?
    fi
    cat "$pull_log" >>"$ASSISTANT_STARTUP_LOG"
    return "$pull_status"
}
if ! awk 'NR > 1 { print $1 }' "$list_log" | grep -Fxq -- "$model_name"; then
    assistant_stage "Downloading $model_name (one time; this may take a while)..."
    pull_log="$(mktemp "$assistant_support_dir/Logs/download.XXXXXX")"
    if ! pull_model; then
        if ! grep -Eqi 'requires a newer version of Ollama|pull model manifest: 412' "$pull_log"; then
            tail -n 12 "$pull_log" >&2
            echo "Model download did not finish. Check the error above and rerun." >&2
            assistant_log_hint
            exit 1
        fi
        stop_server
        if [[ "$brew_ollama" == true ]]; then
            assistant_stage 'Updating Ollama for this model...'
            if ! assistant_capture brew update || ! assistant_capture brew upgrade ollama; then
                assistant_log_hint
                exit 1
            fi
            ollama_bin="$(brew --prefix ollama)/bin/ollama"
        elif [[ "$ollama_bin" == "$owned_runtime/Contents/Resources/ollama" ]]; then
            assistant_stage 'Updating Ollama for this model...'
            assistant_install_owned_ollama
        else
            echo "Update Ollama from https://ollama.com/download (or its menu > Restart to update), then rerun." >&2
            echo "Executable used: $ollama_bin" >&2
            assistant_log_hint
            exit 1
        fi
        start_server
        if ! pull_model; then
            tail -n 12 "$pull_log" >&2
            echo "The model still could not download after updating Ollama. Check the error above." >&2
            assistant_log_hint
            exit 1
        fi
    fi
fi

# Keep explicit shortcut choices as well as choices made in the model menu.
model_choice=ollama
model_url=""
assistant_save_profile
ASSISTANT_OLLAMA_READY=1 \
ASSISTANT_MODEL=ollama \
ASSISTANT_MODEL_URL="$ollama_url" \
ASSISTANT_MODEL_NAME="$model_name" \
bash scripts/start.sh
