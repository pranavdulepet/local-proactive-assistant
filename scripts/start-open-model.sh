#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This starter needs a Mac with Messages.app." >&2
    exit 1
fi

memory_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
if [[ "$memory_gb" -ge 40 ]]; then
    suggested_model="qwen3.8:27b-q4_K_M"
elif [[ "$memory_gb" -ge 16 ]]; then
    suggested_model="qwen3.5:9b-q4_K_M"
elif [[ "$memory_gb" -ge 12 ]]; then
    suggested_model="qwen3.5:4b-q4_K_M"
else
    echo "This Mac has less than 12 GB of memory. Use bash scripts/start.sh for the built-in Apple model." >&2
    exit 1
fi
model_name="${ASSISTANT_OPEN_MODEL:-$suggested_model}"
if [[ "$model_name" == *:cloud* ]]; then
    echo "Cloud model tags are not accepted by the on-device starter." >&2
    exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Install Homebrew from https://brew.sh and rerun this script." >&2
        exit 1
    fi
    brew install ollama
fi
ollama_bin="$(command -v ollama)"
brew_ollama=false
if command -v brew >/dev/null 2>&1 && brew list --formula --versions ollama >/dev/null 2>&1; then
    brew_ollama=true
    ollama_bin="$(brew --prefix ollama)/bin/ollama"
fi

# Use an owned server so an older desktop app/service cannot survive a CLI upgrade.
# Override inherited Ollama/proxy settings for every CLI call and local health check.
export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_NO_CLOUD=1
ollama_url="http://$OLLAMA_HOST"
ollama_log="${TMPDIR:-/tmp}/local-assistant-ollama.log"
ollama_pid=""
pull_log=""
stop_server() {
    if [[ -n "$ollama_pid" ]]; then
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
        ollama_pid=""
    fi
}
cleanup() {
    stop_server
    if [[ -n "$pull_log" ]]; then rm -f "$pull_log"; fi
}
trap cleanup EXIT

start_server() {
    if curl --noproxy '*' --silent --fail --max-time 2 "$ollama_url/api/version" >/dev/null; then
        echo "Port 11435 is already in use. Stop the other local assistant before restarting." >&2
        return 1
    fi
    "$ollama_bin" serve >"$ollama_log" 2>&1 &
    ollama_pid=$!
    for _ in {1..40}; do
        if ! kill -0 "$ollama_pid" 2>/dev/null; then break; fi
        if curl --noproxy '*' --silent --fail --max-time 2 "$ollama_url/api/version" >/dev/null; then
            echo "Ollama executable: $ollama_bin"
            echo "Local server: $(curl --noproxy '*' --silent --fail --max-time 2 "$ollama_url/api/version")"
            return 0
        fi
        sleep 0.5
    done
    echo "The local Ollama server did not start. See $ollama_log." >&2
    return 1
}
start_server

if ! "$ollama_bin" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$model_name"; then
    echo "Downloading $model_name once; the model remains on this Mac for later runs."
    pull_log="$(mktemp "${TMPDIR:-/tmp}/local-assistant-pull.XXXXXX")"
    if ! "$ollama_bin" pull "$model_name" 2>&1 | tee "$pull_log"; then
        if ! grep -Eqi 'requires a newer version of Ollama|pull model manifest: 412' "$pull_log"; then
            echo "Model download failed. Fix the reported error and rerun this starter." >&2
            exit 1
        fi
        stop_server
        if [[ "$brew_ollama" == true ]]; then
            echo "The model needs a newer Ollama. Updating the Homebrew runtime and retrying once."
            brew update
            brew upgrade ollama
            ollama_bin="$(brew --prefix ollama)/bin/ollama"
            start_server
            if ! "$ollama_bin" pull "$model_name"; then
                echo "Download still failed after the update. Install the latest Ollama from https://ollama.com/download, then rerun." >&2
                exit 1
            fi
        else
            echo "Update Ollama from https://ollama.com/download (or its menu > Restart to update), then rerun." >&2
            echo "This starter used $ollama_bin. Check that this executable was updated too." >&2
            exit 1
        fi
    fi
fi

echo "Using $model_name on this Mac. Replies are generated locally."
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_URL="$ollama_url/v1" \
ASSISTANT_MODEL_NAME="$model_name" \
ASSISTANT_LOCAL_REASONING_EFFORT="${ASSISTANT_LOCAL_REASONING_EFFORT:-none}" \
bash scripts/start.sh
