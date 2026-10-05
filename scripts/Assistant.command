#!/bin/bash
# Double-click after downloading and extracting the repository ZIP.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$repo_root/scripts/start.sh"
status=$?
if [[ "$status" -ne 0 ]]; then
    printf '\nSetup stopped. Follow the message above, then double-click this file again.\n'
    read -r -p "Press Return to close this window. " _
fi
exit "$status"
