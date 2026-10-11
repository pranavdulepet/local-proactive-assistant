# Security

## Report privately

Use [GitHub's private vulnerability report form](https://github.com/pranavdulepet/local-proactive-assistant/security/advisories/new)
for recipient-routing bypasses, prompt-injection boundary failures, unintended source access,
pairing/authentication failures, credential leaks, or local inference requests reaching a remote service.
Private reporting is enabled for this repository. Include the affected commit/release, a
synthetic reproducer, expected behavior, and impact. Do not attach personal databases or keys.
There is no promised response time or security audit certification.

## Supported scope

Security fixes target the latest alpha and `main`. Older alpha versions are not maintained
separately; update when a fix is released. The alpha is experimental and has not completed
the [stable release acceptance checks](docs/roadmap.md).

The native host is trusted with the sources you permit. macOS Full Disk Access is a broad OS
permission: the application's bounded tools are an additional code boundary, not an OS-level
restriction to Messages alone. A local process or account with equivalent privileges can
access the stored data. Keep your Mac account protected and disk encryption enabled.

The Apple inference worker is sandboxed. Other local runtimes have their own security model;
use a runtime you control. A loopback proxy can forward requests even though setup rejects
remote endpoints. Do not expose the Ollama or phone-sync listener to the public internet.

Replies go through Apple's iMessage service. Source reads and model generation are local,
but reply text leaves the Mac through Messages. Optional phone uploads use paired HTTPS and
certificate pinning. The model has no general shell or source-writing tool. These boundaries
are covered by tests, but tests do not prove that all attacks or platform failures are prevented.
