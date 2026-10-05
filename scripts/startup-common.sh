#!/bin/bash
# Shared by the guided starters. Configuration is data, never executable shell.
assistant_support_dir="$HOME/Library/Application Support/LocalProactiveAssistant"
assistant_profile="$assistant_support_dir/model-profile.txt"

assistant_require_mac() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo "This assistant runs on a Mac signed into Messages.app." >&2
        return 1
    fi
    local major
    major="$(sw_vers -productVersion | cut -d . -f 1)"
    if [[ ! "$major" =~ ^[0-9]+$ || "$major" -lt 14 ]]; then
        echo "Update this Mac to macOS 14 or newer, then rerun bash scripts/start.sh." >&2
        return 1
    fi
}

assistant_find_brew() {
    if command -v brew >/dev/null 2>&1; then return 0; fi
    local brew_path
    for brew_path in /opt/homebrew/bin /usr/local/bin; do
        if [[ -x "$brew_path/brew" ]]; then
            export PATH="$brew_path:$PATH"
            return 0
        fi
    done
    return 1
}

assistant_install_brew() {
    if assistant_find_brew; then return 0; fi
    echo "Installing Homebrew, the supported installer for the Messages helper."
    echo "Homebrew may ask for your Mac password and its installation confirmation."
    local installer install_status=0
    installer="$(mktemp "${TMPDIR:-/tmp}/local-assistant-homebrew.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 --fail --show-error --location \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then
        rm -f "$installer"
        echo "Homebrew download failed. Check your connection and rerun this starter." >&2
        return 1
    fi
    /bin/bash "$installer" || install_status=$?
    rm -f "$installer"
    if [[ "$install_status" -ne 0 ]] || ! assistant_find_brew; then
        echo "Finish Homebrew installation at https://brew.sh, then rerun this starter." >&2
        return 1
    fi
}

assistant_require_swift() {
    # Use an installed Xcode without changing the global developer selection.
    if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
        local xcode_version
        xcode_version="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version 2>/dev/null | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
        if [[ "$xcode_version" =~ ^[0-9]+$ && "$xcode_version" -ge 26 ]]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        fi
    fi
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Installing Apple's developer tools. Complete the macOS dialog, then rerun this starter."
        xcode-select --install 2>/dev/null || true
        return 1
    fi
    local swift_version swift_major
    swift_version="$(swift --version 2>/dev/null)" || {
        echo "Accept the Xcode license or finish Command Line Tools installation, then rerun." >&2
        return 1
    }
    swift_major="$(printf '%s\n' "$swift_version" | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
    if [[ ! "$swift_major" =~ ^[0-9]+$ || "$swift_major" -lt 6 ]]; then
        echo "This source build needs Swift 6+. Install current Command Line Tools or Xcode from Apple, then rerun." >&2
        return 1
    fi
}

assistant_require_prerequisites() {
    assistant_require_mac || return 1
    assistant_require_swift || return 1
    if ! command -v imsg >/dev/null 2>&1; then
        assistant_install_brew || return 1
        brew install steipete/tap/imsg || return 1
    fi
}

assistant_apple_eligible() {
    [[ "$(uname -m)" == arm64 ]] || return 1
    [[ "$(sw_vers -productVersion | cut -d . -f 1)" -ge 26 ]] || return 1
    local major
    major="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
    [[ "$major" =~ ^[0-9]+$ && "$major" -ge 26 ]]
}

assistant_suggest_model() {
    local memory_gb
    memory_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    if [[ "$memory_gb" -ge 40 ]]; then printf '%s\n' qwen3.8:27b-q4_K_M
    elif [[ "$memory_gb" -ge 16 ]]; then printf '%s\n' qwen3.5:9b-q4_K_M
    elif [[ "$memory_gb" -ge 12 ]]; then printf '%s\n' qwen3.5:4b-q4_K_M
    else printf '%s\n' qwen3.5:2b; fi
}

assistant_valid_tag() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ && ${#1} -le 200 && "$1" != *:cloud* && "$1" != *-cloud* ]]
}

