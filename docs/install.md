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
6. Choose whether to connect additional sources now. Mail and Notes use macOS
   Automation prompts; Reminders uses the normal Reminders permission dialog. You can
   skip or deny a source and still chat. Calendar, Contacts, and Photos request their own permissions.
7. Leave the host running. The first reply may request Automation permission for Messages.

Send `/status` to that same self-chat from your iPhone. Then ask naturally, for example:

> What should I prepare for tomorrow, based on my calendar and recent emails?

The host can search more than one source and refine a search before answering. Mail queries
search locally synced account folders and return a bounded set of matches; they do not search
only the first 100 messages. Attachments are not included, and a bounded query does not claim
that every mailbox item has been scanned. Messages queries use the indexed history, and
files use permitted folders and supported formats.
The answer reports missing access or insufficient evidence. To add a local folder:

```bash
ASSISTANT_READ_ROOT="$HOME/My Work" bash scripts/start.sh
```

The same setting works with the open-model starter. For multiple extra folders, pass
repeated `--read-root <folder>` arguments to `assistantctl serve` directly. macOS may ask
for Documents, Desktop, or other folder permissions.

Replies start with `Assistant:` and use one verified self-chat route, preferring your phone
number when available. Messages controls
whether they appear blue or gray because both sides use your account. Native typing is used
when the existing transport supports it; otherwise a slow turn gets one short progress
message. Setup does not require
private Messages framework changes.

## Use the Mac menu bar app

After the guided starter has saved your model choice and paired your phone, stop the
Terminal host with Control-C and install the native host:

```bash
bash scripts/install-mac-app.sh
```

It builds and installs `~/Applications/LocalAssistant.app`, bundles the Messages helper
and assistant runtime, and opens the app. Later, double-click **LocalAssistant** in your
Applications folder. The app starts your saved local model and Messages listener directly;
you do not need to keep Terminal open or keep the repository folder after installation.
Ollama and its downloaded weights remain installed separately on your Mac.

Click the speech-bubble icon in the menu bar to:

- Start or stop the host, and see its observed readiness and selected model.
- Review source access with timestamps, refresh indexed coverage, and connect sources.
- Add additional permitted file folders while the host is stopped.
- View recent activity and open private log files.
- Enable **Start at login**. If macOS asks, approve Local Assistant in Login Items.

Allow **Local Assistant** Full Disk Access in Privacy & Security, then quit and reopen the
app. Its Mail, Notes, Messages, Calendar, Contacts, Reminders, and Photos permissions can
differ from the earlier Terminal grants. Use **Connect** in the app to request optional
source access before asking about those sources from your phone. Denied sources are
reported; they do not prevent ordinary chat once Messages and the model are ready.

The app keeps an open Mac awake while serving. Keep the Mac online; closing the lid can
still interrupt replies. It restarts a host that exits unexpectedly after becoming ready,
with three attempts, and stops with an actionable status if startup fails. Stop and Quit
terminate the processes the app owns, including its separate local Ollama server. They
leave other Ollama instances alone. Stop a Terminal host before launching this app.

This is a source-built, ad-hoc signed app. It is not a Developer ID signed, notarized
download. The first model choice, model download, and phone pairing still use the guided
starter; the native app currently reuses that completed setup. Updates can require renewed
macOS access grants. To update, quit the app, pull the repository changes, and run the same
installer. A failed signed package replacement restores the previous app and model worker.

For packaging without changing your installed worker or launching the host:

```bash
bash scripts/install-mac-app.sh --build-only --output "$HOME/Desktop/LocalAssistant.app"
```

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
It checks that the listener belongs to the process it started and retries a required runtime
update once. It stops only that server, leaving other Ollama apps/services alone. A verified
update is staged before replacing the private runtime; a failed replacement restores the
previous installation.

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

Normal startup shows short stages for the model, build, and Messages access. Successful
compiler and dependency output is saved in private setup logs. A failed step shows its
diagnostic and the log path. For setup details and host diagnostics:

```bash
bash scripts/start.sh --verbose
```

`--verbose` also works with the open-model starter. `ASSISTANT_DEBUG=1` enables the same
details plus transport debugging. It includes the actual Ollama executable and server
version. An interactive terminal is required for the first model choice, chat pairing,
and Homebrew installation. Saved setups can run without a terminal; use explicit model
settings if there is no saved choice. Homebrew's official `NONINTERACTIVE=1` option is
respected when deliberately set.

Your pairing, model selection, transcript, and source state are saved under
`~/Library/Application Support/LocalProactiveAssistant/`. The model profile is plain data,
not shell code. The starter keeps an open Mac awake while serving; closing the lid can
still put it to sleep. The Terminal starter remains a foreground host. The native menu bar
app can run without Terminal and can register itself as a login item. The current repository
ZIP is a source download, not a notarized app installer.

If you skipped source preparation, run this on the Mac:

```bash
.build/release/assistantctl prepare-access
```

That command probes read access without printing personal content. Grant Automation for
Mail and Notes, and the normal Reminders permission when requested. It writes no emails, notes, or
reminders. The guided starter remembers successful preparation; a failed or skipped setup
does not mark access complete. Upgrading from the earlier Reminders Automation integration
prepares the new native Reminders permission once. `ASSISTANT_SKIP_ACCESS_SETUP=1 bash scripts/start.sh`
skips this step for a run. `/status` reports source access and sync freshness.

For phone-only data and on-device phone models, pair the optional iPhone companion described
in [local-models.md](local-models.md). It contributes permissioned phone context, and the
Mac remains the Messages responder. iOS grants access by source; it does not expose every app.

## Installation sources

- [Ollama macOS requirements and application paths](https://docs.ollama.com/macos)
- [Ollama official macOS download implementation](https://github.com/ollama/ollama/blob/main/scripts/install.sh)
- [Ollama Homebrew formula](https://formulae.brew.sh/formula/ollama)
- [Qwen3.8 27B Q4 weights](https://ollama.com/library/qwen3.8:27b-q4_K_M)
- [Qwen3.5 model tags](https://ollama.com/library/qwen3.5/tags)
- [imsg supported installation](https://github.com/openclaw/imsg/blob/main/docs/install.md)
- [Homebrew official installer](https://github.com/Homebrew/install)
- [Apple supported main-app login registration](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
