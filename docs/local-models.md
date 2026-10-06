# Local models and phone setup

Your Mac's model answers Messages. The phone's model answers inside the companion app and
uses phone sources you enable. They are independent choices. Source storage and generation
stay on your devices; normal Messages delivery uses Apple, and downloading weights requires
network access once.

## Mac models

The guided starter installs Ollama if selected, saves your model choice, and reuses downloaded
weights. Stop the active host before switching:

```bash
bash scripts/start.sh --choose-model
```

Choose the suggested open model, another local Ollama tag, Apple, or an existing offline
server. On the 48 GB Mac the saved Qwen3.8 27B Q4 choice can be reused. Memory-based suggestions
are documented in the README; they are not benchmarks or a guarantee of conversational quality.

Ollama uses the native `/api/chat` tool protocol at the owned `127.0.0.1:11435` server.
The host verifies that the named local weights are installed and rejects cloud-backed model
metadata. Cloud features are disabled. Optional thinking is disabled for ordinary chat,
with a 16K context budget and bounded read loop. A tool-capable model is needed for personal
source questions. Smaller models may be faster and leave more room for other apps.

For an existing offline runtime with function tools:

```bash
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_NAME=your-loaded-model \
ASSISTANT_MODEL_URL=http://127.0.0.1:1234/v1 \
bash scripts/start.sh
```

`/v1` names a local API shape; it does not call OpenAI. The endpoint must be literal loopback
HTTP, and redirects are blocked. Configure the runtime itself for local inference; a local
proxy that forwards data is not an offline model.

Apple needs Apple silicon, macOS 26+, Apple Intelligence and Xcode 26+. The signed, sandboxed
worker runs the system model without extra app-downloaded weights. Its availability is checked
before serving. Apple uses typed read planning; Ollama and tool-compatible local servers retain
native assistant/tool turns.

Inspect a model directly:

```bash
.build/release/assistantctl model-status --model ollama \
  --model-url http://127.0.0.1:11435 --model-name qwen3.8:27b-q4_K_M
.build/release/assistantctl model-status --model apple
```

The Ollama server must be running for its status call. The Mac menu bar app supervises it and
the host without Terminal. It reuses the saved profile. Enable **Start at login** to resume
at login; the Mac must remain logged in, awake and online for phone texts to receive replies.

## Phone models

The companion now has a model selector: Apple, Qwen3 0.6B 4-bit, Qwen3 1.7B 4-bit, or an imported
compatible small MLX model folder. Open weights download only when you tap the download button.
Inference loads the saved local directory. The default Apple option needs an Apple Intelligence
capable iPhone; the MLX option requires a physical iPhone and enough free memory.

See [phone model installation, importing and runtime licenses](phone-models.md). These are
available options in the code, not proof that any particular model is installed on your phone.
Neither simulator CI nor a generic device build measures physical phone generation quality.

## Pair phone context with the Mac

Build and install `Apps/AssistantPhone/AssistantPhone.xcodeproj` using Xcode, your signing team
and your physical iPhone. Stop the Mac host, then pair on the Mac:

```bash
.build/release/assistantctl pair-phone
```

Scan the displayed QR using the iPhone Camera, open it in Local Assistant, and verify/confirm
the Mac pairing in the app. Restart the Mac host to start its paired HTTPS listener. Start on the same local network. Enable each source separately:

- Sleep: derived 24-hour and 7-day summaries.
- Activity: today's readable steps, active energy and exercise totals.
- Coarse location: one recent foreground fix, rounded to about 1 km.
- Phone Calendar and Contacts: available to the on-phone conversation when granted.

Raw Health samples stay on the phone. Missing Health readings are unknown rather than zero.
Location collection stops after the foreground request; it is not live tracking. The paired
upload queue sends derived sleep/activity/location snapshots over authenticated, certificate-
pinned HTTPS and preserves their original capture times. Turning sharing off removes the
corresponding Mac snapshots after the update reaches it.

Phone Calendar/Contacts are currently read by the phone model; they are not uploaded by this
snapshot channel. The Mac has its own Calendar/Contacts connectors. Photo metadata comes from
the Mac Photos library. The companion cannot read iOS Messages or other apps' private storage.

When the paired HTTPS address is unreachable, updates stay queued. A private network path is
needed to upload from away from home; no public relay is configured. iMessage questions can
still reach the Mac from anywhere Apple Messages works. Health background delivery is system-
scheduled; activity/location collect while the app is open. Opening the companion retries
queued updates. There is no permanent iOS background LLM process.

## What to test on real devices

Start with `/status`, then a calendar date question and follow-up, a real person's latest
incoming message, and an unread Mail query. Confirm the dates, person, contents and source
references against the source apps. Long answers should show one progress acknowledgement
where native typing is unavailable, followed by one answer.

After pairing, enable activity or location, sync, and ask the Mac about the uploaded source.
Check the capture time, especially after being away from the Mac. For a phone open model,
download once, turn off networking, then use **Ask on this iPhone**. Try Start/Stop and login
startup, lock/display-off behavior, restart catchup and a 24-hour run. Closing the Mac lid can
still stop replies. Record actual outcomes before calling the product release-ready.
