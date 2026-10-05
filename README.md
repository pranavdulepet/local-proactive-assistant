# Local Proactive Assistant

**Turn your number into a personal, local AI assistant.**

Text your own number from your iPhone. Your Mac reads permitted local sources, searches for
relevant information, and answers in Messages using a model running on your hardware.
Messages is the conversation interface; the optional iPhone app adds permissioned phone context.
The Mac must remain awake, online, and running the host.

## Start

On a Mac signed into Messages:

```bash
git clone https://github.com/pranavdulepet/local-proactive-assistant.git
cd local-proactive-assistant
bash scripts/start.sh
```

Or [download the repository ZIP](https://github.com/pranavdulepet/local-proactive-assistant/archive/refs/heads/main.zip),
extract it, and open `scripts/Assistant.command`. If macOS prevents opening the launcher,
run `bash scripts/start.sh` in Terminal from the extracted folder.

The guided starter checks developer tools, installs the Messages helper, and remembers your
model choice. Choose a recommended Ollama model, Apple's on-device model, another local
Ollama model, or an existing local server. It pairs your private self-chat with a one-time code;
you never need to look up chat IDs. It also offers to prepare Mail, Notes, and Reminders access
on the Mac before you ask about them from your phone.

macOS controls source access. Allow Full Disk Access for your terminal, reopen it when asked,
and allow Automation for Messages, Mail, and Notes, plus the normal Reminders permission
for that source. This is currently a source build:
Swift 6-compatible developer tools are required. Apple's model additionally needs Apple
silicon, macOS 26+, Apple Intelligence, and Xcode 26+. A signed, downloadable host app is still
planned. See [installation and first text](docs/install.md).

## Choose a local model

`bash scripts/start.sh` reuses your saved model after the first run. To change it:

```bash
bash scripts/start.sh --choose-model
```

The Ollama recommendation leaves room for macOS and the assistant; weights still need
extra memory while running. These are starting points, not speed guarantees:

| Mac memory | Suggested Ollama model | Approximate weights |
| --- | --- | --- |
| 40 GB or more | Qwen3.8 27B Q4 | 18 GB |
| 16–39 GB | Qwen3.5 9B Q4 | 6.6 GB |
| 12–15 GB | Qwen3.5 4B Q4 | 3.4 GB |
| Less than 12 GB | Qwen3.5 2B | 2.7 GB |

You can still run `bash scripts/start-open-model.sh` directly. Set `ASSISTANT_OPEN_MODEL`
to a different local Ollama tag. Weights download once and remain on the Mac. The starter
installs Ollama if needed, disables its cloud features, and uses an owned loopback server on
port 11435 so an older desktop server cannot silently handle the new model.

For a model already running in another local runtime:

```bash
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_NAME=your-loaded-model \
ASSISTANT_MODEL_URL=http://127.0.0.1:1234/v1 \
bash scripts/start.sh
```

The runtime needs `/v1/chat/completions`, `/v1/models`, and structured JSON responses for
context planning. “OpenAI-compatible” describes that local protocol; it does not select a cloud
provider. Only literal loopback HTTP endpoints are accepted and redirects are blocked.
A local proxy can itself forward requests, so choose an offline runtime. Ollama cloud tags
are rejected. Stop the existing assistant before switching models.

## Current capabilities

The host keeps a bounded private conversation history, makes validated read requests, and
can refine a search before answering. It has no general-purpose shell tool and never lets
the model choose an outbound recipient. Source text is treated as data.

| Source | Current scope |
| --- | --- |
| Messages | Indexed one-to-one text history; coverage is reported |
| Calendar | Permissioned events in the refresh window |
| Contacts | Permissioned local contacts and identity joins |
| Apple Mail | Query-directed Inbox and mailbox searches; paged results and body excerpts |
| Notes | Title/body search across exposed notes, with inspection and result limits |
| Reminders | Native EventKit reads of synced lists, completion states and due dates |
| Local files | Supported formats within permitted roots; an extra folder can be added |
| Mac details | Fixed read-only device information |
| Phone context | Optional paired companion with derived HealthKit sleep context |

Ask naturally in the verified self-chat. Slow turns show native typing when the existing
transport supports it, otherwise one short progress acknowledgment. All progress and answers
use one verified phone route when available and carry an `Assistant:` label. Messages controls
bubble color; a self-chat cannot guarantee a distinct gray sender.

The transport has durable cursors, reconnect recovery, and an outbound ledger to prevent
self-reply loops. An unconfirmed send is not automatically resent. One opt-in commitment
reminder rule starts paused; `/resume` enables it, and `/pause` stops unsolicited reminders
while conversation commands keep working.

This remains a development-stage foreground host. The paired phone companion adds selected
phone context; it is not an independent iMessage responder. A signed host app and richer
phone-model choices remain planned. See [source access and coverage](docs/read-access.md),
[model and phone details](docs/local-models.md),
[storage](docs/m1-storage.md), and [host policy](docs/m1-host.md).

## Requirements

- Apple silicon or Intel Mac running macOS 14+
- Swift 6-compatible Command Line Tools or Xcode; Xcode 26+ for the Apple model or phone app
- Messages.app signed into iMessage
- [`imsg`](https://github.com/openclaw/imsg) installed
- Full Disk Access for the calling host/terminal
- Automation permission to control Messages.app
- Calendar full-access permission for the terminal or host running `assistantctl`
- Contacts permission for the terminal or host running `assistantctl`
- Automation permission for Mail and Notes, and Reminders permission, to connect those sources

Install `imsg`:

```bash
brew install steipete/tap/imsg
```

## Developer commands

```bash
swift test
swift run assistantctl doctor
swift run assistantctl chats
swift run assistantctl echo --chat-id <SELF_CHAT_ID>
swift run assistantctl index-messages --control-chat-id <SELF_CHAT_ID>
swift run assistantctl index-calendar
swift run assistantctl index-contacts
swift run assistantctl prepare-access
swift run assistantctl index-mail
swift run assistantctl source-status
swift run assistantctl meeting-context --person "<exact contact name>"
swift run assistantctl index-commitments --days 30
swift run assistantctl forgetting
swift run assistantctl serve --control-chat-id <SELF_CHAT_ID>
```

Only choose a private, one-to-one iMessage self-chat. The echo and control services never
choose a recipient. Verified self-chat aliases share one fixed reply route. Ordinary texts
start a local conversation, including calendar questions, and preserve follow-up context.
The host queues one final answer per turn; deterministic commands remain available during
generation. The last four exchanges are kept in a bounded private transcript. A
[separate assistant identity](https://github.com/pranavdulepet/local-proactive-assistant/issues/28)
is needed for a reliably distinct incoming sender. Send `/help` for commands.

`serve` refreshes Messages and commitments every 60 seconds after each completed scan, and
Calendar/Contacts every 15 minutes. Reminders start paused. `/resume` enables the one M1 rule;
`/pause` stops unsolicited reminders without disabling commands. `/status` reports the last
gate, submission state, source freshness and last checked Mail/Notes/Reminders access.
Access checks and search coverage are different: readable does not mean fully indexed.
Use `/meeting <exact person>` for indexed meeting
context. This is a foreground host: keep the Mac awake and the process running. Do not run the
echo test or manual indexers alongside it. See [docs/m1-host.md](docs/m1-host.md) for policy,
failure semantics and the focused device smoke test.

The CLI stores its state under `~/Library/Application Support/LocalProactiveAssistant/`. A Messages restart resumes from the newer of its checkpoint and an optional `--after <ROW_ID>` value; it never rewinds a saved cursor. Calendar refreshes cover 90 days in the past through 365 days in the future and report that window after each run.

For the full device test matrix, see [docs/p0-transport.md](docs/p0-transport.md).

## Design rules

- Source text is data, never policy.
- The model will never choose an outbound recipient.
- External actions stay structurally absent until the core is trustworthy.
- Structured queries come before RAG.
- Proactivity optimizes precision; silence is a feature.
- Every derived claim must retain evidence and provenance.

## Near-term plan

1. Use the assistant in Messages and connect the phone companion's sleep source. Review grounded
   answer usefulness, freshness and real network delivery while dogfooding.
2. Ship signed native host/login-item support so the Mac host does not need a foreground terminal.
3. Expand the on-phone model beyond Apple's system model and add phone-only sources where iOS permits.

The phone context companion queues updates when the Mac is unreachable and uses no cloud relay. The iMessage conversation relies on Apple's Messages delivery between your phone and Mac; that transport is not an on-prem network path. The optional phone companion has an on-device Apple model on supported iOS 26 devices while the app is open, with permissioned phone Calendar, Contacts, and Health context. It does not read iMessages or replace the Mac as the Messages responder. Model inference,
source storage, and reduction stay on user-controlled devices. This does not claim unattended
Mac lifecycle or immediate phone refresh while offline.

## License

Apache-2.0. Third-party tools and model weights keep their own licenses.
