# Use the assistant in Messages

Messages is the only conversation interface. Keep the assistant running on your Mac and text
its configured private self-chat from your phone. The phone companion only connects phone
sources; it has no demo, context import, or separate chat screen.

## Start on your Mac

The Mac needs Apple Intelligence support, macOS 26+, Apple Intelligence enabled, and Xcode 26+
to build the model worker. Stop the previous foreground host before updating.

```bash
git pull --ff-only origin main
./scripts/setup-local-model.sh
.build/release/assistantctl model-status
.build/release/assistantctl serve --control-chat-id 955 --model apple
```

Use your validated private control chat ID if it differs from 955. From Messages on your phone,
send `What is on my calendar tomorrow?`. Questions ending in `?` do not need `/ask`.
For other phrasing, use `/ask <question>`. Ordinary notes remain ignored.

Calendar, Contacts and Messages come from the Mac. `/forgetting`, `/why`, `/done`, `/meeting`,
`/pause`, `/resume`, `/status` and `/help` remain deterministic. Questions do not enable proactive
reminders; `/resume` enables the one-per-day rule. Keep the Mac awake and the foreground process
running. You do not need the phone companion open to chat.

The Mac model runs in the signed sandboxed worker installed by setup. If generation is unavailable
or invalid, the assistant returns labeled evidence excerpts. No remote model service is configured.
`model-eval` and `check-model-worker.sh` are developer checks, not everyday app steps.

## Pair the phone companion

The phone companion runs on iOS 17+ and does not need Apple Intelligence. Build it from
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
.build/release/assistantctl serve --control-chat-id 955 --model apple
```

If your Mac's default hostname is not reachable on your network, recreate the pairing code with
`pair-phone --host <Mac-LAN-IP>` and scan that code. Recreating pairing revokes the previous phone
credentials. The receiver uses local HTTPS port 8765; allow incoming local connections if macOS
asks. Credentials stay in each device's Keychain and the phone pins the Mac certificate.

In the phone companion, tap **Enable sleep sharing**. Only derived recorded-sleep totals for the
last 24 hours and seven days are uploaded. Raw Health samples stay on the phone. Calendar and
Contacts do not need a second phone permission flow because the assistant already reads them on
its Mac host.

The companion shows when the Mac last acknowledged an update. Then ask in the same Messages
self-chat: `How much recorded sleep do I have over the last 24 hours?`

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
is the configured conversational runtime. The companion derives simple sleep summaries without
an LLM. Models cannot select recipients, change settings, or run action tools.
