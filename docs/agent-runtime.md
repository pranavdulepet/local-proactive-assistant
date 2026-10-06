# Conversation runtime

The Mac owns the conversation, source readers and response destination. The iPhone is the
Messages interface and an optional source companion. Model generation stays on the devices.
Normal iMessage delivery still uses Apple's service.

## Native conversation and tools

Ollama uses its native `/api/chat` endpoint, with real user, assistant and tool turns.
A message that needs no personal lookup can finish in one model response. A personal question
can resolve a contact, query a date interval, search Mail or discover and read a document,
then answer from those results. The host supplies the current clock and timezone.

There is no separate mandatory JSON planning response for Ollama. Read calls and results are
saved with the recent conversation, so a follow-up can refer to the person or exact dates
used in a previous lookup. Prior excerpts are compacted; freshness-sensitive questions must
read again. The loop allows six reads over at most five model steps, with bounded context.
It uses a 16,384-token context and disables optional thinking for ordinary Ollama chat.
The model must be installed locally; cloud-backed Ollama model metadata is rejected.

An existing offline `/v1` runtime can use native function tools too. Apple inference retains
its guided, typed planning path in the sandboxed worker. The source readers are the same.

Messages reads resolve contact names before searching, apply direction/date/topic predicates
before ordering and paging, and expose ambiguity rather than searching unrelated people.
Calendar reads use interval overlap, including overnight and all-day events. Mail filters
and sorts metadata before fetching selected bodies, reports stage-specific errors, and
returns a cursor when another page is available. None of these readers modifies source apps.

## Submission tracking

The inbox saves its outbound request ID before sending. The ledger and transport can then
look for that exact outgoing reply in the owner's verified phone and email chat aliases.
A matching GUID and local Messages row reconcile the queue after a send timeout or restart.
Catchup also reconciles delayed echoes. Ambiguous matches remain unresolved; the host never
resends a potentially submitted reply automatically.

A local Messages row confirms submission, not delivery to a phone. Old inbox turns created
before request-ID linking cannot safely be associated with old sends and remain uncertain.
They are not resent. All new command, progress and answer messages use the configured verified
reply route. A shared-account self-chat does not provide a separate sender identity or control
blue versus gray bubbles.

## Research and implementation choices

Reviewed October 6, 2026 using Exa searches and primary documentation. Instinct and Poke inform
the conversational product experience; their implementations are not copied. The useful
shared pattern is a persistent conversation, tools that return actual source results, and
clear progress and source access. Cloud hosting and arbitrary shell agents are unnecessary
for the local Mac/phone architecture.

| Primary source | Decision |
| --- | --- |
| [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling) | Use native assistant calls and `tool_name` results through `/api/chat` |
| [Ollama thinking](https://docs.ollama.com/capabilities/thinking) | Explicit thinking controls; avoid spending ordinary-chat latency on optional reasoning |
| [OpenClaw Ollama provider](https://docs.openclaw.ai/providers/ollama) | Native endpoint; its docs warn that the compatibility endpoint can break tool calling |
| [Vercel AI SDK agents](https://ai-sdk.dev/docs/agents/overview) | Conversation/tool loop and explicit stopping conditions; conceptual inspiration only |
| [Vercel AI SDK license](https://github.com/vercel/ai/blob/main/LICENSE) | Apache 2.0, so no code copied under the project's MIT-only copying constraint |
| [pi source and MIT license](https://github.com/badlogic/pi-mono) | Compare session/tool-result structure; implementation here is original Swift |
| [Apple JavaScript for Automation](https://developer.apple.com/library/archive/releasenotes/InterapplicationCommunication/RN-JavaScriptForAutomation/Articles/OSX10-10.html) | Resolve lazy object specifiers through getters; normalize actual Apple Events date values |
| [PhotoKit assets](https://developer.apple.com/documentation/photos/phasset) | Read permissioned asset metadata without requesting image bytes or cloud originals |
| [Safari export format](https://developer.apple.com/documentation/safariservices/importing-data-exported-from-safari) | Supported history/bookmark exports can be read as documents; no claim of a public live full-history API |
| [Instinct](https://instinct.co/) | Natural Messages-first interaction with personal context |

CI covers protocol interoperability, scoped source queries, durable follow-ups, submission
reconciliation, native host lifecycle, and iPhone builds. It does not measure this Mac's real
27B model latency or prove physical iMessage delivery, Apple Mail behavior, phone background
collection or a 24-hour unattended run. Record those results before claiming a finished release.
