# Setup

Use a Mac with macOS 14 or later and Swift 6-compatible developer tools. Sign into
Messages with the same Apple Account as your iPhone. Keep the Mac awake and online
while the assistant runs. Read [Privacy](../PRIVACY.md) before connecting sources.

## Start in Terminal

Choose **Code → Download ZIP**, unzip it, and open Terminal in the source folder:

```bash
bash scripts/start.sh
```

Or copy the HTTPS URL from **Code** and clone it:

```bash
git clone YOUR_REPOSITORY_URL local-proactive-assistant
cd local-proactive-assistant
bash scripts/start.sh
```

Follow the prompts to:

1. Install Apple's developer tools if needed, then rerun the starter.
2. Install the Messages helper through Homebrew. Homebrew may ask for your Mac password.
3. Choose a local model. Setup installs Ollama if selected and downloads missing weights.
4. Give your Terminal app **Full Disk Access** in System Settings → Privacy & Security.
   Quit and reopen Terminal after changing access, then rerun the starter. If another
   app launches the command, that app needs its own grant.
5. Send the exact `LOCAL-...` pairing code from your iPhone to your one-to-one self-chat.
   Confirm the chat found on your Mac.
6. Approve the sources you want to connect. You can skip optional sources.

Leave the assistant running. Approve Messages Automation when asked, then send `/status`
to the same self-chat from your iPhone. Try “What's on my calendar tomorrow?”
Stop the Terminal assistant with Control-C.

## Install the menu bar app

After completing Terminal setup, stop the assistant and run:

```bash
bash scripts/install-mac-app.sh
```

The installer opens `~/Applications/LocalAssistant.app`. The app reuses your saved model
and self-chat setup. Terminal and the source folder are no longer needed to run it;
Ollama and its model weights remain installed separately.

1. Give **Local Assistant** Full Disk Access, then quit and reopen it.
2. Choose **Connect** under Source access and approve the sources you want to use.
   The app's grants are separate from Terminal's grants.
3. Start the assistant and send `/status` from your iPhone.
4. Enable **Start at login** if wanted. Approve it in Login Items if macOS asks.

The control window and menu bar icon let you start or stop the assistant, change source
access, add file folders, pair the optional iPhone app, and open logs. Keep the Mac logged
in and online. Closing the lid can put it to sleep and interrupt replies.

## Models and sources

See [model setup](local-models.md) to change the Mac model or pair the optional iPhone app.
The iPhone app is not needed to chat through Messages.

See [source access](read-access.md) for permissions and supported content.
To add a folder when starting from Terminal:

```bash
ASSISTANT_READ_ROOT="$HOME/My Work" bash scripts/start.sh
```

For multiple folders, pass repeated `--read-root <folder>` arguments to
`assistantctl serve`. In the menu bar app, stop the assistant before adding folders.

## Troubleshooting

If a source is unavailable, use **Connect** in the app and check Privacy & Security.
For a Terminal setup, retry access with:

```bash
.build/release/assistantctl prepare-access
```

This checks access without printing source contents. Send `/status` to see which sources
are available and when they last synced.

For startup errors, use **Open log folder** in the app or run:

```bash
bash scripts/start.sh --verbose
```

Read logs before sharing them; they may contain personal information.

## Update

Quit the app. Download the current source through **Code → Download ZIP**, extract it into
a separate folder, and run `bash scripts/install-mac-app.sh`. Your saved application data
is reused. Preserve any local source edits before replacing a checkout.

Each build is signed locally. If Full Disk Access appears enabled but reads fail after an
update, remove the old Local Assistant entry, add the newly installed app, then quit and
reopen it. Approve any renewed source permissions when asked.

[Everyday use](use.md) · [Privacy and removal](../PRIVACY.md)
