# Contributing to Threadline

Threadline values native macOS behavior, deterministic data handling, privacy,
and explicit failure states. Changes must preserve provider histories as
read-only inputs and keep automatic reconciliation safe, quiet, and observable.

## Development requirements

- macOS 14 or later
- Apple Silicon for Preview distribution validation
- Xcode or Command Line Tools with Swift 6.1 support
- system SQLite with FTS5

Use an isolated checkout and synthetic data. Never point development or tests
at a real Threadline application-data directory or production sync folder.

## Build and test

Run from the repository root:

```bash
swift build
swift test
swift build -c release
make app
codesign --verify --deep --strict .build/Threadline.app
```

The suite combines XCTest and Swift Testing. Check that the relevant regression
test ran instead of relying only on a total count.

Useful make targets:

```bash
make build
make test
make app
make run
make clean
```

`make app` invokes `Scripts/package_app.sh`. It builds the Release executables,
generates the icon, rejects leaked absolute workspace paths, assembles the main
app and embedded helper, signs the bundle, and verifies the result.

The default signing identity is ad-hoc. A local identity can be selected for
repeatable development installs:

```bash
CODESIGN_IDENTITY="Your Local Signing Identity" make app
```

A local identity is not an Apple Developer ID, even when `codesign` prints an
Authority name. It does not provide Apple trust or notarization and commonly
causes Gatekeeper, Start at Login, or Keychain authorization prompts to recur
after replacing a build.

## Preview DMG packaging

The distributed Preview is an unsigned Apple Silicon DMG containing Threadline
0.2.1 (build 12). The app has a local code signature rather than an Apple
Developer ID signature. Neither app nor DMG is notarized. Installation
documentation must direct users to Finder's **Open** or **System Settings →
Privacy & Security → Open Anyway**. Never recommend disabling Gatekeeper,
running `spctl --master-disable`, or stripping quarantine metadata.

After `make app`, create the release artifacts with:

```bash
Scripts/package_dmg.sh
shasum -a 256 -c dist/Threadline-0.2.1-arm64.dmg.sha256
```

The script:

1. requires an existing app bundle, `.build/Threadline.app` by default;
2. reads the version and executable from the app's Info plist;
3. verifies the executable architecture and existing code signature;
4. stages `Threadline.app` with an Applications shortcut;
5. creates and verifies a compressed UDZO image;
6. writes and verifies a SHA-256 sidecar;
7. stages output temporarily and moves each finished file into place only after
   verification.

For the 0.2.1 Apple Silicon bundle the outputs are:

- `dist/Threadline-0.2.1-arm64.dmg`
- `dist/Threadline-0.2.1-arm64.dmg.sha256`

`dist/` is ignored by Git. Attach both files to the same GitHub Release so users
can verify the DMG before opening it. `APP_PATH` and `OUTPUT_DIR` may select a
different input app or output directory for isolated packaging tests.

The DMG script does not build or sign the app, sign the DMG, notarize either
artifact, staple a ticket, or publish a GitHub Release. A Developer ID pipeline
must add Apple signing with a timestamp, notarization, stapling, and release
publication without weakening the script's architecture, app-signature, image,
or checksum verification.

## Architecture and ownership

| Path | Responsibility |
| --- | --- |
| `Sources/ProviderKit` | Read-only Codex and Claude Code discovery and parsing |
| `Sources/ConversationCore` | Models, SQLite/FTS5, encryption, transport, devices |
| `Sources/ThreadlineRuntime` | Composition, ingestion, scheduler, sync, and health |
| `Sources/Threadline` | SwiftUI/AppKit app, menu bar, settings, and login control |
| `Sources/ThreadlineAgent` | Embedded prototype, not the active automatic loop |
| `Tests` | Unit/integration coverage and synthetic fixtures |

Changes to schemas, identifiers, provider cursors, manifests, folder layouts,
envelope formats, encryption keys, or device state are contract changes. They
require backward-compatibility analysis, migration or rejection behavior, and
tests that cover both old and new data.

## Automatic reconciliation contract

The main app owns automatic import and sync while it is running. Preserve these
invariants:

- startup requests reconciliation immediately;
- wake requests reconciliation;
- source events use a 15-second trailing debounce;
- a five-minute fallback requests reconciliation;
- the scheduler is single-flight;
- triggers received during a run coalesce into at most one follow-up run;
- manual Refresh or Sync never competes with an automatic run;
- automatic import precedes automatic sync;
- automatic work does not set the manual import/sync presentation flags;
- automatic publication updates library, selection, and detail without an
  intermediate empty UI state;
