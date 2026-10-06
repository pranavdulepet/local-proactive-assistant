#!/bin/bash
# Shared by the guided starters. Configuration is data, never executable shell.
assistant_support_dir="$HOME/Library/Application Support/LocalProactiveAssistant"
assistant_profile="$assistant_support_dir/model-profile.txt"

assistant_verbose() {
    [[ "${ASSISTANT_VERBOSE:-0}" == 1 || "${ASSISTANT_DEBUG:-0}" == 1 ]]
}

assistant_start_session() {
    umask 077
    mkdir -p "$assistant_support_dir/Logs"
    chmod 700 "$assistant_support_dir" "$assistant_support_dir/Logs"
    if [[ "${ASSISTANT_STARTUP_LOG:-}" != "$assistant_support_dir/Logs/"* \
        || ! -f "${ASSISTANT_STARTUP_LOG:-}" || -L "${ASSISTANT_STARTUP_LOG:-}" ]]; then
        ASSISTANT_STARTUP_LOG="$(mktemp "$assistant_support_dir/Logs/startup.XXXXXX")"
        export ASSISTANT_STARTUP_LOG
    fi
    if [[ "${ASSISTANT_STARTUP_BANNER:-0}" != 1 ]]; then
        printf 'Local assistant\n'
        export ASSISTANT_STARTUP_BANNER=1
    fi
}

assistant_stage() { printf '%s\n' "$1"; }

assistant_capture() {
    # Capture successful setup chatter; failures keep the actual diagnostic and log path.
    local task_log task_status=0
    task_log="$(mktemp "$assistant_support_dir/Logs/task.XXXXXX")"
    if assistant_verbose; then
        "$@" 2>&1 | tee "$task_log" || task_status=$?
    else
        "$@" >"$task_log" 2>&1 || task_status=$?
    fi
    cat "$task_log" >> "$ASSISTANT_STARTUP_LOG"
    if [[ "$task_status" -ne 0 ]] && ! assistant_verbose; then
        tail -n 12 "$task_log" >&2
    fi
    rm -f "$task_log"
    return "$task_status"
}

assistant_log_hint() { printf 'Details: %s\n' "$ASSISTANT_STARTUP_LOG" >&2; }

assistant_install_owned_ollama() {
    local runtime="$assistant_support_dir/Runtime/Ollama.app"
    local staging=""
    if [[ -L "$runtime" || ( -e "$runtime" && ! -d "$runtime" ) ]]; then
        echo "The assistant's Ollama runtime path is not an application folder. Move it aside before installing." >&2
        return 1
    fi
    mkdir -p "$assistant_support_dir/Runtime"
    chmod 700 "$assistant_support_dir/Runtime"
    staging="$(mktemp -d "$assistant_support_dir/Runtime/.ollama-download.XXXXXX")"
    assistant_install_staging="$staging"
    assistant_stage 'Installing Ollama...'
    if ! assistant_capture curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --show-error --location \
        https://ollama.com/download/Ollama-darwin.zip -o "$staging/Ollama.zip" \
        || ! assistant_capture ditto -x -k "$staging/Ollama.zip" "$staging" \
        || [[ -L "$staging/Ollama.app" || ! -x "$staging/Ollama.app/Contents/Resources/ollama" ]] \
        || ! assistant_capture codesign --verify --deep --strict "$staging/Ollama.app" \
        || ! assistant_capture spctl --assess --type execute "$staging/Ollama.app"; then
        rm -rf "$staging"
        assistant_install_staging=""
        echo "Ollama could not be installed or verified. Install it from https://ollama.com/download and rerun." >&2
        assistant_log_hint
        return 1
    fi
    if [[ -d "$runtime" ]] && ! mv "$runtime" "$staging/previous.app"; then
        rm -rf "$staging"
        assistant_install_staging=""
        echo "The existing Ollama runtime could not be replaced; it has been kept." >&2
        return 1
    fi
    if ! mv "$staging/Ollama.app" "$runtime"; then
        if [[ -d "$staging/previous.app" ]] && ! mv "$staging/previous.app" "$runtime"; then
            # Preserve the backup if a filesystem failure also prevents restoration.
            assistant_install_staging=""
            echo "Ollama installation stopped. The previous runtime is saved at $staging/previous.app." >&2
            return 1
        fi
        rm -rf "$staging"
        assistant_install_staging=""
        echo "Ollama installation stopped. The previous runtime has been restored." >&2
        return 1
    fi
    rm -rf "$staging"
    assistant_install_staging=""
}

