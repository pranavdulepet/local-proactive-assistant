# Use the assistant in Messages

Messages is the main conversation interface. Keep the assistant running on your Mac and text
its configured private self-chat from your phone. The companion also offers a separate,
optional on-phone chat while its app is open on an Apple Intelligence iPhone.

## Start on your Mac

Use a Mac signed into Messages. Apple model answers require Apple silicon with Apple Intelligence
enabled, macOS 26+, and Xcode 26+ to build the local worker. The host runs in the foreground.

```bash
git clone https://github.com/pranavdulepet/local-proactive-assistant.git
cd local-proactive-assistant
bash scripts/start.sh
```

The starter installs `imsg` with Homebrew if needed, builds the local worker, checks Messages
access, and prompts you to send a one-time code to your private iMessage self-chat. Confirm the
chat identity it displays. It remembers that chat on this Mac for later runs. At startup the host
also looks up your own phone numbers and email addresses on the Contacts Me card, then monitors
matching direct iMessage routes. It replies through the route that received each command. If
Contacts has no Me card or access is unavailable, add each other self address once with
`.build/release/assistantctl add-self-handle --address <your phone or email>\` and restart.
The host prints the active route IDs so missing aliases are visible. No chat ID or model
weights need to be entered. If Homebrew is absent, install it first. macOS requires you to grant
Full Disk Access to your terminal and, on the first reply, Automation permission for Messages;
the starter explains a missing grant. Quit and reopen the terminal after Full Disk Access changes.

Text `/status` in the paired self-chat. A response should appear within a few seconds. Then ask
`What is on my calendar tomorrow?` or send `/ask <question>`. A history poll catches new texts
even when `imsg`'s watch notification is missed. Ordinary notes are ignored. If Messages
reports an uncertain send, the host records that command and keeps listening; it will not
send the same reply again automatically. Check your phone before texting the command again.

Calendar, Contacts and Messages come from the Mac. `/forgetting`, `/why`, `/done`, `/meeting`,
`/pause`, `/resume`, `/status` and `/help` remain deterministic. Questions do not enable proactive
reminders; `/resume` enables the one-per-day rule. Keep the Mac awake and the process running.
Rerun `bash scripts/start.sh` after a restart or update. Do not run two hosts at once.

The default Mac model runs in the signed sandboxed worker installed by setup. For a larger
open-weight local model, stop the host with Control-C and run:

```bash
bash scripts/start-open-model.sh
```

This installs Ollama through Homebrew if needed, starts it on 127.0.0.1, downloads weights once,
and uses Qwen3.8 27B Q4 (about 18 GB) on a 40 GB+ Mac, Qwen3.5 9B on a 16–39 GB Mac, or
Qwen3.5 4B on a 12–15 GB Mac. On a 48 GB M4 Pro this is the 27B option. The starter disables
optional thinking for ordinary quick chat; personal evidence remains on the Mac. Model downloads
need internet once, while inference does not. `ASSISTANT_OPEN_MODEL=<tag> bash scripts/start-open-model.sh`
chooses another locally installed Ollama model. Use `bash scripts/start.sh` to return to Apple's
model. These are starting points based on model size and memory, not measured performance on
your Mac. Run one host at a time.

For a different local server, set `ASSISTANT_MODEL=local`, `ASSISTANT_MODEL_NAME`, and optionally
`ASSISTANT_MODEL_URL` when running `start.sh`. The URL must use literal loopback HTTP and a
`/v1` API. `ASSISTANT_LOCAL_REASONING_EFFORT` can request `none`, `low`, `medium`, or `high`
if that server supports it. “OpenAI-compatible” is the API shape on your own Mac; this project
does not require OpenAI or cloud credentials. A custom local server could itself forward
requests elsewhere, so its configuration matters. If generation is unavailable, owner commands
continue. `model-eval` and `check-model-worker.sh` are developer checks.

## Pair the phone companion

The phone companion can share sources on iOS 17+; its optional on-phone chat needs Apple
Intelligence and iOS 26+. It currently uses Apple's on-device system model while the app is open.
It does not run the Mac's 27B model or a downloaded open-weight phone model yet. Build it from
`Apps/AssistantPhone/AssistantPhone.xcodeproj` using Xcode on your Mac, your development team,
and your physical iPhone as the destination.

With both devices on the same local network, run this in a second Mac terminal:

```bash
.build/release/assistantctl pair-phone
```

A QR code opens on the Mac. Scan it with the iPhone Camera and open the result in Local Assistant.
Check that the eight-character verification code shown on the phone matches the Mac terminal,
then tap **Pair**. Restart `serve` once after initial pairing so it starts the phone receiver:

```bash
bash scripts/start.sh
```

If your Mac's default hostname is not reachable on your network, recreate the pairing code with
`pair-phone --host <Mac-LAN-IP>` and scan that code. Recreating pairing revokes the previous phone
credentials. The receiver uses local HTTPS port 8765; allow incoming local connections if macOS
asks. Credentials stay in each device's Keychain and the phone pins the Mac certificate.

In the phone companion, tap **Enable sleep sharing**. Only derived recorded-sleep totals for the
last 24 hours and seven days are uploaded. Raw Health samples stay on the phone. Calendar and
Contacts do not need a second phone permission flow because the assistant already reads them on
its Mac host.

The companion shows when the Mac last acknowledged an update. You can ask its separate local
chat about allowed phone Calendar, Contacts, and sleep information while the app is open.
That on-phone chat cannot read Messages or respond to the iMessage conversation if the Mac is
unavailable. Then ask in the same Messages self-chat: `How much recorded sleep do I have over the last 24 hours?`

HealthKit read denial is not disclosed by Apple. No readable samples can mean missing data or
read denial; neither is reported as zero sleep. Sleep windows are explicit rolling windows,
not medical conclusions or an exact label for "last night." Answers retain the collection time.

HealthKit background delivery needs the supplied HealthKit/background-delivery entitlements and
a compatible provisioning profile. If background delivery is unavailable, the app reports that
and syncs on open. Remove that extra entitlement if your team cannot provision it; foreground
sharing still works. Uploads use a file-backed background URLSession. Updates are queued durably
until the Mac acknowledges them, and opening the companion retries pending updates.

Turn off **Share sleep summaries** to queue a disable update; once received, the Mac removes sleep
from current answers. **Disconnect phone** stops uploads locally. `assistantctl unpair-phone`
revokes Mac authorization immediately. Neither action deletes historical evidence already stored
on the Mac.

## Current boundaries

This is a local-network phone connection. Away from the Mac's network, updates remain on the
phone until it becomes reachable. A user-controlled VPN can provide reachability; there is no
project cloud relay. Keep the Mac host running. A signed native Mac app/login-item lifecycle,
optional location, Mail, and broader model-based extraction remain separate later work.

The backend contract remains replaceable behind `LocalModelProvider`; Apple's on-device model
is the default Mac runtime and the current phone runtime. The optional Mac Ollama starter runs
open weights on localhost. The companion derives simple sleep summaries independently of its
chat model. Models cannot select recipients, change settings, or run action tools.
