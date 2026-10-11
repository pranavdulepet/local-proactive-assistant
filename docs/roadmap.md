# Roadmap and acceptance

The product goal is useful local follow-through: remember open loops, prepare for meetings,
recall personal context with evidence, and recognize when a dependency has resolved.
More connectors do not establish that this goal works reliably. The developer alpha exposes
the implementation for testing and contribution while the checks below remain open.

## Before a stable app release

| Area | Implemented | Acceptance still needed |
| --- | --- | --- |
| Transport | imsg abstraction, verified self route, durable ledger and uncertain-send handling | Physical iPhone visibility/latency; cellular, locked/display-off Mac, Messages/network/process restart, reboot, duplicates, tapbacks and 24-hour soak; second adapter parity |
| Sources | Permissioned bounded reads, lexical index, freshness and coverage | Fresh reads after final app update, including Contacts/Reminders/Photos; deleted Calendar reconciliation; clean-account setup |
| Follow-through | Narrow owner-authored commitment extraction, manual completion and provenance | Automatic completion evidence, dependency resolution, complete correction/retraction lifecycle and replay coverage |
| Proactivity | Initially paused, quiet hours, duplicate suppression and daily budget | Worthwhile/incorrect feedback, bundling and replay evaluation; at least 90% of unsolicited messages judged worthwhile before increasing volume |
| Models | Local tool loop, Apple worker, Ollama and compatible local server paths | Small-model quality/speed comparison, latency distribution, unsupported/empty-source quality and sustained resource use |
| Mac distribution | Ad-hoc source installer, bundled host/worker, login registration and supervised recovery | Native first-run flow; Developer ID signing/notarization; permission continuity across updates; actual logout/login and reboot readiness |
| Phone | Paired HTTPS, Bonjour, queued transfers and Apple/MLX code | Physical offline inference, freshness/revocation, background upload, unreachable-network recovery and away-from-home path |

Existing work tracks [distribution #19](https://github.com/pranavdulepet/local-proactive-assistant/issues/19),
[conversation #35](https://github.com/pranavdulepet/local-proactive-assistant/issues/35),
[latency #31](https://github.com/pranavdulepet/local-proactive-assistant/issues/31),
[phone inference #34](https://github.com/pranavdulepet/local-proactive-assistant/issues/34),
[phone context #27](https://github.com/pranavdulepet/local-proactive-assistant/issues/27), and
[separate identity #28](https://github.com/pranavdulepet/local-proactive-assistant/issues/28).
A dedicated sender/account is later work; self-chat remains the initial supported route.

## Evidence rules

Record the commit, OS/hardware, relevant source grants, exact scenario, elapsed time and observed
result. Distinguish local submission, Mac Delivered status and actual visibility on the phone.
Do not turn a registration check into a reboot pass, simulator build into physical inference,
or a source metadata probe into a successful source read. Keep raw personal logs private.

Current evidence is in the [device report](device-results-2026-10-06.md) and
[reply evaluations](reply-style.md). The historical device report remains a record of that
build and session; publishing a newer source release does not change those observations.
