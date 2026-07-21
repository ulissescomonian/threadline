# Threadline Agent Guide

## Project

Threadline is a native macOS 14+ Swift 6.1 application that imports Codex and
Claude Code histories as read-only inputs, indexes them locally in SQLite/FTS5,
and optionally synchronizes encrypted envelopes through a user-selected cloud
folder. It is an engineering preview: packages are ad-hoc signed by default or
may use a local identity, but are not Developer ID signed or notarized. Provider
histories remain the authoritative originals.

## Architecture

- `Sources/ProviderKit`: bounded discovery and parsing of provider histories.
- `Sources/ConversationCore`: models, SQLite/FTS5, blobs, encryption, devices,
  manifests, and folder transports.
- `Sources/ThreadlineRuntime`: application composition, ingestion, sync,
  health, configuration, filesystem monitoring, and scheduling.
- `Sources/Threadline`: SwiftUI/AppKit application, menu bar, settings, and
  presentation state.
- `Sources/ThreadlineAgent`: embedded prototype; it is not the authoritative
  automatic-reconciliation path while the main app is running.
- `Tests`: unit/integration tests and synthetic fixtures only.

Keep dependencies flowing toward lower layers. UI code must not reimplement
storage, crypto, provider parsing, or transport policy.

## Commands

Run from the repository root:

```bash
make build                         # Debug build
make test                          # Complete test suite
swift test --filter TestName       # Focused regression test
swift build -c release             # Release build
make app                           # Ad-hoc signed .build/Threadline.app
make run                           # Package and launch the local app
codesign --verify --deep --strict .build/Threadline.app
Scripts/package_dmg.sh             # Verified DMG + SHA-256 in dist/
```

`make app` embeds `ThreadlineAgent`, icons, plists, and provider assets; it also
rejects binaries containing the absolute workspace path. For provisioned
CloudKit packaging, set both `CODESIGN_IDENTITY` and
`ENABLE_CLOUDKIT_ENTITLEMENTS=1`. Ad-hoc signing cannot carry CloudKit
entitlements.

After `make app`, create and verify the Preview DMG with:

```bash
Scripts/package_dmg.sh
(cd dist && shasum -a 256 -c Threadline-0.2.1-arm64.dmg.sha256)
```

`APP_PATH` and `OUTPUT_DIR` may override the default bundle and output
directory. Keep `dist/` out of Git and upload the DMG plus checksum as GitHub
Release assets. Do not describe an ad-hoc or locally signed app as notarized.

## Swift and SwiftUI conventions

- Preserve Swift 6 strict-concurrency correctness. Use actors for mutable
  shared state, `Sendable` boundaries, cancellation-aware tasks, and weak
  captures for long-lived callbacks.
- Keep UI and observable presentation state on `@MainActor`; do parsing,
  SQLite, crypto, file I/O, and synchronization off the main actor.
- Never block an actor or the main thread with semaphores or synchronous waits.
- Prefer explicit state machines and idempotent operations over timing-based
  assumptions. Do not allow overlapping imports, syncs, or migrations.
- Treat provider and sync files as untrusted input. Bound file, line, payload,
  event, and concurrency sizes; reject traversal and unsafe symlinks.
- Use native SwiftUI/AppKit behavior and accessibility labels. Avoid transient
  empty states: stage related list/selection/detail changes and publish them
  together; do not assign observable values when they are unchanged.
- Use `OSLog` without conversation content, recovery keys, tokens, or raw local
  paths. Sensitive error details must use private/hash privacy.

## Automatic reconciliation contract

The main app owns automatic reconciliation while it remains running, including
menu-bar-only operation:

- Run `ingestAll` followed by `syncNow` on startup and macOS wake.
- Monitor only Codex `sessions`, Codex `archived_sessions`, and Claude Code
  `projects`; do not create missing provider directories.
