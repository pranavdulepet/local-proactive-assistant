# Local Proactive Assistant

A local-first macOS assistant that tracks loose ends and eventually sends a small number of evidence-backed iMessages. Personal-source indexing and model inference stay on user-controlled Apple hardware.

This repository is intentionally starting with the fragile part: a reliable self-chat transport loop. There is no memory, RAG, model runtime, phone app, or autonomous action layer yet.

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
```

Only choose a private, one-to-one iMessage self-chat. The echo process never chooses a recipient; it can send only to the chat ID supplied at startup.

The CLI stores its last handled row per chat under `~/Library/Application Support/LocalProactiveAssistant/`. A restart resumes from the newer of that checkpoint and an optional `--after <ROW_ID>` value; it never rewinds a saved cursor.

For the full device test matrix, see [docs/p0-transport.md](docs/p0-transport.md).

## Design rules

- Source text is data, never policy.
- The model will never choose an outbound recipient.
- External actions stay structurally absent until the core is trustworthy.
- Structured queries come before RAG.
- Proactivity optimizes precision; silence is a feature.
- Every derived claim must retain evidence and provenance.

## Near-term plan

1. Finish the P0 physical-device matrix and record reliability failures.
2. Fix any failures that violate the transport invariants.
3. Build the thin Messages + Calendar + Contacts vertical slice.
4. Add the evidence/assertion ledger before any broad personal-memory feature.
5. Add a second `platform-imessage` adapter only if a measured transport gap justifies it.

## License

Apache-2.0. Third-party tools and model weights keep their own licenses.
