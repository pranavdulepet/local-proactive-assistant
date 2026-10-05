# Turn your number into a personal, local AI assistant

Your phone is the Messages interface. Your Mac is the main source and model engine. You can
text the assistant from anywhere iMessage works while the Mac remains online and serving.
Model requests and personal-source storage stay on your devices; Messages delivery uses
Apple's service.

## Get it running

On a Mac signed into the same Messages account as your iPhone:

```bash
git clone https://github.com/pranavdulepet/local-proactive-assistant.git
cd local-proactive-assistant
bash scripts/start.sh
```

If you prefer downloading, extract the
[repository ZIP](https://github.com/pranavdulepet/local-proactive-assistant/archive/refs/heads/main.zip)
and open `scripts/Assistant.command`. If the launcher is blocked, open Terminal in the
extracted folder and run `bash scripts/start.sh`.

The starter walks through these steps:

1. Check macOS 14+ and Swift 6-compatible developer tools. If tools are missing, it opens
   Apple's Command Line Tools installation dialog. Complete it and rerun the same starter.
2. Install `imsg`, the Messages helper. If Homebrew is missing, it runs Homebrew's official
   installer first; Homebrew may request your Mac password and installation confirmation.
3. Choose a local model. The starter saves your choice and installs Ollama when selected.
   The first model download may be large; later starts reuse the weights.
4. Allow your terminal Full Disk Access in System Settings. Quit and reopen the terminal
   after changing that permission, then rerun the starter.
5. Send the exact one-time `LOCAL-...` pairing code from your iPhone to your private
   one-to-one self-chat. Confirm the chat found on the Mac. Phone and email aliases are
   resolved by the host; you do not enter a numeric chat ID.
6. Choose whether to connect Mail, Notes, and Reminders now. Allow the prompts on your Mac.
   You may skip or deny a source and still chat; it remains unavailable until permission is
   granted. The assistant also requests Calendar and Contacts access as it refreshes them.
7. Leave the host running. The first reply may request Automation permission for Messages.

Send `/status` to that same self-chat from your iPhone. Then ask naturally, for example:

> What should I prepare for tomorrow, based on my calendar and recent emails?

The host can make bounded read requests and refine its searches before answering. Each
source has its own scope and permission. A sampled Inbox, indexed Messages window, or
file search is not proof that every item on the Mac has been read. If access is missing or
evidence is insufficient, the answer should say so. Reading local files is limited to
permitted roots and supported formats. To add a local folder to a starter run:

```bash
ASSISTANT_READ_ROOT="$HOME/My Work" bash scripts/start.sh
```

The same setting works with the open-model starter. For multiple extra folders, pass
repeated `--read-root <folder>` arguments to `assistantctl serve` directly. macOS may ask
for Documents, Desktop, or other folder permissions.

Replies can appear blue or gray because the host sends through your own Messages account
to your own self-chat. The host does not control bubble color. It shows native typing when
the installed transport already supports it; otherwise a slow turn gets one short progress
message. The ordinary setup does not require private Messages framework changes.

## Model choices

On first start, choose from:

| Choice | What runs on the Mac |
| --- | --- |
| Recommended Ollama model | A local open-weight model selected for installed memory |
| Apple | Apple's system model, with no separate weight download |
| Another Ollama model | The local model tag you enter, downloaded only if missing |
| Existing local server | The loaded model and literal loopback endpoint you enter |

Apple needs Apple silicon, macOS 26+, Apple Intelligence enabled, and Xcode 26+. The host
reports when that model is still preparing; it does not silently start a chat assistant with
no ready model. Ollama can use macOS 14+ with Swift 6-compatible developer tools. Intel
Macs run Ollama on the CPU and may answer considerably more slowly.

Stop the current host with Control-C, then change the saved choice:

```bash
bash scripts/start.sh --choose-model
```

For the 48 GB Mac, the suggested model is Qwen3.8 27B Q4, about 18 GB of downloaded
weights. Smaller Macs get Qwen3.5 9B Q4, 4B Q4, or 2B. Running a model uses more memory
than its weight file; choose a smaller one if other apps or your chosen context size create
memory pressure. These recommendations are a starting point, not a conversational benchmark.

`bash scripts/start-open-model.sh` remains a shortcut for the recommended Ollama model.
Set `ASSISTANT_OPEN_MODEL=<local-tag>` to choose another; that choice is remembered too.
The assistant owns a separate Ollama server at `127.0.0.1:11435` with cloud features disabled.
It prints the executable and server version and retries a required runtime update once.
It stops only the server it started, leaving other Ollama apps/services alone.

If Ollama is absent and Homebrew exists, it installs the Homebrew formula. Otherwise it
downloads Ollama's official macOS app into the assistant's private runtime directory and
verifies its code signature and Gatekeeper assessment before using its bundled CLI.
It does not execute Ollama's remote shell installer.

Existing local runtimes must implement the local `/v1` chat and model-list protocol plus
structured JSON responses for read planning. Use `http://127.0.0.1:<port>/v1` or
`http://[::1]:<port>/v1`. Remote hosts, credentials, redirects, query strings, and cloud model
tags are rejected by the guided setup. A proxy on your Mac can still forward requests;
use a runtime you control and configure it for offline inference.

## Restart and access

Later starts only need:

```bash
bash scripts/start.sh
```

Your pairing, model selection, transcript, and source state are saved under
`~/Library/Application Support/LocalProactiveAssistant/`. The model profile is plain data,
not shell code. The starter keeps an open Mac awake while serving; closing the lid can
still put it to sleep. This remains a foreground host. A signed downloadable host with a
login item is planned, and the current ZIP is a source download rather than that app.

If you skipped source preparation, run this on the Mac:

```bash
.build/release/assistantctl prepare-access
```

That command probes read access without printing personal content. Grant Automation for
Mail and Notes, and Reminders permission when requested. It writes no emails, notes, or
reminders. The guided starter remembers successful preparation; a failed or skipped setup
does not mark access complete. `ASSISTANT_SKIP_ACCESS_SETUP=1 bash scripts/start.sh`
skips this step for a run. `/status` reports what the host has actually synced.

For phone-only data, pair the optional iPhone companion described in
[local-models.md](local-models.md). The companion currently uses Apple's on-device model
on supported iOS 26 devices while the app is open. It contributes permissioned phone
context, and the Mac remains the Messages responder. It does not read every iPhone app.

## Installation sources

- [Ollama macOS requirements and application paths](https://docs.ollama.com/macos)
- [Ollama official macOS download implementation](https://github.com/ollama/ollama/blob/main/scripts/install.sh)
- [Ollama Homebrew formula](https://formulae.brew.sh/formula/ollama)
- [Qwen3.8 27B Q4 weights](https://ollama.com/library/qwen3.8:27b-q4_K_M)
- [Qwen3.5 model tags](https://ollama.com/library/qwen3.5/tags)
- [imsg supported installation](https://github.com/openclaw/imsg/blob/main/docs/install.md)
- [Homebrew official installer](https://github.com/Homebrew/install)
