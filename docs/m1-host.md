# Supervised M1 host

This describes the deterministic M1 host. Its policy and evidence paths remain independent of
the separately added [local-model pilot](local-models.md). The iMessage surface works alongside
the native phone app; this is still a supervised foreground host.

## Run

```bash
git pull --ff-only origin main
swift test
swift run assistantctl serve --control-chat-id 955
```

Choose your private self-chat explicitly; `955` is the validated development chat, not a default.
The host refuses a group or non-iMessage chat and acquires a kernel-managed single-host lock.
Keep this foreground process running on an awake, online Mac. Startup catches up Messages;
the first historical backfill can take time. Commands run independently during source refresh.
Calendar and Contacts retain their existing read-only authorization paths.

Messages catch-up and the 30-day commitment extractor run once per loop, then wait 60 seconds.
Calendar and Contacts snapshots are attempted every 15 minutes. Permission failures are
isolated and logged by source, without private source text. Failed attempts do not fabricate
a successful sync timestamp. One-shot `imsg` requests have a 60-second deadline and cancellation
terminates their child. The watch retains the existing reconnect/resume behavior.

## Owner controls

| Command | Result |
| --- | --- |
| `/forgetting` | Current open commitments, with coverage limitations |
| `/why <id>` | Immutable evidence and latest candidate gate evaluations |
| `/done <id>` | Explicitly complete an open commitment |
| `/meeting <exact person>` | Next indexed meeting and ten genuinely newest direct messages |
| `/ask <question>` | Bounded grounded answer when `serve --model apple` is enabled |
| `/pause` | Persistently stop unsolicited reminders; commands still work |
| `/resume` | Opt in to the one due-commitment rule |
| `/status` | Policy state, last gate/submission, and source freshness |

Terminal equivalents for policy control are `assistantctl pause`, `resume`, and `proactive-status`.
Do not run echo or manual indexers alongside `serve`.

## One proactive rule

- Initially paused; no notification without `/resume`.
- Current, active `commitment.v2` assertion from recent owner-authored direct-message evidence.
- Evidence must still be the indexed current head, not a tombstone, and at most seven days old.
- Messages catch-up must have succeeded, with coverage no older than ten minutes.
- Due within three hours, not a historical overdue backlog. This lets “tonight” cues surface
  before quiet hours rather than sending at midnight.
- Quiet hours 22:00–08:00 in the Mac's current timezone; no urgent override.
- At most one reservation per local day **and** rolling 24 hours. Timezone changes cannot buy
  another slot. No repeated source evidence, even if its assertion ID changes.
- Generic unsolicited text with `/why` and `/done` IDs; no source excerpt or person name.

Gate checks, audit updates and reservation are a single SQLite transaction. The decision is
made against state at reservation time; an already-in-flight submission cannot be recalled by
a later `/pause` or `/done`. The database keeps the latest evaluation per candidate/reason and
all reservations; it does not append a redundant audit row every minute.

A reservation is committed **before** the external send. A receipt is recorded as `submitted`,
not proof of device delivery. Missing/error results are `unknown` and atomically pause reminders.
On host restart, unfinished reservations become `unknown` and pause reminders too. Inspect
the self-chat and `/status` before deliberately resuming. Reserved/unknown attempts consume the
slot and are never automatically retried: this prioritizes avoiding duplicate interruptions
over exactly-once delivery. `/why` shows the candidate-specific gate decisions.

## Focused physical smoke test

The prior self-chat and host/policy validation remain accepted. These steps are the repeatable
smoke procedure for changes to this path; CI cannot exercise private macOS permissions or actual
iMessage delivery. Real-device local-model checks are listed separately in local-models.md.

1. Start `serve`; `/status` should show paused on first use and increasingly fresh source syncs.
2. `/resume`, `/pause`, ordinary notes and `/meeting <exact person>` should leave the listener
   working. Restart and confirm the pause state and watch cursor persist.
3. During non-quiet hours, make a supported commitment in a different direct conversation
   with yourself as author, such as “I will send the notes tonight.” In the last three hours
   before its due window, expect at most one generic reminder after opting in.
4. Verify `/why <id>` points to the real source and `/done <id>` removes it from open items.
   Restart/resume must not repeat the reminder. Avoid sending fabricated commitments to other
   people merely to test this; use an intentional existing task or a controlled test participant.

Automated tests cover gates, persistent budget, concurrent reservation, cross-version evidence
deduplication, timezone changes, unknown-send pause, interrupted recovery, fixed recipient,
echo suppression, source failure isolation, refresh cadence and helper deadlines/cancellation.

## What “usable” means next

The narrow deterministic assistant is usable now through iMessage while the foreground host
is running. The Mac local-model pilot now adds bounded evidence input, typed output,
unavailable-model fallback and evaluation. Inference has no transport/policy authority and
does not enable autonomous external actions.

After model and device validation, start supervised dogfooding. Reliable unattended daily use
still requires signed native application/login-item lifecycle and ongoing transport soak tests.
Messages edits/deletions/groups/attachments and Calendar deletions are explicitly incomplete;
no answer should imply complete coverage.

The phone pilot now supports its own on-device model, read-only Calendar/Contacts, optional
derived sleep context and manual Mac snapshots. Live phone connectivity remains later work:
bounded derived-event queue, pairing, HTTPS sync/freshness, and optional location. No raw health
or location data is sent through iMessage. Optional Mac MLX, embeddings or rankers should be
added only for a measured workload.
