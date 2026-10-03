#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
worker="$HOME/Library/Application Support/LocalProactiveAssistant/Models/LocalAssistantModel.app/Contents/MacOS/assistant-model-worker"
probe="$(mktemp "$HOME/.lpa-worker-probe.XXXXXX")"
response="$(mktemp)"
trap 'rm -f "$probe" "$response"' EXIT
printf '%s\n' 'public sandbox probe' > "$probe"
"$worker" --sandbox-check "$probe"
printf '%s\n' '{"operation":"availability"}' | "$worker" > "$response"
python3 - "$response" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
assert not result.get("failure"), result
assert isinstance(result["availability"]["ready"], bool), result
assert result["availability"]["detail"], result
print("Worker JSON availability contract passed.")
PY
status=0
.build/release/assistantctl model-status > "$response" || status=$?
cat "$response"
if [[ "$status" -gt 1 ]] || grep -q 'Signed model worker unavailable' "$response"; then
    echo 'Host could not verify or communicate with the installed worker.' >&2
    exit 1
fi
