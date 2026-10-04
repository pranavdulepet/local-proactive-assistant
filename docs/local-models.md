# Local-model pilot: Mac first, then iPhone

This follows design v0.2: Apple’s on-device system model first, one bounded generation at a
time, structured evidence before retrieval expansion, and no model-controlled recipients,
settings or actions. There are no cloud AI credentials, extra model weights or AI endpoints.

## Mac setup

Use an Apple Intelligence-capable Mac running macOS 26 or newer. Enable Apple Intelligence
in Settings and let its system-managed model finish preparing. Select Xcode 26+ as the active
developer directory. Existing deterministic commands still work on macOS 14+.

From the repo, with the old host stopped:

```bash
git pull --ff-only origin main
swift test
./scripts/setup-local-model.sh
./scripts/check-model-worker.sh
.build/release/assistantctl model-status
.build/release/assistantctl model-eval
.build/release/assistantctl ask --question "What is on my calendar tomorrow?"
.build/release/assistantctl serve --control-chat-id 955 --model apple
```

Use your already validated private control chat ID if it differs from 955. The installer
builds release binaries and signs an isolated worker at
`~/Library/Application Support/LocalProactiveAssistant/Models/LocalAssistantModel.app`.
Re-run it after model-worker changes. It does not change source permissions or reminder policy.

The worker has only the App Sandbox entitlement: no network, personal-data or Automation
entitlements. The host verifies its signature and entitlements before sending a JSON request.
The installer check confirms the worker cannot read a host-owned probe file outside its sandbox
and validates its availability response. It does not test private Messages or Health data.

`model-status` reports the actual runtime state. If it says the model is preparing, enable
Apple Intelligence and allow preparation to finish. If it says the signed worker is unavailable,
re-run setup with Xcode 26+. The status command exits 1 for unavailable; questions still produce
labeled evidence excerpts when generation is unavailable, times out or fails validation.
There is no automatic fallback to a remote service.

Send `/ask <question>` or a question ending in `?` in the control chat. Ordinary notes stay
ignored. Existing `/forgetting`, `/why`, `/done`, `/meeting`, `/pause`, `/resume` and `/status`
routes remain deterministic. A question receives an acknowledgment and a later answer;
one question is allowed in flight and owner commands keep working. Failed or uncertain answer
submissions are not retried automatically. Questions do not unpause reminders.

For everyday use, open Messages on your phone and use the same private self-chat you validated
during setup. Send `What is on my calendar tomorrow?` directly; `/ask` is optional for messages
ending in `?`. The Mac retrieves its indexed evidence and answers in that conversation. Keep
the Mac awake and `serve` running. You do not need the phone companion open for this path.

For person-specific context, use an exact name or handle:

```bash
.build/release/assistantctl ask --question "Help me prepare for the next meeting" --person "Exact Contact Name"
```

## iPhone setup

Use a physical Apple Intelligence-capable iPhone running iOS 26+, with Apple Intelligence
enabled and its on-device model ready. Open:

```bash
open Apps/AssistantPhone/AssistantPhone.xcodeproj
```

Select the `AssistantPhone` scheme, your phone as the run destination, and your Apple development
team under Signing & Capabilities. Use your own bundle identifier if provisioning requires it.
Build and Run. A simulator can validate the UI and fallback but is not proof of hardware model
availability. Optional HealthKit access needs a provisioning profile that permits HealthKit;
if your team cannot provision it, remove that capability for a model/Calendar/Contacts-only pilot
and leave sleep context disabled.

The phone companion opens with the Messages instructions. It is optional for everyday chat.
**Phone sources** controls Calendar, Contacts and sleep access for on-phone answers only; these
sources are not yet synced to the Mac or used by the Messages assistant.

For a separate phone-local test, open **Advanced → On-phone model tools** and start with
**Demo → Ask locally**. The only supplied fact is a public project deadline of Friday
at 5 PM. Check the generated answer and visible citation. Then select **This phone** and open
**Choose phone sources** to enable the sources you want. Calendar is limited to the next seven days;
Contacts supplies only one unambiguous exact-name match. Sleep supplies a derived seven-day total
of available asleep intervals, merging overlaps and clipping the window. Missing/denied data is
not treated as zero sleep, a diagnosis or proof of read authorization. Raw samples stay on phone.

All context and answers in the app are held in memory. **Clear local context** drops them and
disables source toggles; operating-system permissions remain manageable in Settings. Source
reads happen when you ask, not through a background feed. Cancel stops the question; moving the
app into the background requests cancellation too.

## Bring selected Mac evidence to the phone

The phone cannot read the Mac Messages database. Export a bounded question-specific snapshot:

```bash
.build/release/assistantctl export-context --question "What is on my calendar tomorrow?" --output "$HOME/Desktop/tomorrow.lpa-context"
```

You can also pass `--person "Exact Contact Name"` for meeting context. The file contains at most
eight excerpts with provenance and coverage, not the database. It is private data: share it only
through a transfer you select, such as AirDrop. Open it in Local Assistant or choose **Import Mac
context** in the app. The phone’s model runs locally over those records. The original export time
and a snapshot warning stay visible; asking again does not make the sources fresh. Delete the
export when finished. Exported context files are ignored by git. The import control is under
**Advanced → On-phone model tools**; opening a context file directly takes you to those tools.

This is explicit snapshot transfer, not authenticated live device sync. It does not implement
Bonjour pairing, keychain credentials, HTTPS delivery/acknowledgment, an offline derived-event
queue or phone-to-Mac health sync. Those remain the later connectivity milestone, as do optional
location, Mail, broad edit/deletion reconciliation and signed native host/login-item lifecycle.

## Evaluation and limits

`model-eval` uses a public fixture, times one generation, and validates bounded output and citation
IDs. You must still review whether “Friday at 5 PM” is preserved accurately. Run it with the
network disconnected after the system model is prepared. The app’s Demo supports the same check
in airplane mode. Do not claim real-device/offline success from CI: CI builds both phone
architectures and tests the contracts and worker isolation without relying on a downloaded model.

Each request contains at most eight records, 768 UTF-8 bytes per excerpt and a 512-byte question.
Every generated claim must cite supplied evidence IDs. Unknown IDs, malformed or oversized
outputs fall back to excerpts. Citations identify inputs; they do not prove semantic support.
Lexical retrieval can miss relevant messages, source coverage remains explicitly partial, and
small local models can abstain or make incorrect claims. Review the source preview when needed.

Apple’s model weights and license are system-managed; readiness includes the OS version, not
a fabricated weight hash. The model adapter can be replaced behind `LocalModelProvider` if the
measured quality/latency gate later justifies MLX or llama.cpp. This slice adds grounded answers;
it does not silently replace the deterministic commitment extractor or add inferred completion.

You can use this as a supervised personal pilot after installation and device checks. A reliable
unattended, continuously synced product still needs the remaining lifecycle/connectivity work.
