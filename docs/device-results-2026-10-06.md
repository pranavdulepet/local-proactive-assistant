# Mac device results — October 6, 2026

This records actual runs on the owner's Mac. It is not release acceptance.
Baseline: `main` at `94a248d` (merged PRs #40 and #41). The updated code is on
`codex/device-startup-validation`. No private messages, contact details, source excerpts,
phone pairing codes or signing identities are included here. Raw local logs remain private.

## Intended product and current state

The repository README, `docs/agent-runtime.md`, installation/coverage docs and product
issues describe a local Mac assistant reached through Messages, with bounded read tools,
durable conversations, a supervised native host and optional phone context/inference.
The final distribution goal in [#19](https://github.com/pranavdulepet/local-proactive-assistant/issues/19)
is a signed/notarized download, native first-run setup and ordinary use without developer tools.
The current installer still builds from source and signs ad hoc. This run did not release
or notarize a download or test a clean non-developer Mac account.

Physical conversation/latency acceptance remains in
[#35](https://github.com/pranavdulepet/local-proactive-assistant/issues/35) and
[#31](https://github.com/pranavdulepet/local-proactive-assistant/issues/31).
A dedicated incoming Messages identity requires separate supported Apple Account/device setup
([#28](https://github.com/pranavdulepet/local-proactive-assistant/issues/28)); self-chat formatting
cannot supply that identity. Physical phone model benchmarks and away-from-LAN context sync
remain [#34](https://github.com/pranavdulepet/local-proactive-assistant/issues/34) and
[#27](https://github.com/pranavdulepet/local-proactive-assistant/issues/27).
These issues are not closed by the checks below.

## Environment and checkout

- Apple M4 Pro, 48 GiB memory; macOS 26.5.2 (25F84), Xcode 26.6 (17F113), arm64.
- Existing checkout: `~/projects/local-proactive-assistant`, branch `main`.
- Pulled `main` fast-forward from `e377129` to `94a248d`.
- The sole initial local change, an untracked Xcode `project.xcworkspace` directory,
  remains in place and was copied to the private task workspace before pulling.
- Fixes were developed in a separate local clone; the original checkout remains on `main`.
- Saved model: `qwen3.8:27b-q4_K_M`; installed weights reused without downloading a new model.
- Owned test server: Ollama 0.35.1, `127.0.0.1:11435`, cloud disabled. Only the process
  started for this test was stopped; the separate desktop Ollama server was left alone.

## Latest follow-up: native setup and refresh recovery

The results in this section supersede the earlier source failures and disabled-login
state in the chronological attempts below.

- Added a normal native control window on manual launch/Finder reopen. The actual window
  exposed Connect, source timestamps and Start at login; automatic login launches are intended
  to remain in the menu bar. Physical login launch behavior is still unverified.
- With the owner's approval, native Connect performed fresh bounded Mail, Notes, Reminders
  and Photos reads successfully at 21:55 local time. All four reported Available after
  the final installed build. This proves these bounded reads, not full-library coverage.
- Calendar's apparent access failure was a refresh stall before its read: a sampled live
  backend was scanning historical observations during commitment extraction. The dated
  query's nullable predicates and unindexed head join produced a costly scan. The fixed
  query uses date bounds and the composite head key; other head joins receive an additive
  observation-ID index. A real read-only database query completed in 0.016 seconds.
- After installing the fix and refreshing the same app's Full Disk Access grant, Calendar
  indexed coverage and Contacts synced freshly at 21:55. Calendar still reports its bounded
  indexed window, rather than complete coverage.
- Two new `/status` replies appeared in the owner's real Messages self-chat as Delivered,
  before and after a controlled backend crash. The second reported all four optional
  sources connected, fresh Calendar/Contacts and zero waiting/failed replies.
- Sent SIGKILL only to the verified native app's backend. Its supervisor started a replacement
  in 4.2 seconds, returned to Running, and answered the subsequent real `/status`.
  The separate desktop Ollama remained running. This is process recovery, not reboot recovery.
- Start at login is enabled in the native UI and confirmed by the installed executable's
  Service Management status after the final update. No reboot/logout was performed.
- Nine legacy uncertain replies remain awaiting local confirmation; none were cleared or resent.
- The owner's paired physical iPhone is available and has companion version 0.1/build 1
  installed. Inventory does not verify its UI, companion pairing, inference or phone delivery.
  The owner chose manual phone-screen verification after iPhone Mirroring access was rejected.

## Earlier observed results

| Check | Actual result | Meaning |
| --- | --- | --- |
| `bash scripts/start.sh` in the original checkout | Release build and Ollama startup passed; Messages doctor failed opening the database read-only | The assistant did not reach serving readiness |
| Full Disk Access settings | Terminal enabled; Codex not listed as granted | Terminal's grant does not cover commands launched by Codex |
| Native Mac startup, initial attempt | App launched and started its owned Ollama; its Messages doctor also failed read-only access | Local Assistant needed its own Full Disk Access grant and relaunch |
| Native Mac startup after owner unlocked the Mac | Granted the installed app Full Disk Access, reopened it from Finder, and observed the host's Ready output with its bundled helper and owned loopback Ollama running | Native Messages database access and host startup now pass; the app remains running |
| Native package before fix | Codesign rejected resource fork/Finder metadata | A real packaging failure, not a compiler failure |
| Native package after fix | Built, installed, strict deep signature verification and `--check-payload` passed | Locally built/ad-hoc signed package is valid; not a notarized release |
| Signing regression | Injected synthetic ResourceFork metadata reproduced the rejection; clearing only the staged bundle allowed signing and strict verification | Packaging cleanup fixes the observed failure mechanism |
| Qwen model availability | Installed local model ready, 0.10 seconds for the status command | Metadata readiness only; inference results below |
| Qwen evidence evaluation | Correct Friday-at-5-PM claim with `[demo1]`, 18.1 seconds of inference (18.21 seconds wall time) | Real local generation from synthetic evidence |
| Qwen production conversation loop, run 1 | One `searchIndex` read, then correct Friday-at-5-PM answer with `[e1]`, 12.6 seconds (12.68 wall) | Actual native tool-call/result loop using a synthetic index |
| Qwen production conversation loop, run 2 | Same correct read/answer, 10.7 seconds (10.76 wall) | Second local model run; not a broad quality or latency benchmark |
| Native login API | Reversible `--check-login-startup` registered with status 1 (enabled), then restored status 0 (not registered) | Actual Service Management registration works on this Mac; startup remains off |
| Native login status after probe | Not registered | No logout/login, reboot or phone-reply recovery test occurred |
| Real iMessage replies visible on iPhone | Not verified; no physical phone observation supplied | The Mac round trip below does not establish phone visibility |
| Real Messages round trip on the Mac, follow-up | Sent a fresh `/status` in the verified owner self-chat and observed the Assistant response marked Delivered in Messages | Real receive/dispatch/reply path passes on the Mac; physical iPhone visibility remains unverified |
| Live natural-language source-access question | Local inference completed and a reply appeared in Messages, but the model returned the earlier generic read-selection failure without issuing a source read | Transport/inference pass; this answer is not evidence of current Notes permissions |
| Installed helper synthetic conversation, follow-up | Actual bundled helper executed `searchIndex`, cited the correct Friday-at-5-PM result, and passed in 12.4 seconds | The installed package supports the native tool loop; the live source question still needs investigation |
| Fresh native Notes read, explicit follow-up | Actual `notes` read returned one matching excerpt with no unreadable sampled items; availability-only answer appeared in Messages marked Delivered; host recorded 58.8 seconds through reply submission | Notes access and the real source/model/transport loop pass for this bounded query; speed and natural tool selection still need improvement |
| Fresh native Mail/Reminders/Photos checks | Mail timed out during account access (`-1712`); Reminders and Photos reported authorization not requested; the failure summary appeared in Messages marked Delivered; host recorded 66.9 seconds through submission | These are current native-host results, separate from the earlier Codex CLI probes |
| Native permission settings, follow-up | Full Disk Access on; Automation to Messages and Notes on; Calendar full access on; Contacts on | Visible grants verified; grants alone are not proof that every source read completes |
| Final fresh `/status`, follow-up | Assistant running, no waiting or failed turns; Contacts freshly synced; Calendar refresh unavailable despite its visible full-access grant; Notes connected; nine older turns still awaiting local confirmation | Host stayed responsive after live reads; Calendar failure and uncertain-turn reconciliation remain open |
| Apple Mail UI, follow-up | App responded and displayed a Login Failed indicator | Account repair may be needed; no credentials or account settings were changed |
| Apple Mail fresh read | Timed out during account access, Apple Events `-1712` | Unavailable for this attempt; timeout is not proof of permission denial |
| Notes fresh read | Read deadline exceeded; no permission denial reported | Unavailable for this attempt |
| Reminders fresh read | Permission decision did not arrive within 60 seconds | Access not verified |
| Photos fresh read | Authorization denied | Access denied for this execution context |
| Calendar fresh indexing | No result within a bounded 45-second wait; test process stopped | Access/read not verified; could be a pending permission decision |
| Contacts fresh indexing | `CNErrorDomain` code 100, access denied | Access denied for this execution context |
| Phone companion, remote uploads, lock/reboot, 24-hour soak | Not exercised | Still require physical-device acceptance |

The initial optional-source probes above ran from the CLI supervised by Codex. The explicit
follow-up source checks ran through Messages into the now-authorized native host.
macOS grants differ by responsible app and executable identity.
Previously saved source-access/sync records were not counted as fresh successful reads.
No p50/p95 receive-to-visible iPhone latency is reported: the inference samples do not measure delivery.

## Automated validation on this Mac

- 246 Swift tests passed on the pulled baseline; all 247 tests across 52 suites pass with
  the final fixes, including date bounds, current revisions, tombstones, trust and ordering.
- 59 setup/script checks passed after isolating the missing-helper fixture from installed `imsg`.
- All 10 package installer tests passed, including staged-metadata cleanup and rollback cases.
- Built CLI host-startup/exclusivity regression passed, including lock release after exit.
- Three built CLI evaluation regressions passed: selected Ollama provider, production tool loop,
  and rejection of unknown evaluation options before model access.
- Native host lifecycle tests passed, including process cleanup, cancellation, startup failures,
  phone-pairing cancellation and actionable native Full Disk Access recovery.
- Shell syntax and `git diff --check` passed.
- No iPhone source changes were made and no physical/simulator phone build was run here.
- PR #42 CI passed: both macOS test jobs and the phone build job.

## Remaining acceptance

1. Observe `/status` and a natural question on the physical iPhone, recording receive-to-visible
   latency separately from Mac submission/Delivered indicators. Phone-screen verification
   remains manual at the owner's request.
2. Perform a coordinated logout/login or reboot and verify native readiness plus a physical
   phone reply. The enabled registration and controlled backend recovery do not prove this.
3. Check lock/display-off behavior and a 24-hour unattended run, including catchup and
   uncertain-send reconciliation without automatically resending uncertain replies.
4. Validate physical iPhone offline inference, opt-in context freshness/revocation and
   away-from-home reachability. Complete native first-run setup, signed/notarized distribution
   and clean-account installation acceptance before calling the product finished.
