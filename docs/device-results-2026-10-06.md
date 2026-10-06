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

## Observed results

| Check | Actual result | Meaning |
| --- | --- | --- |
| `bash scripts/start.sh` in the original checkout | Release build and Ollama startup passed; Messages doctor failed opening the database read-only | The assistant did not reach serving readiness |
| Full Disk Access settings | Terminal enabled; Codex not listed as granted | Terminal's grant does not cover commands launched by Codex |
| Native Mac startup | App launched and started its owned Ollama; its Messages doctor also failed read-only access | Local Assistant needs its own Full Disk Access grant and relaunch |
| Native package before fix | Codesign rejected resource fork/Finder metadata | A real packaging failure, not a compiler failure |
| Native package after fix | Built, installed, strict deep signature verification and `--check-payload` passed | Locally built/ad-hoc signed package is valid; not a notarized release |
| Signing regression | Injected synthetic ResourceFork metadata reproduced the rejection; clearing only the staged bundle allowed signing and strict verification | Packaging cleanup fixes the observed failure mechanism |
| Qwen model availability | Installed local model ready, 0.10 seconds for the status command | Metadata readiness only; inference results below |
| Qwen evidence evaluation | Correct Friday-at-5-PM claim with `[demo1]`, 18.1 seconds of inference (18.21 seconds wall time) | Real local generation from synthetic evidence |
| Qwen production conversation loop, run 1 | One `searchIndex` read, then correct Friday-at-5-PM answer with `[e1]`, 12.6 seconds (12.68 wall) | Actual native tool-call/result loop using a synthetic index |
| Qwen production conversation loop, run 2 | Same correct read/answer, 10.7 seconds (10.76 wall) | Second local model run; not a broad quality or latency benchmark |
| Native login API | Reversible `--check-login-startup` registered with status 1 (enabled), then restored status 0 (not registered) | Actual Service Management registration works on this Mac; startup remains off |
| Native login status after probe | Not registered | No logout/login, reboot or phone-reply recovery test occurred |
| Real iMessage replies visible on iPhone | Not verified; no functioning host or phone confirmation in this run | No send/delivery success is claimed |
| Apple Mail fresh read | Timed out during account access, Apple Events `-1712` | Unavailable for this attempt; timeout is not proof of permission denial |
| Notes fresh read | Read deadline exceeded; no permission denial reported | Unavailable for this attempt |
| Reminders fresh read | Permission decision did not arrive within 60 seconds | Access not verified |
| Photos fresh read | Authorization denied | Access denied for this execution context |
| Calendar fresh indexing | No result within a bounded 45-second wait; test process stopped | Access/read not verified; could be a pending permission decision |
| Contacts fresh indexing | `CNErrorDomain` code 100, access denied | Access denied for this execution context |
| Phone companion, remote uploads, lock/reboot, 24-hour soak | Not exercised | Still require physical-device acceptance |

Optional-source probes above ran from the CLI supervised by Codex, not from an authorized
Terminal or native app session. macOS grants differ by responsible app and executable identity.
Previously saved source-access/sync records were not counted as fresh successful reads.
No p50/p95 receive-to-visible iPhone latency is reported: the inference samples do not measure delivery.

## Automated validation on this Mac

- 246 Swift tests across 52 suites passed on both the pulled baseline and the fixed code.
- 59 setup/script checks passed after isolating the missing-helper fixture from installed `imsg`.
- All 10 package installer tests passed, including staged-metadata cleanup and rollback cases.
- Built CLI host-startup/exclusivity regression passed, including lock release after exit.
- Three built CLI evaluation regressions passed: selected Ollama provider, production tool loop,
  and rejection of unknown evaluation options before model access.
- Native host lifecycle tests passed, including process cleanup, cancellation, startup failures,
  phone-pairing cancellation and actionable native Full Disk Access recovery.
- Shell syntax and `git diff --check` passed.
- No iPhone source changes were made and no physical/simulator phone build was run here.

## Required next device actions

1. Grant the installed `~/Applications/LocalAssistant.app` Full Disk Access in System Settings,
   quit and reopen it, and confirm the menu reaches Running. Source prompts must be approved
   for that responsible app if those sources are wanted. Permission grants cannot be supplied
   by the model or inferred from Terminal's grants.
2. Connect sources from the native app. Retry Mail/Notes after opening their apps and confirming
   they respond. Compare a current Calendar question/follow-up and source answers against the
   actual apps. Preserve missing-access and incomplete-coverage reporting.
3. Send `/status` and a natural question from the physical iPhone. Record receive-to-visible
   timing and phone observation separately from a local Messages submission row. Test restart
   catchup and uncertain-send reconciliation without automatically resending uncertain replies.
4. Enable Start at login deliberately, then verify logout/login or reboot recovery with a
   physical phone round trip. Check lock/display-off behavior and a 24-hour unattended run.
5. Validate physical iPhone offline inference, opted-in context freshness/revocation and
   away-from-home reachability. Complete native first-run UI, signed/notarized distribution
   and clean-account installation acceptance before calling the product finished.
