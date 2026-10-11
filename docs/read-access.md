# Source access

Connect sources in the Mac app or during Terminal setup. Send `/status` to see access
and freshness. Permissions for Local Assistant and Terminal are separate; grant access
to the app running the assistant. You can skip optional sources and still chat.

| Source | Permission | What it reads |
| --- | --- | --- |
| Messages | Full Disk Access; Messages Automation for replies | Indexed direct text messages |
| Calendar | Full Calendar access | Synced events from 90 days back to 365 days ahead |
| Contacts | Contacts access | Names, nicknames, phone numbers, and email addresses |
| Mail | Mail Automation | Locally synced folders, matching messages, and selected bodies |
| Notes | Notes Automation | Exposed titles and plain-text bodies |
| Reminders | Reminders access | Synced lists, titles, notes, completion, and due dates |
| Photos | Photos access | Dates, media types, dimensions, albums, and rounded locations |
| Documents | Folder access | Text, PDF text, and supported office files in permitted folders |
| Browser exports | A permitted export folder | History or bookmark files you select |
| Mac information | Built-in system reads | OS, hardware type, memory, and CPU counts |
| iPhone | Paired app and individual iOS grants | Sleep, activity, and coarse location summaries; Calendar and Contacts in phone chat |

Photos reads metadata, not image contents. Messages groups and attachments are excluded.
Locked notes, mail attachments, scanned PDFs, and files not downloaded from iCloud are
not included. Searches return selected records, so an empty result does not prove an item
is absent. The iPhone app reads the sources you enable; it cannot read iOS Messages or
other apps' private databases.

If a source is unavailable, retry **Connect** in the Mac app or run
`.build/release/assistantctl prepare-access` in Terminal. Check System Settings →
Privacy & Security for the relevant app. See [setup troubleshooting](install.md#troubleshooting).

Source tools only read. They do not run shell commands, change apps, or choose message
recipients. Document reads exclude credential files and hidden private directories.
Revoking access stops future reads but does not erase saved records; see
[Privacy and removal](../PRIVACY.md).
