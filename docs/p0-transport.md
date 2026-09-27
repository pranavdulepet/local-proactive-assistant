# P0 transport runbook

P0 answers one question: can a self-chat round trip remain reliable enough to support the product?

## Setup

1. Create a private one-to-one self-chat in Messages.
2. Install `imsg` and grant the terminal or signed host Full Disk Access.
3. Run `swift run assistantctl doctor`.
4. Run `swift run assistantctl chats` and copy the numeric ID of the active self-chat route. Messages may keep phone-number and email routes as separate numeric chats while showing one conversation, so use the recently active route.
5. Start `swift run assistantctl echo --chat-id <ID>`.
6. Send a message from the iPhone. Expect exactly one `echo: ...` response.

The first run may trigger macOS Automation approval for Messages.app.

The watcher checkpoints every handled row. On restart it resumes automatically and prints the stored row. `--after <ROW_ID>` may seed a newer cursor, but cannot rewind an existing checkpoint.

If `imsg rpc` stops with a retry-safe transport failure, the watcher reconnects after 1, 2, 4, 8, 16, then at most 30 seconds. Each interruption and retry is printed. Invalid data and uncertain send outcomes remain terminal errors.

## Automated checks

`swift test` covers:

- monotonic per-chat cursor persistence across store restarts;
- automatic resume from a stored cursor;
- reconnect and resume after a retry-safe watch failure;
- checkpointing ignored outbound echoes;
- replay, empty-event, wrong-chat, and echo filtering;
- parsing a streamed `imsg rpc` subscription and message event.

## Test matrix

Record pass/fail, latency, duplicate sends, missed events, and the last printed row ID.

| Scenario | Minimum check | Current status |
|---|---|---|
| Baseline | 20 sequential messages; exactly 20 replies | One round trip passed; full run pending |
| Cellular | iPhone off Wi-Fi; 10 successful round trips | Pending |
| Locked Mac | Lock the Mac; 10 successful round trips | Pending |
| Display off | Keep the host awake; 10 successful round trips | Pending |
| Process restart | Stop and restart; stored row prints and no old command replays | Pending |
| Watch reconnect | Terminate the child `imsg rpc`; watcher reconnects visibly | Pending |
| Messages restart | Quit/reopen Messages.app; watcher recovers or fails visibly | Pending |
| Network loss | Disconnect/reconnect Mac network; no duplicate replies | Pending |
| Identical commands | Send the same text twice; receive two replies | Pending |
| Tapback | React to a command; receive no reply | Pending |
| Empty/system event | Produce a read receipt or other empty event; receive no reply | Pending |
| Delayed sync | Send while Mac is offline, reconnect, and inspect ordering | Pending |
| Long run | Keep it running for 24 hours; zero recursive loops | Pending |

## Invariants

- Only the configured numeric chat ID is eligible.
- Empty events and cursor replays are ignored.
- Stored cursors only move forward and are scoped by numeric chat ID.
- Retry-safe watch failures resume from the last handled row.
- An observed outbound GUID is ignored.
- If the send GUID is unavailable, matching content is ignored only in the same chat and a short time window.
- `is_from_me` is not trusted as the only self-chat discriminator.
- A send with an uncertain outcome is not automatically retried.

## Failure notes

Capture:

- macOS and Messages versions;
- `imsg` version;
- scenario and timestamp;
- last accepted row ID;
- whether the send appeared in Messages.app;
- whether `imsg` returned a GUID;
- whether a duplicate had the same or a different GUID.

Never include message bodies, phone numbers, email addresses, or a real `chat.db` in an issue.
