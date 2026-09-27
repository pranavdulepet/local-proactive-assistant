# Local Proactive Assistant

A local-first macOS assistant that tracks loose ends and eventually sends a small number of evidence-backed iMessages. Personal-source indexing and model inference stay on user-controlled Apple hardware.

This repository started with the fragile part: a reliable self-chat transport loop. It now has local observation storage plus read-only Messages, Calendar, and Contacts ingestion, but no model runtime, phone app, or autonomous action layer.

## Current milestone: M1 thin vertical slice

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
- an `imsg` adapter for chat listing, JSON-RPC watching, health checks, and sending;
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
- a narrow deterministic extractor for explicit, owner-authored, time-bound commitments;
- open-commitment, evidence explanation, and explicit completion commands.

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

## Run the P0 loop

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
```

Only choose a private, one-to-one iMessage self-chat. The echo process never chooses a recipient; it can send only to the chat ID supplied at startup.

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

1. Validate meeting-context and commitment evidence on the Mac.
2. Add `/why` in the owner control chat using the existing evidence path.
3. Add one gated proactive commitment rule with a one-message-per-day ceiling.
4. Add a second `platform-imessage` adapter only if a measured transport gap justifies it.

## License

Apache-2.0. Third-party tools and model weights keep their own licenses.
