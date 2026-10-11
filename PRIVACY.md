# Privacy and local data

The assistant stores its index, conversation history, source-access state, reply ledger,
pairing configuration and logs under
`~/Library/Application Support/LocalProactiveAssistant/`. These files can contain sensitive
personal information. They are local files, not a separately encrypted application database.
Your account and filesystem protections apply. Backups may retain copies.

The source repository contains no runtime database or model weights.
There is no project analytics backend. Setup contacts GitHub, Homebrew, Ollama and, for an
explicit phone model download, Hugging Face. Those services receive normal download traffic.
During inference, the configured model runs locally; Messages replies use Apple's delivery
service. A third-party local runtime or proxy must be configured independently for offline use.

## Source access

macOS and iOS grant access per source and responsible application. Optional sources may be
denied while ordinary chat continues. Full Disk Access is required for the Mac Messages
database. Photos reads currently use asset metadata, not image understanding. Documents use
permitted roots and supported formats. See [read-access.md](docs/read-access.md) for coverage.

Revoking an OS permission stops future permitted reads. It does not erase previously indexed
records or conversation history. `/forgetting` lists open commitments; it is not a data-erasure
command. Stopping the host or `/pause` does not delete stored data either.

## Disconnect or remove

1. Stop the host and disable **Start at login** in the Mac app before quitting it.
2. To revoke the companion, run `.build/release/assistantctl unpair-phone` from a source build,
   or `"$HOME/Applications/LocalAssistant.app/Contents/Resources/Runtime/bin/assistantctl" unpair-phone`
   from an installed app while the host is stopped. This removes the Mac pairing credential
   and QR file; indexed phone evidence remains. Tap **Disconnect phone** in the phone app as well.
3. Revoke Local Assistant's source/Automation/Full Disk Access grants in System Settings if
   you no longer use it. Remove the application through Finder.
4. To erase the assistant's saved configuration, index, conversations and logs, remove
   `~/Library/Application Support/LocalProactiveAssistant/` through Finder while all hosts
   are stopped. This also removes the private runtime and worker installed there. It leaves
   Apple's original Messages, Mail, Calendar and other source libraries alone.
5. Remove the iPhone app to remove its installed models and application data. Separately
   installed Homebrew/Ollama software and Ollama's model cache are outside the assistant's
   state directory; manage them with their own tools if desired. Backups and iCloud source
   copies are managed separately.

## Sharing diagnostics

Public issues should contain versions, elapsed times, permission/error categories and
synthetic reproductions. Logs can include message text, contact identifiers, paths, source
excerpts and pairing information. Read and redact each attachment; do not upload the whole
state directory or information that identifies your device or account.
