# Local Proactive Assistant

A local-first macOS assistant that tracks loose ends and eventually sends a small number of evidence-backed iMessages. Personal-source indexing and model inference stay on user-controlled Apple hardware.

This repository started with a reliable self-chat transport loop. It now has read-only
Messages, Calendar and Contacts ingestion, bounded on-device answers on the Mac, and a native
iPhone app with the same model contract. Apple’s system model is the first runtime, as planned.
External action tools are absent.

## Current stage: local-model pilot on Mac and iPhone

For the shortest setup path, see [docs/local-models.md](docs/local-models.md): install the
Mac worker, check the local model, ask an indexed question, then run the iPhone app from Xcode.
Everyday conversation stays in your private Messages self-chat. The phone app is an optional
companion for phone sources and local testing; its sources do not yet sync to the Mac.
The core host still runs on macOS 14+; model inference needs an Apple Intelligence-capable
device, macOS/iOS 26+, Apple Intelligence enabled, and Xcode 26+ to build.

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
- a versioned deterministic extractor for explicit, actionable, owner-authored,
  time-bound commitments;
- open-commitment, evidence explanation, and explicit completion commands;
- an owner-control service for evidence, completion, meeting context, pause and status;
- automatic, independent source refresh in a single supervised host;
- one opt-in due-commitment reminder rule with persistent reservations and gate audits.
- a small `LocalModelProvider` contract, bounded evidence documents and validated citation IDs;
- Apple on-device structured generation with deterministic evidence-only fallback;
- a signed sandboxed Mac model worker, question CLI and nonblocking `/ask` owner commands;
- a native iPhone app for phone-local questions and explicit Mac context snapshot import;
- explicit phone Calendar/Contacts access and optional derived HealthKit sleep context;
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
swift run assistantctl serve --control-chat-id <SELF_CHAT_ID>
```

Only choose a private, one-to-one iMessage self-chat. The echo and control services never
choose a recipient; they can send only to the chat ID supplied at startup. Ordinary self-chat
notes are checkpointed without a reply. Send `/help` in the control chat to list commands.

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

1. Run the local-model pilot on physical Mac and iPhone hardware. Review claim support,
   latency, abstention and offline behavior before enabling broader AI extraction.
2. Dogfood the narrow assistant and measure grounded-answer quality and interruption usefulness
   before expanding sources, models or proactive rules.
3. Ship signed native host/login-item support for unattended use; do not substitute shell
   LaunchAgent installation for the planned application lifecycle.
4. Finish the later phone connectivity milestone: authenticated pairing, bounded derived-event
   queue, HTTPS sync and freshness, then optional location. The current phone app runs its own
   local model and reads explicitly enabled local sources; context import is a manual snapshot.

Mail, broad Messages reconciliation, embeddings and additional model runtimes remain later
work, not prerequisites silently added to M1. A second `platform-imessage` adapter is justified
only by a measured transport gap. MLX/llama.cpp and embeddings remain evaluation-driven
additions. This pilot does not claim background phone sync or unattended host lifecycle.

## License

Apache-2.0. Third-party tools and model weights keep their own licenses.
