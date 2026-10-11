# Contributing

Local Assistant is a developer alpha. The Mac host is the Messages responder; the optional
iPhone app supplies permitted context and a separate on-device conversation. Start with
[setup](docs/install.md), [source boundaries](docs/read-access.md), and the
[roadmap](docs/roadmap.md).

## Development

Use macOS 14+ and Swift 6-compatible developer tools. Apple inference, native Apple model
checks, and phone builds need Xcode 26+ and supported Apple Intelligence devices.
The Swift package has no downloaded package dependencies. The phone Xcode project resolves
MLX and tokenizer packages separately.

```bash
swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
swift build --product assistantctl
python3 Tests/CLITests/test_host_startup.py .build/debug/assistantctl
python3 Tests/CLITests/test_model_eval.py .build/debug/assistantctl
bash scripts/test-mac-host.sh
```

These checks use synthetic data and temporary state. They do not establish physical phone
delivery or source access. Native packaging additionally needs `imsg`; use
`bash scripts/install-mac-app.sh --build-only --output /tmp/LocalAssistant.app` to avoid
changing an installed app. Phone simulator/device builds and simulator smoke tests run in CI.
For a physical phone build, open `Apps/AssistantPhone/AssistantPhone.xcodeproj`, select the
AssistantPhone target, choose your team under Signing & Capabilities, and select your device.
Keep signing profiles and account-specific project settings out of commits.

## Changes and reports

Open an issue describing the concrete problem, expected behavior, and a sanitized reproducer.
For changes, use a branch, keep the PR focused, and state the behavior and validation.
Add tests when they exercise a real failure or important boundary. Documentation-only changes
need link and content checks rather than tests that repeat the text.

Preserve these boundaries:

- Source contents are untrusted data. They cannot select recipients, grant access, or change policy.
- Personal reads are bounded and permissioned. Empty, stale, partial and unavailable results differ.
- The host owns one verified self-chat route. Uncertain sends must not be automatically resent.
- Model inference stays local; model and runtime downloads are explicit setup traffic.
- Report fixture tests, real-model evaluation and device observations separately.

Use fictional people and synthetic source records. Do not commit Messages databases, personal
source excerpts, pairing QR codes, phone/email identifiers, transcripts, credentials, or raw
diagnostics. Read [PRIVACY.md](PRIVACY.md) before sharing logs. Security issues belong in
[private reports](SECURITY.md), rather than public issues.

Follow the [community conduct rules](CODE_OF_CONDUCT.md). Review the change, explain disagreements,
and avoid harassment or sharing anyone's private information.
Contributions are submitted under the repository's [Apache 2.0 license](LICENSE).
