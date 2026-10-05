#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/startup-common.sh
assistant_require_mac
suggested_model="$(assistant_suggest_model)"
model_name="${ASSISTANT_OPEN_MODEL:-$suggested_model}"
if ! assistant_valid_tag "$model_name"; then
    echo "Use a local Ollama model tag. Cloud tags and invalid model names are not accepted." >&2
    exit 1
fi

owned_runtime="$assistant_support_dir/Runtime/Ollama.app"
install_owned_ollama() {
    local staging
    mkdir -p "$assistant_support_dir/Runtime"
    chmod 700 "$assistant_support_dir" "$assistant_support_dir/Runtime"
    staging="$(mktemp -d "$assistant_support_dir/Runtime/.ollama-download.XXXXXX")"
    echo "Installing Ollama from its official macOS download."
    if ! curl --proto '=https' --tlsv1.2 --fail --show-error --location \
        https://ollama.com/download/Ollama-darwin.zip -o "$staging/Ollama.zip" \
        || ! /usr/bin/ditto -x -k "$staging/Ollama.zip" "$staging" \
        || ! /usr/bin/codesign --verify --deep --strict "$staging/Ollama.app" \
        || ! /usr/sbin/spctl --assess --type execute "$staging/Ollama.app"; then
        rm -rf "$staging"
        echo "The official Ollama download could not be installed or verified. Use https://ollama.com/download and rerun." >&2
        return 1
    fi
    if [[ -d "$owned_runtime" ]]; then mv "$owned_runtime" "$staging/previous.app"; fi
    mv "$staging/Ollama.app" "$owned_runtime"
    rm -rf "$staging"
}
if command -v ollama >/dev/null 2>&1; then
    ollama_bin="$(command -v ollama)"
elif [[ -x "$owned_runtime/Contents/Resources/ollama" ]]; then
    ollama_bin="$owned_runtime/Contents/Resources/ollama"
elif [[ -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    ollama_bin=/Applications/Ollama.app/Contents/Resources/ollama
elif assistant_find_brew; then
    brew install ollama
    ollama_bin="$(command -v ollama)"
else
    install_owned_ollama
    ollama_bin="$owned_runtime/Contents/Resources/ollama"
fi
brew_ollama=false
if command -v brew >/dev/null 2>&1 && brew list --formula --versions ollama >/dev/null 2>&1; then
    brew_ollama=true
    ollama_bin="$(brew --prefix ollama)/bin/ollama"
fi

# Use an owned server so an older desktop app/service cannot survive a CLI upgrade.
# Override inherited Ollama/proxy settings for every CLI call and local health check.
export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_NO_CLOUD=1
export NO_PROXY=localhost,127.0.0.1,::1
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
trap 'exit 130' INT
trap 'exit 143' TERM

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
        elif [[ "$ollama_bin" == "$owned_runtime/Contents/Resources/ollama" ]]; then
            echo "The model needs a newer Ollama. Updating this assistant's private runtime and retrying once."
            install_owned_ollama
            start_server
            if ! "$ollama_bin" pull "$model_name"; then
                echo "Download still failed after the update. Check the error above and rerun." >&2
                exit 1
            fi
        else
            echo "Update Ollama from https://ollama.com/download (or its menu > Restart to update), then rerun." >&2
            echo "This starter used $ollama_bin. Check that this executable was updated too." >&2
            exit 1
        fi
    fi
fi

# Remember explicit open-model starter choices as well as choices from the main menu.
model_choice=ollama
model_url=""
assistant_save_profile
echo "Using $model_name on this Mac. Replies are generated locally."
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_URL="$ollama_url/v1" \
ASSISTANT_MODEL_NAME="$model_name" \
ASSISTANT_LOCAL_REASONING_EFFORT="${ASSISTANT_LOCAL_REASONING_EFFORT:-none}" \
bash scripts/start.sh
