# Security Policy

Threadline handles conversation history that may contain source code, command
output, file paths, and other sensitive material. Security and privacy reports
are welcome and should be handled carefully.

## Supported versions

Threadline is currently an engineering preview. Security fixes are made on the
latest revision of the `main` branch; there is not yet a supported stable
release series.

| Version | Security support |
| --- | --- |
| Latest `main` | Best effort |
| Older revisions and local builds | Not supported |

## Reporting a vulnerability

Use GitHub's private vulnerability reporting option in the repository's
**Security** tab when it is available. Please do not disclose a vulnerability
in a public issue, discussion, pull request, or commit.

If private vulnerability reporting is unavailable, open a public issue asking
the maintainer to establish a private contact channel. Do not include exploit
details, conversation content, credentials, local paths, logs, database files,
or screenshots containing private information in that issue.

A useful private report includes:

- the affected Threadline revision or version;
- the affected macOS version and processor architecture;
- a concise description of the impact and affected trust boundary;
- minimal reproduction steps using synthetic data;
- whether the issue affects local storage, provider ingestion, encryption,
  folder transport, recovery, device registration, or the background helper;
- any suggested mitigation, if known.

## Current security boundaries

- Provider histories are read-only inputs. Threadline is not intended to modify
  the original Codex or Claude Code history files.
- The local SQLite library contains readable conversation content. Its local
  confidentiality depends on the macOS user account and storage protections
  such as FileVault.
- Conversation payloads are encrypted by Threadline before they are written to
  an iCloud Drive, OneDrive, or Google Drive sync folder. Local-only mode does
  not write conversation payloads to a remote folder.
- Recovery-key handling, provider migration, key rotation, and strong device
  revocation remain security-sensitive release gates. A device marked as
  forgotten is not guaranteed to lose data or key material it already has.
- Cloud-storage providers can observe file metadata such as names, sizes,
  timing, and activity even though conversation payloads and device profiles
  are encrypted.
- Threadline is an index and synchronization client, not a backup authority.
  Keep the original provider histories while the project remains a preview.

These boundaries are not a substitute for reporting a suspected vulnerability.
