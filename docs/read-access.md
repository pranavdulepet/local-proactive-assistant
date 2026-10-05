# Source access and coverage

The Mac answers from information its adapters can read with your permission. A source being
readable does not mean every account, item, attachment or revision has been indexed.
`/status` shows indexed-source freshness and the last observed Mail, Notes and Reminders
access. A check can become stale if permissions, accounts or app state change.

| Source | Access | Search and answer scope | Remaining gaps |
| --- | --- | --- | --- |
| Messages | Terminal Full Disk Access; Messages Automation for replies | Indexed one-to-one text; verified self-chat is the command interface | Groups, attachments, edited/deleted message reconciliation |
| Calendar | Calendar full access | Refreshed events from 90 days ago through 365 days ahead; requested dates narrow the answer | Deleted-event reconciliation and overnight overlap retrieval |
| Contacts | Contacts access | Local contact names, handles and identity joins | Limited grants and ambiguous names need clarification |
| Mail | Mail Automation and configured accounts | Current unread Inbox queries filter before the result limit; specific queries can search account and local folders, including Archive/Sent; dates and pages are supported by the adapter | Unavailable folders/bodies, attachments, mail not exposed by Mail, and incomplete searches |
| Notes | Notes Automation | Title/body query before bounded inspection; plain-text excerpts from exposed notes | Locked items, attachments, unsupported scripting and limits reported with results |
| Reminders | Reminders full access via EventKit | Synced lists; incomplete/completed and date predicates; matching titles/list names/notes | Attachments and items not synced or exposed by EventKit |
| Documents | Folder access and locally chosen roots | Documents/Desktop/Downloads/downloaded iCloud Drive plus selected folders; text, PDF text and supported office formats | Scanned PDFs/OCR, cloud placeholders, unsupported formats; hidden/credential files excluded |
| Mac information | Fixed local metadata reads | OS, hardware identifier, memory and CPU counts | Screen/app contents, account secrets and arbitrary system interrogation |
| Phone | Optional signed companion and platform grants | Selected phone Calendar/Contacts/derived Health sleep context; paired sync | Entire phone storage, iMessages, unrestricted background reads, Photos/voice/location adapters, open-weight phone model chooser |

Mail searches no longer take an arbitrary first-100 Inbox sample and then filter it. They
select matching messages first, sort them by date and return a page. The search has a time
budget and enumeration limits (256 mailboxes and 5,000 identified matches); a page contains
at most 100 messages and the conversational context at most eight excerpts. Coverage says
whether searching completed and whether another page or unavailable data remains. A brief
answer can still omit mail. Ask for a specific sender, topic, folder or date when you need
to find a particular item. Empty or incomplete results never prove an email does not exist.

Source errors distinguish reported access denial, missing setup, timeout, an unavailable app
and scripting/read failures. An unclassified error does not establish that permissions were
denied. Re-run `.build/release/assistantctl prepare-access` on the Mac to retry source setup.
The selected local model cannot grant permissions, run a shell or modify source data.

All progress messages, conversational answers and command replies use the same verified
phone route where one exists. They are labeled `Assistant:`. The same Apple Account remains
the sender, so the host cannot guarantee gray bubbles. A separate assistant account or
device identity is a separate setup feature, not a text-formatting option.

This is a development-stage foreground host. Automated fixtures test bounds, query behavior,
failure handling and persistence; they do not certify real-model answer quality or physical
iMessage delivery. Release work still includes a signed native installer/login item, richer
message/time queries, real Mac/phone latency and accuracy evaluation, and broader phone
sources where iOS permits them.
