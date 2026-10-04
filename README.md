# Local Proactive Assistant

A local-first macOS assistant that tracks loose ends and eventually sends a small number of evidence-backed iMessages. Personal-source indexing and model inference stay on user-controlled Apple hardware.

This repository started with a reliable self-chat transport loop. It now has read-only
Messages, Calendar and Contacts ingestion, bounded Mac-local answers, and a phone source
companion. **Messages is the main conversation interface.** The Mac answers through
Messages. The optional phone app can answer locally while open on a supported iPhone and
shares selected derived sleep context with its paired Mac.

## Quick start

On a Mac signed into Messages, clone the repository and run the guided starter:

```bash
git clone https://github.com/pranavdulepet/local-proactive-assistant.git
cd local-proactive-assistant
bash scripts/start.sh
```

The first run checks prerequisites, builds the local worker, and asks you to send a one-time
pairing code to your iMessage self-chat. Confirm the chat it finds. Later runs reuse that choice.
You must grant macOS Full Disk Access to your terminal and Automation permission for Messages
when prompted. Apple model answers require Apple silicon, macOS 26+, Apple Intelligence enabled,
and Xcode 26+. For a larger open-weight model selected for the Mac's memory, use `bash scripts/start-open-model.sh` instead. On a 48 GB Mac it downloads Qwen3.8 27B (about 18 GB) once and serves it locally. The Mac must stay awake with the host running. See [the guided setup](docs/local-models.md).

## Mac model choices

`bash scripts/start.sh` uses Apple's on-device model, already available on supported Macs. For an open-weight model, run:

```bash
bash scripts/start-open-model.sh
```

That starter installs the Ollama CLI with Homebrew if needed, starts a loopback server, downloads a model once, and launches the same Messages assistant. It selects Qwen3.8 27B Q4 on Macs with at least 40 GB memory (about 18 GB of weights), Qwen3.5 9B on 16–39 GB, and Qwen3.5 4B on 12–15 GB. Set `ASSISTANT_OPEN_MODEL=<an Ollama local model tag>` to override. Restart the assistant to switch back with `bash scripts/start.sh`. Only one host should run at a time.

For other model runtimes, use `ASSISTANT_MODEL=local ASSISTANT_MODEL_NAME=<loaded model> ASSISTANT_MODEL_URL=http://127.0.0.1:<port>/v1 bash scripts/start.sh`. The runtime must implement `/v1/chat/completions` and `/v1/models`. “OpenAI-compatible” names the local wire format, not a cloud provider. Literal loopback HTTP URLs are required and redirects are blocked. A user-supplied local proxy may itself forward requests; choose a runtime that stays offline if that matters to you. The open-model starter uses local Ollama tags and needs network only to download weights. Set `ASSISTANT_LOCAL_REASONING_EFFORT=none` for a compatible quick-chat model; the open-model starter does this by default.

## Current stage: Messages assistant with paired phone context

See [docs/local-models.md](docs/local-models.md) for setup. Install the Mac worker, start the host,
and text your private Messages self-chat from anywhere the phone and Mac have connectivity. The Mac must remain online and running the host. Pair the optional phone companion once to include
derived sleep summaries. Mac generation needs Apple Intelligence support and macOS 26+; the
source companion supports iOS 17+. Build with Xcode 26+.

The first slice:

```text
iPhone self-chat
→ Messages.app on Mac
→ imsg watcher
→ deterministic echo
→ fixed control chat
```

Implemented now:

- a small `MessageTransport` boundary;
- an `imsg` adapter for chat listing, JSON-RPC watching, paged history catchup for owner commands, health checks, and sending;
- exact-chat filtering, durable per-chat cursors, and automatic resume;
- bounded reconnect backoff with visible degraded-state output;
- outbound GUID/content ledger for self-echo suppression;
- a deterministic echo service;
- focused unit tests;
- a CLI for Mac device testing.
- append-only SQLite observations with current heads and FTS5 search;
- resumable one-to-one Messages history ingestion with durable source cursors.
- bounded, read-only EventKit ingestion with explicit authorization and scan coverage.
- deterministic Contacts ingestion for local handle-to-person resolution.
- persisted, explicit coverage status for Messages, Calendar, and Contacts;
- exact phone/email joins across contacts, events, and direct messages;
- a deterministic meeting-context evidence query with explicit ambiguity errors.
- typed commitment assertions linked to source evidence;
- a versioned deterministic extractor for explicit, actionable, owner-authored,
  time-bound commitments;
- open-commitment, evidence explanation, and explicit completion commands;
- an owner-control service for evidence, completion, meeting context, pause and status;
- automatic, independent source refresh in a single supervised host;
- one opt-in due-commitment reminder rule with persistent reservations and gate audits.
- a small `LocalModelProvider` contract, bounded evidence documents and validated citation IDs;
- Apple on-device structured generation with deterministic evidence-only fallback;
- a signed sandboxed Mac model worker, question CLI and nonblocking `/ask` owner commands;
- a phone companion for QR pairing and optional derived HealthKit sleep sharing;
- pinned HTTPS, Keychain pairing credentials, durable phone upload queue and Mac acknowledgment;
- macOS tests, worker isolation checks and simulator/device iOS builds in CI.

`imsg` is the first adapter because its stable JSON/JSON-RPC surfaces expose resumable row cursors and send GUIDs. `platform-imessage` remains a later comparison backend behind the same transport contract.

The P0 self-chat gate has passed physical round-trip, restart/resume, forced reconnect, duplicate-content, tapback, cellular, and delayed-sync checks. Lock-screen, reboot, and long-run checks remain ongoing soak tests.

Milestone 1 starts with a small `AssistantStore` module: append-only, versioned observations from Messages, Calendar, and Contacts; current-version heads; tombstones; and SQLite FTS5 search. See [docs/m1-storage.md](docs/m1-storage.md).

## Requirements

- Apple silicon or Intel Mac running macOS 14+
- Xcode with Swift 6
- Messages.app signed into iMessage
- [`imsg`](https://github.com/openclaw/imsg) installed
- Full Disk Access for the calling host/terminal
- Automation permission to control Messages.app
- Calendar full-access permission for the terminal or host running `assistantctl`
- Contacts permission for the terminal or host running `assistantctl`

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
swift run assistantctl source-status
swift run assistantctl meeting-context --person "<exact contact name>"
swift run assistantctl index-commitments --days 30
swift run assistantctl forgetting
swift run assistantctl serve --control-chat-id <SELF_CHAT_ID>
```

Only choose a private, one-to-one iMessage self-chat. The echo and control services never
choose a recipient; they can send only to the chat ID supplied at startup. Ordinary self-chat texts start a local conversation when the model is enabled. The host sends one final answer per turn and queues follow-ups; commands and direct Calendar agendas can answer while generation is running. The last four exchanges are kept in a bounded private Mac transcript for follow-ups. Because the Mac sends from your own iMessage account to your self-chat, some replies appear as outgoing blue bubbles; the same conversation can also render gray on the phone depending on the address and route Messages uses. A [separate assistant identity](https://github.com/pranavdulepet/local-proactive-assistant/issues/28) is the intended long-term conversation UX. Send `/help` in the control chat to list commands.

`serve` refreshes Messages and commitments every 60 seconds after each completed scan, and
Calendar/Contacts every 15 minutes. Reminders start paused. `/resume` enables the one M1 rule;
`/pause` stops unsolicited reminders without disabling commands. `/status` reports the last
gate, submission state and source freshness. Use `/meeting <exact person>` for indexed meeting
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