- failures keep the durable queue, appear as Needs Attention, and retry later.

Do not add a periodic visual ticker, spinner, toast, or modal for successful
automatic work. `Sync Now` means “run as soon as possible,” including queuing a
follow-up when automatic work already owns the single-flight operation.

Relevant coverage belongs in
`Tests/ThreadlineRuntimeTests/AutomaticReconciliationSchedulerTests.swift` and
the affected ingestion, synchronization, or application-services suite.

## UI status contract

Connection state and queue state are independent:

- never show **Up to date** when pending objects exist;
- pending data is **Waiting to sync**, not a diagnostic failure;
- a healthy sync-folder connection does not mean the queue is empty;
- automatic failures are visible without a modal in the sidebar, menu bar,
  Health Center, and Needs Attention view;
- Health Center shows queue count/bytes, last import, last completed sync,
  connections, and actionable diagnostics;
- buttons that would conflict with manual work are disabled, while automatic
  work may queue the next user-requested attempt through the model;
- spinners represent manual import/sync or explicit configuration work only.

Keep controls native, keyboard-accessible, and labeled for VoiceOver. Avoid
changing container identity or replacing stable content with progress UI during
background reconciliation.

## Keychain and update testing

Folder-sync keys are stored in the local login Keychain. Test upgrades without
deleting the user's database or key material:

1. create or join a sync space with an isolated application-support folder;
2. replace the app with a newly packaged local build;
3. verify that expected Keychain authorization is understandable and that
   denial surfaces Needs Attention without data loss;
4. verify that the recovery key is never requested by a macOS authentication
   dialog and never written to logs, fixtures, or the sync folder;
5. verify launch, wake, source change, fallback, and manual follow-up behavior.

Do not automate around security prompts by weakening Gatekeeper or Keychain
policy. A macOS authorization prompt uses the test account's login password,
not the Threadline recovery key.

## Making a change

1. Identify the affected persistence, synchronization, scheduling, or UI
   contract before editing.
2. Keep ownership and file scope explicit, especially for schemas, manifests,
   root configuration, shared UI state, and packaging scripts.
3. Add a regression test for changed parsing, persistence, crypto, transport,
   scheduler, failure, or migration behavior.
4. Run targeted tests, then the complete gates.
5. Review the final diff and packaged binaries for private data and absolute
   build-machine paths.
6. Document the current behavior and remaining limitations without writing a
   changelog into evergreen documentation.

Retries must be idempotent. Failures must remain distinguishable from success.
Do not resolve concurrency by dropping queued work, publishing partial state,
or allowing two processes to share the live database.

## Privacy and test data

Only synthetic, reviewable fixtures may be committed. Never commit:

- real conversation transcripts, databases, sync folders, diagnostics, or logs;
- usernames, hostnames, device identifiers, serial numbers, or private paths;
- recovery keys, Keychain exports, tokens, credentials, signing assets,
  provisioning profiles, or certificates;
- screenshots containing conversations or identifying metadata;
- generated `.build` products, DMGs, or IDE user state.

Provider and sync inputs are untrusted. Prefer bounded streaming reads, avoid
shell interpretation for provider commands, reject unsafe links and partial
records, and never log conversation content or secrets.

Use `THREADLINE_APP_SUPPORT`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR` with isolated
temporary directories for manual QA. Keep real cloud-provider directories out
of automated tests.

## Pull request checklist

- [ ] Scope and user-visible behavior are explained.
- [ ] Persisted and synchronized compatibility was evaluated.
- [ ] Provider inputs remain read-only.
- [ ] Automatic reconciliation remains single-flight and visually quiet.
- [ ] Queue and connection status remain semantically distinct.
- [ ] Tests cover the regression or contract change.
- [ ] `swift test` passes.
- [ ] `swift build -c release` passes.
- [ ] `make app` and `codesign --verify --deep --strict` pass when packaging is
      affected.
- [ ] The diff and binaries contain no private data or workspace paths.
- [ ] Distribution text does not imply Developer ID signing or notarization.

Report suspected vulnerabilities according to [SECURITY.md](SECURITY.md), not
through a public issue or pull request.
