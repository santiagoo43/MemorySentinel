# Security

For a potential vulnerability, use [GitHub private vulnerability reporting](https://github.com/santiagoo43/MemorySentinel/security/advisories/new). Include the version, reproduction steps, expected impact and a minimal example. Do not put sensitive diagnostics, exploit details or personal data in a public issue.

There is no guaranteed response time. The latest public release is the recommended version; older versions do not have a separate maintenance commitment.

MemorySentinel is a local monitoring tool, not a security boundary. It does not automatically terminate processes. Native actions recheck identity, ownership and application relationships, but the final POSIX check/signal race is not atomic. Force Quit can lose unsaved work.

The downloadable app is ad-hoc signed and not notarized. Check the release checksum and source before installing it. Do not disable system security protections to run it.

Exports may contain process names, executable paths, identities and memory measurements. Command-line arguments and environment variables are not collected, but an export can still reveal private workspace information. Review it before sharing.