assistant_valid_endpoint() {
    [[ "$1" =~ ^http://(127\.0\.0\.1|\[::1\]):([0-9]{1,5})/v1/?$ ]] || return 1
    local port="${BASH_REMATCH[2]}"
    [[ "$((10#$port))" -ge 1 && "$((10#$port))" -le 65535 ]]
}

assistant_valid_model_name() {
    [[ -n "$1" && ${#1} -le 200 && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *:cloud* && "$1" != *-cloud* ]]
}

assistant_load_profile() {
    [[ -s "$assistant_profile" ]] || return 1
    local version extra
    {
        IFS= read -r version || return 1
        IFS= read -r model_choice || return 1
        IFS= read -r model_name || return 1
        IFS= read -r model_url || return 1
        if IFS= read -r extra; then return 1; fi
    } < "$assistant_profile"
    [[ "$version" == 1 ]] || return 1
    case "$model_choice" in
        apple) [[ -z "$model_name" && -z "$model_url" ]] ;;
        ollama) assistant_valid_tag "$model_name" && [[ -z "$model_url" ]] ;;
        local) assistant_valid_model_name "$model_name" && assistant_valid_endpoint "$model_url" ;;
        *) return 1 ;;
    esac
}

assistant_save_profile() {
    mkdir -p "$assistant_support_dir"
    chmod 700 "$assistant_support_dir"
    local staging
    staging="$(mktemp "$assistant_support_dir/.model-profile.XXXXXX")"
    printf '1\n%s\n%s\n%s\n' "$model_choice" "$model_name" "$model_url" > "$staging"
    chmod 600 "$staging"
    mv "$staging" "$assistant_profile"
}

assistant_choose_model() {
    local suggested memory_gb selection
    suggested="$(assistant_suggest_model)"
    memory_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    printf '\nTurn your number into a personal, local AI assistant.\n'
    printf 'This Mac has %s GB of memory. Choose how it answers your texts:\n' "$memory_gb"
    printf '  1. Ollama + %s (recommended; download once)\n' "$suggested"
    printf '  2. Apple on-device model (no extra weights; Apple Intelligence and Xcode 26 required)\n'
    printf '  3. Another Ollama model (paste an installed or downloadable local model tag)\n'
    printf '  4. Your existing local model server (literal loopback endpoint)\n'
    if [[ ! -t 0 ]]; then
        echo "First-run model choice needs a terminal. Run interactively, or set ASSISTANT_MODEL explicitly." >&2
        return 1
    fi
    while true; do
        IFS= read -r -p "Model [1]: " selection || return 1
        case "${selection:-1}" in
            1) model_choice=ollama; model_name="$suggested"; model_url=""; break ;;
            2)
                if ! assistant_apple_eligible; then
                    echo "Apple's model needs Apple silicon, macOS 26+, and Xcode 26+. Choose Ollama or update first."
                    continue
                fi
                model_choice=apple; model_name=""; model_url=""; break ;;
            3)
                IFS= read -r -p "Local Ollama model tag: " model_name || return 1
                if ! assistant_valid_tag "$model_name"; then echo "Use a local Ollama tag such as qwen3.5:9b-q4_K_M."; continue; fi
                model_choice=ollama; model_url=""; break ;;
            4)
                IFS= read -r -p "Local server URL [http://127.0.0.1:11434/v1]: " model_url || return 1
                model_url="${model_url:-http://127.0.0.1:11434/v1}"
                IFS= read -r -p "Loaded model name: " model_name || return 1
                if ! assistant_valid_endpoint "$model_url" || ! assistant_valid_model_name "$model_name"; then
                    echo "Use a loaded local model and http://127.0.0.1:<port>/v1 or http://[::1]:<port>/v1."
                    continue
                fi
                model_choice=local; break ;;
            *) echo "Choose 1, 2, 3, or 4." ;;
        esac
    done
    assistant_save_profile
    echo "Saved your model choice. Change it with bash scripts/start.sh --choose-model."
}