assistant_model_label() {
    case "$model_choice" in
        apple) printf '%s\n' 'Apple on-device model' ;;
        ollama|local)
            if assistant_valid_model_name "$model_name"; then printf '%s\n' "$model_name"
            else printf '%s\n' 'unconfigured local model'; fi ;;
    esac
}

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
    if [[ ! -t 0 && "${NONINTERACTIVE:-0}" != 1 ]]; then
        echo "Homebrew is needed for the Messages helper. Run this starter in Terminal to install it." >&2
        return 1
    fi
    echo "Installing Homebrew, the supported installer for the Messages helper."
    echo "Homebrew may ask for your Mac password and its installation confirmation."
    local installer install_status=0
    installer="$(mktemp "${TMPDIR:-/tmp}/local-assistant-homebrew.XXXXXX")"
    if ! assistant_capture curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --show-error --location \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then
        rm -f "$installer"
        echo "Homebrew download failed. Check your connection and rerun this starter." >&2
        return 1
    fi
    # Homebrew's own interactive confirmation/password prompts must remain visible.
    if [[ -t 0 ]]; then
        /bin/bash "$installer" || install_status=$?
    else
        assistant_capture /bin/bash "$installer" || install_status=$?
    fi
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
        assistant_stage 'Installing Messages support...'
        if ! assistant_capture brew install steipete/tap/imsg; then
            assistant_log_hint
            return 1
        fi
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
    [[ -n "$1" && ${#1} -le 200 && "$1" != *[$'\001'-$'\037'$'\177']* && "$1" != *:cloud* && "$1" != *-cloud* ]]
}

assistant_load_profile() {
    [[ -f "$assistant_profile" && ! -L "$assistant_profile" && -s "$assistant_profile" ]] || return 1
    [[ "$(wc -c < "$assistant_profile")" -le 4096 ]] || return 1
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
    if [[ -L "$assistant_profile" || ( -e "$assistant_profile" && ! -f "$assistant_profile" ) ]]; then
        echo "The model settings path is not a regular file. Move it aside before choosing a model." >&2
        return 1
    fi
    mkdir -p "$assistant_support_dir"
    chmod 700 "$assistant_support_dir"
    local staging
    staging="$(mktemp "$assistant_support_dir/.model-profile.XXXXXX")"
    printf '1\n%s\n%s\n%s\n' "$model_choice" "$model_name" "$model_url" > "$staging"
    chmod 600 "$staging"
    if ! mv "$staging" "$assistant_profile"; then
        rm -f "$staging"
        echo "The model choice could not be saved. Check permissions for $assistant_support_dir." >&2
        return 1
    fi
}

assistant_mark_access_prepared() {
    local marker="$assistant_support_dir/access-prepared-v3.txt" staging
    if [[ -L "$marker" || ( -e "$marker" && ! -f "$marker" ) ]]; then
        echo "Source access was granted, but the preparation marker could not be saved." >&2
        return 1
    fi
    staging="$(mktemp "$assistant_support_dir/.access-prepared.XXXXXX")"
    printf '3\n' > "$staging"
    if ! mv "$staging" "$marker"; then
        rm -f "$staging"
        echo "Source access was granted, but its setup state could not be saved." >&2
        return 1
    fi
}

assistant_access_prepared() {
    local marker="$assistant_support_dir/access-prepared-v3.txt"
    [[ -f "$marker" && ! -L "$marker" && "$(wc -c < "$marker")" -eq 2 ]] || return 1
    [[ "$(cat "$marker")" == 3 ]]
}

assistant_choose_model() {
    local suggested memory_gb selection
    suggested="$(assistant_suggest_model)"
    memory_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    printf '\nChoose a model for this %s GB Mac:\n' "$memory_gb"
    printf '  1. %s via Ollama (recommended)\n' "$suggested"
    printf '  2. Apple on-device model\n'
    printf '  3. Another local Ollama model\n'
    printf '  4. A model already running on this Mac\n'
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
    echo "Model saved. Change it with bash scripts/start.sh --choose-model."
}