- Reconcile after source writes have been quiet for 15 seconds.
- Request a periodic fallback every 5 minutes.
- Enforce single-flight execution. Requests arriving during a run are
  coalesced into at most one follow-up run.
- A manual refresh/sync request during an automatic run schedules that
  follow-up instead of overlapping or being discarded.
- Automatic runs are visually silent: no import banner, sync spinner, progress
  stream, modal, or button dim/undim cycle. Publish one consolidated library
  update after ingestion and sync, while preserving the current selection.
- Store automatic failures separately from manual action errors. A later cycle
  clears the automatic error only after both ingestion and sync succeed.
- `Sync Now` remains the explicit user-visible path and preserves progress and
  actionable modal errors.

Changes to this contract require scheduler/monitor regression tests and UI
validation for both unchanged libraries and a changing selected conversation.

## Synchronization and security

- Provider histories are read-only. Never edit, move, delete, or synchronize
  their original files.
- Never place the live SQLite database or readable transcripts in cloud
  storage. A folder sync space contains authenticated/versioned metadata,
  manifests, and coordination markers plus encrypted records and envelopes;
  do not describe every file in the folder as ciphertext.
- The recovery key is the user-visible representation shown during setup. The
  app must never persist it. For folder sync, persist only the active `keyData`
  in the local, non-synchronizable macOS Keychain; never write either value to
  the sync folder, logs, fixtures, screenshots, or Git.
- Preserve Keychain access-group validation and rollback semantics where they
  apply. Synchronizable-Keychain/local-fallback behavior belongs to the legacy
  or CloudKit spike path and must not be introduced into folder sync.
- Folder access must remain user-selected and security-scoped. Validate
  bookmarks, manifests, sync-space identity, key fingerprints, and destination
  emptiness before mutation.
- Sync publication must remain encrypted, bounded, atomic, idempotent, and safe
  for retry, partial downloads, delayed/out-of-order files, and conflicts.
- Device removal is cooperative, not cryptographic erasure. Do not imply strong
  revocation without key rotation.
- Use isolated temporary directories and `THREADLINE_APP_SUPPORT` for tests.
  Never test against real provider histories, application data, or cloud sync
  folders.

## Validation

For focused changes, run the nearest relevant tests first. Before handoff of a
code or packaging change, run:

```bash
swift test
swift build -c release
make app
codesign --verify --deep --strict .build/Threadline.app
git diff --check
```

Add regression coverage for changes to parsing, persistence, migrations,
encryption, manifests, cursors, batching, conflicts, recovery, scheduling, or
failure semantics. Inspect the final diff and Release binaries for real
transcripts, credentials, device identifiers, private paths, and generated
artifacts.

## Hotspots

Treat these as single-owner integration points during concurrent work:

- canonical models, SQLite schemas/migrations, IDs, and cursors;
- envelope formats, batching limits, manifests, device registry, and crypto;
- `RuntimeConfiguration`, sync configuration/migration, and runtime assembly;
- automatic scheduler, filesystem monitor, and `AppModel` reconciliation;
- `Package.swift`, root build scripts, plists, entitlements, signing, and login
  item packaging;
- shared UI state, navigation selection/detail publication, and health status;
- shared fixtures, generated resources, and repository documentation.

Do not edit the same hotspot concurrently. Route cross-layer contract changes
through its current owner and validate the integrated diff.

## Git rules

- Preserve unrelated user changes in a dirty worktree. Inspect `git status` and
  the relevant diff before editing.
- Do not use destructive commands such as `git reset --hard`, broad recursive
  deletion, or checkout-based file restoration without explicit authorization.
- Only the designated coordinator may change branches, stage, commit, rebase,
  push, force-push, or otherwise rewrite Git state.
- Never commit `.build`, IDE user state, real databases, sync folders, logs,
  credentials, signing assets, or non-synthetic conversation data.
- Keep commits focused and explain changed persistence/sync/security contracts
  plus validation evidence. Force-push only when explicitly requested and use
  an exact `--force-with-lease` expectation.
