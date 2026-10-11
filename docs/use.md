# Use Local Assistant

Send questions to the self-chat you paired during setup. Your Mac answers through Messages
while it is logged in, awake, online, and running the assistant.

Try “What's on my calendar tomorrow?” or “Find the notes about the project deadline.”
You can ask follow-up questions in the same chat. Replies start with `Assistant:`.
The assistant reads connected sources; it does not send mail, change calendar events,
or make purchases. Check source references before relying on an answer.

## Commands

| Send | Result |
| --- | --- |
| `/status` | Source access, freshness, reply queue, and reminder status |
| `/ask <question>` | Ask the local model; ordinary text also works |
| `/meeting <exact person>` | Next indexed meeting and recent direct messages |
| `/forgetting` | List open commitments found in your messages |
| `/why <id>` | Show the source for a commitment |
| `/done <id>` | Mark a commitment complete |
| `/resume` | Enable proactive reminders |
| `/pause` | Pause reminders; questions still work |
| `/help` | Show available commands |

## Reminders

Reminders start paused. Send `/resume` to enable them. The assistant looks for supported
commitments in recent messages you wrote and can remind you within three hours of their
due time. It sends at most one reminder per day and per 24 hours, with quiet hours from
10 PM to 8 AM in your Mac's timezone.

Use the ID in a reminder with `/why` or `/done`. If a send cannot be confirmed, reminders
pause automatically. Check the self-chat and `/status` before resuming.
`/forgetting` lists commitments; it does not erase saved data.

## Optional iPhone app

The [iPhone app](phone-models.md) has a separate local conversation. You can also
[pair it with the Mac](local-models.md#pair-the-iphone-app) to share selected sleep,
activity, and coarse location summaries. The Mac still answers your Messages chat.

[Setup](install.md) · [Source access](read-access.md) · [Privacy and removal](../PRIVACY.md)
