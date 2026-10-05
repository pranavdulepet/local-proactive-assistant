#!/bin/bash
# Double-click after downloading and extracting the repository ZIP.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$repo_root/scripts/start.sh"
status=$?
if [[ "$status" -eq 130 || "$status" -eq 143 ]]; then
    printf '\nAssistant stopped. Open this launcher again to resume.\n'
elif [[ "$status" -ne 0 ]]; then
    printf '\nFollow the message above, then open this launcher again.\n'
    read -r -p "Press Return to close this window. " _
fi
exit "$status"
