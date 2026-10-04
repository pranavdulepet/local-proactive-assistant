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

ollama_pid=""
cleanup() {
    if [[ -n "$ollama_pid" ]]; then
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
if ! curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then
    OLLAMA_HOST=127.0.0.1:11434 ollama serve >"${TMPDIR:-/tmp}/local-assistant-ollama.log" 2>&1 &
    ollama_pid=$!
    for _ in {1..40}; do
        if curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then break; fi
        if ! kill -0 "$ollama_pid" 2>/dev/null; then break; fi
        sleep 0.5
    done
fi
if ! curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then
    echo "The local Ollama server did not start. See ${TMPDIR:-/tmp}/local-assistant-ollama.log." >&2
    exit 1
fi

if ! ollama list | awk 'NR > 1 { print $1 }' | grep -Fxq "$model_name"; then
    echo "Downloading $model_name once; the model remains on this Mac for later runs."
    ollama pull "$model_name"
fi

echo "Using $model_name on this Mac. Replies are generated locally."
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_URL=http://127.0.0.1:11434/v1 \
ASSISTANT_MODEL_NAME="$model_name" \
ASSISTANT_LOCAL_REASONING_EFFORT="${ASSISTANT_LOCAL_REASONING_EFFORT:-none}" \
bash scripts/start.sh
