# Model setup

Your Mac's model answers Messages. The optional iPhone app has its own model and conversation.
Questions and source storage stay on your devices. Model downloads use the internet;
Messages delivery uses Apple's service.

## Choose a Mac model

Stop the running assistant, then run this in the source folder:

```bash
bash scripts/start.sh --choose-model
```

Choose the suggested Ollama model, another local Ollama tag, Apple, or an existing local
server. Setup saves the choice and reuses downloaded weights. Smaller models leave more
memory for other apps.

Ollama works with macOS 14+ and Swift 6-compatible developer tools. Apple needs Apple
silicon, macOS 26+, Apple Intelligence enabled, and Xcode 26+. Setup checks availability
before starting the assistant. A model that supports tool calls is needed for source questions.

The assistant starts its own Ollama server at `127.0.0.1:11435`, with cloud features disabled.
Stopping the assistant stops that server and leaves other Ollama instances alone.

## Use an existing local server

Load a model that supports function tools and the `/v1` chat and model-list API. Then run:

```bash
ASSISTANT_MODEL=local \
ASSISTANT_MODEL_NAME=your-loaded-model \
ASSISTANT_MODEL_URL=http://127.0.0.1:1234/v1 \
bash scripts/start.sh
```

Use `http://127.0.0.1:<port>/v1` or `http://[::1]:<port>/v1`. Setup accepts local addresses
only. Configure the runtime for local inference; a proxy can still forward requests elsewhere.

## Pair the iPhone app

Build and install the [iPhone app](phone-models.md) on your physical phone. On the Mac,
choose **Stop → Pair iPhone** in Local Assistant. Scan the QR with the iPhone Camera,
open it in Local Assistant, and verify the code shown on the Mac. Choose **Start** on
the Mac to enable sharing. Begin on the same local network and approve Local Network
access on both devices if asked.

If you use the Terminal assistant instead, stop it and run:

```bash
.build/release/assistantctl pair-phone
```

Scan and verify the QR, then restart the assistant.

Enable each source separately in the phone app:

- Sleep: 24-hour and seven-day summaries.
- Activity: today's steps, active energy, and exercise totals.
- Coarse location: a recent location rounded to about 1 km.

Raw Health samples stay on the phone. Calendar and Contacts stay in the phone conversation;
the Mac reads its own synced Calendar and Contacts. Turning sharing off removes the
corresponding Mac snapshots after the update reaches it.

Uploads use encrypted, paired HTTPS. When the Mac cannot be reached, updates wait in a
queue; opening the phone app retries them. Away from home, phone uploads need a private
network path to your Mac. Messages questions still use Apple's delivery service.
Health background delivery is scheduled by iOS; activity and location update while the app
is open. Check capture times before relying on a summary.

[Setup](install.md) · [Phone models](phone-models.md) · [Everyday use](use.md)
