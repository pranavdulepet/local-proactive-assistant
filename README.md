# Local Assistant

**Turn your number into a personal, local AI assistant.**

Text your Messages self-chat from your iPhone. Your Mac runs the main model, reads connected
personal sources, and answers in Messages. An optional iPhone companion contributes phone
context and can run its own small local model. Generation and source storage stay on your
devices; normal iMessage delivery uses Apple's service.

## Install and start

On your Mac, signed into Messages:

```bash
git clone https://github.com/pranavdulepet/local-proactive-assistant.git
cd local-proactive-assistant
bash scripts/start.sh
```

The starter installs the Messages helper and Ollama when needed, offers local model choices,
and pairs your self-chat with a one-time code. Allow the requested macOS source permissions.
No numeric chat ID is needed. The first model download is reused on later starts.
You can also [download the source ZIP](https://github.com/pranavdulepet/local-proactive-assistant/archive/refs/heads/main.zip)
and open `scripts/Assistant.command`.

After choosing a model and pairing, install the menu bar host:

```bash
# Stop the Terminal host with Control-C first.
bash scripts/install-mac-app.sh
```

Open **Local Assistant**, grant it its own Full Disk Access and source permissions, and click
**Start**. Its menu shows running status, connected sources, permitted document folders,
recent activity and **Start at login**. It supervises the host and its own local Ollama process,
and keeps the open Mac awake while serving. You can close Terminal. The Mac must remain
logged in and online; closing the lid can stop replies.

This is a source installation requiring Swift 6 developer tools. The app is locally signed;
a notarized, Developer ID signed public download is not yet published. Apple inference and
iPhone builds require Xcode 26+. See [setup and first text](docs/install.md).

## Text it naturally

Send `/status` from your phone to the paired self-chat, then try:

- “What's on my calendar tomorrow?” followed by “What about the next day?”
- “What did Asmitha Sathya say last?” using a real contact's full name.
- “Any important unread emails I should read?”
- “Find my launch notes and compare them with tomorrow's meeting.”
- “What unfinished reminders should I prioritize?”

The agent keeps conversation and tool results together. Older owner messages stay searchable
in the local index after leaving recent history; generated replies are not indexed as facts.
It can resolve people, search exact
date intervals, read another source or page, and answer with source references. Short ordinary
conversation can finish in one model response. Missing source access is reported. Replies use
one verified route and the `Assistant:` label. Apple's shared-account self-chat controls bubble
color; a distinct gray sender requires a different account or device identity.

Slow turns use the transport's typing feature where available; otherwise they get one brief
progress message. The outbound ledger reconciles actual outgoing Messages rows across verified
phone/email aliases after timeouts. It never automatically resends a potentially submitted reply.
A local submission record is separate from physical phone delivery.

## Connected sources

| Source | Available information |
| --- | --- |
| Messages | Indexed direct text; people, incoming/outgoing, dates and topic filters |
| Calendar | Events overlapping requested dates, including overnight/all-day events |
| Contacts | Name, nickname, phone and email identity resolution |
| Apple Mail | Current Inbox and account-folder queries, selected bodies and paging |
| Notes | Exposed titles and plain-text content |
| Reminders | Synced lists, completion state, due dates and notes |
| Photos | Permitted asset metadata: dates, media type, dimensions, albums and coarse location |
| Documents | Supported local formats in permitted folders, with native folder selection |
| Mac information | Hardware and OS metadata |
| iPhone companion | Opt-in sleep/activity summaries and coarse location uploads; phone Calendar/Contacts in local phone chat |

Read [source coverage and platform limits](docs/read-access.md). These connectors provide
actual permitted reads; they do not imply unrestricted access to every app, account or file.
The model has no shell or source-writing tool. A source record cannot change the response
recipient or host policy.

## Bring your own local model

Stop the Mac app or Terminal host before changing the saved model:

```bash
bash scripts/start.sh --choose-model
```

Choose Apple, the suggested Ollama model, another local Ollama tag, or an existing offline
model server. The memory-based suggestions are starting points, not measured quality rankings:

| Mac memory | Suggested Ollama model |
| --- | --- |
| 40 GB+ | Qwen3.8 27B Q4 |
| 16–39 GB | Qwen3.5 9B Q4 |
| 12–15 GB | Qwen3.5 4B Q4 |
| Under 12 GB | Qwen3.5 2B |

Ollama uses its native tool-calling API at the owned loopback server `127.0.0.1:11435`, with
cloud features disabled and installed local model verification. The agent uses a bounded
16K context and disables optional thinking for ordinary chat. Use a tool-capable model for
personal-source questions. Another offline runtime can use `/v1` function tools; that protocol
name does not select OpenAI or a cloud provider. Apple runs in the sandboxed on-device worker
and needs Apple Intelligence on macOS 26+.

See [Mac and phone model setup](docs/local-models.md) and [runtime design and research](docs/agent-runtime.md).

## Host controls

`/status` shows source freshness, access and the reply queue. `/pause` stops unsolicited reminders;
`/resume` enables the one-per-day due-commitment rule. Ordinary conversation always works when
a model is ready. `/help` lists the other commands. Proactive reminders start paused.

CI builds the Mac modules, native app and iPhone app, and exercises source queries, protocol
interoperability, durable follow-ups and recovery. Physical-device latency, Mail behavior,
away-from-home context sync and an unattended 24-hour run still require recorded validation.
Those results determine release readiness.

## Development

```bash
swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
bash scripts/test-mac-host.sh
```

The native host and Apple app integrations require macOS. Architecture details are in
[storage](docs/m1-storage.md) and [host policy](docs/m1-host.md).
