# Source access and coverage

The Mac reads connected local sources with macOS permission. `/status` shows freshness and
last observed access in compact form; the menu bar app also shows source details. A permission
check and a complete search are different results. Mail setup now performs a real limited
Inbox read instead of certifying access from an account-metadata probe alone.

| Source | Required access | Current scope | Gaps |
| --- | --- | --- | --- |
| Messages | Host Full Disk Access; Messages Automation for replies | Indexed direct text; full-name/handle resolution and direction/date/topic filters before paging | Groups, attachments, edits/deletions |
| Calendar | Full Calendar access | Refreshed window:90 days back to365 days ahead; true interval-overlap queries, including overnight/all-day events | Deleted-event reconciliation; unsynced calendars |
| Contacts | Contacts access | Names, nicknames and exact phone/email identity joins | Limited grants; ambiguous names require clarification |
| Mail | Mail Automation and locally synced accounts | Inbox or query-directed account/local folders, filtered metadata, selected bodies and pages | Attachments, missing bodies/folders, search time/size limits |
| Notes | Notes Automation | Exposed title and plain-text body search | Locked notes, attachments and scripting limits |
| Reminders | Native Reminders access | Synced lists, completion/due predicates and title/notes | Attachments and unsynced items |
| Photos | PhotoKit permission | Creation dates, media kind, dimensions, album names, rounded locations; limited grants honored | Image understanding/OCR, cloud originals and unselected assets |
| Documents | Permitted folders | Documents/Desktop/Downloads/local iCloud Drive plus selected folders; text, PDF text and supported office formats | Scanned PDF/OCR, cloud placeholders and unsupported formats |
| Browser exports | User-selected export folder | Safari history/bookmark exports can be read as permitted documents | No live full-browser-history connector; no passwords/payment data |
| Mac information | Fixed metadata calls | OS, hardware identifier, memory and CPU counts | Screen/audio capture, arbitrary app interiors and protected secrets |
| iPhone | Signed companion and individual iOS grants | Selected phone sources, local inference and paired uploads described in phone setup | App-private storage, Messages database, arbitrary background collection |

Mail is not an exhaustive Inbox scan. It identifies query matches before fetching selected
bodies, orders by received date and exposes a next-page offset. Reads are bounded by time,
256 mailboxes and5,000 matches. The model receives at most eight records per read and may
ask for another page or refine the query. Unknown dates and unreadable bodies are identified.
Stage-specific Apple Events diagnostics distinguish actual permission denial from a scripting
failure such as -2700. An empty or incomplete result does not establish that an email is absent.

Source failures update the access registry. Retry setup with **Connect sources** in the Mac
app or `.build/release/assistantctl prepare-access` in Terminal. Native app and Terminal grants
are separate. macOS decides which responsible app appears in Privacy & Security; approve the
host actually running the reader. No model can grant permissions.

## Phone and platform boundaries

Texting from elsewhere works through iMessage while the Mac is awake, signed in, online and
running. Phone context uploads use paired HTTPS with certificate pinning. A reachable local
or private network path is needed; queued phone data waits until that path is available.
There is no public cloud relay or unrestricted remote exposure by default.

The companion cannot read iOS Messages, other apps' private databases, arbitrary Mail account
contents, the whole filesystem or every notification. iOS background tasks are scheduled by
the system and are not a permanent agent process. Photos, microphone, motion and other public
frameworks require individual connectors and grants; their presence on the OS is not a
promise that this repository currently reads them. Health read denial can look like an empty
result, so missing samples are not reported as zero sleep or activity.

The Mac model has no generic shell, app-writing or recipient-selection tool. Passwords,
credential files and hidden private directories are excluded from document reads. All source
contents remain data, including instructions embedded in a message or document.

## Messages behavior and release evidence

All replies use the verified route configured by the host, preferring the owner's phone
number. A shared Apple Account does not guarantee gray bubbles. Progress feedback uses a
native typing capability only when supported, otherwise one short text after a slow turn.

Timeouts are reconciled against actual outgoing rows and GUIDs across verified aliases.
Ambiguous sends remain unresolved and are not retried. Old uncertain queue records created
before outbound request-ID linking remain visible because they cannot be safely reconstructed.
A locally observed row confirms submission, not physical phone delivery.

CI verifies source filtering, tool protocols, persistence, packaging and platform builds.
Physical Phone/Mac source checks, real-model answers, remote-context delivery, lock/restart
behavior and a24-hour run are still release acceptance work. Keep actual results separate
from automated fixture coverage.
