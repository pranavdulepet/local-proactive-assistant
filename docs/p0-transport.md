# P0 transport runbook

P0 answers one question: can a self-chat round trip remain reliable enough to support the product?

## Setup

1. Create a private one-to-one self-chat in Messages.
2. Install `imsg` and grant the terminal or signed host Full Disk Access.
3. Run `swift run assistantctl doctor`.
4. Run `swift run assistantctl chats` and copy the numeric ID of the self-chat.
5. Start `swift run assistantctl echo --chat-id <ID>`.
6. Send a message from the iPhone. Expect exactly one `echo: ...` response.

The first run may trigger macOS Automation approval for Messages.app.

## Test matrix

Record pass/fail, latency, duplicate sends, missed events, and the last printed row ID.

| Scenario | Minimum check |
|---|---|
| Baseline | 20 sequential messages; exactly 20 replies |
| Cellular | iPhone off Wi-Fi; 10 successful round trips |
| Locked Mac | Lock the Mac; 10 successful round trips |
| Display off | Keep the host awake; 10 successful round trips |
| Process restart | Stop and restart after recording the last row ID |
| Resume | Start with `--after <ROW_ID>`; no old command is replayed |
| Messages restart | Quit/reopen Messages.app; watcher recovers or fails visibly |
| Network loss | Disconnect/reconnect Mac network; no duplicate replies |
| Identical commands | Send the same text twice; receive two replies |
| Tapback | React to a command; receive no reply |
| Empty/system event | Produce a read receipt or other empty event; receive no reply |
| Delayed sync | Send while Mac is offline, reconnect, and inspect ordering |
| Long run | Keep it running for 24 hours; zero recursive loops |

## Invariants

- Only the configured numeric chat ID is eligible.
- Empty events and cursor replays are ignored.
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
