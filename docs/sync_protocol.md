# Planned synchronization contract ? not implemented in Phase 1

Drift is the student operational source of truth. A swipe commits progress, persisted queue/session changes and UID-owned outbox record atomically. A single-flight synchronizer uploads only the authenticated UID, then reconciles paginated remote progress, then content changes.

Operations have immutable IDs/payloads, expected server revision and per-device sequence. Server transactions validate publication/auth/claims and deduplicate before returning authoritative revisions. Revision mismatch preserves pending intent. Rebase latest still-current intent with a new linked operation ID and latest expected revision; bound retries and surface unresolved contention. Never use client wall clocks as authority or delete newer edits on acknowledgement. Later-arriving offline intent may supersede earlier accepted device intent. Convergence is conditional on edits stopping and successful retries. Dedup retention and safe retry expiry must be fixed before sync implementation.

Publication functions atomically update words, global monotonic revision, public changes/tombstones, safe manifest counts and audit. Public feed never contains drafts. Stage bounded download pages, catch up changes to a closing revision, verify complete membership, then commit and advance cursor transactionally. Concurrent changes invalidate/reconcile staged results; interrupted groups are never offline-ready. Expired cursor triggers full snapshot reconciliation. Tombstones remove active content/queues but preserve historical progress.

On account switch: cancel listeners/work, invalidate request generation, isolate UID stores; explicit logout clears private data with clear pending-loss UX. Device encryption, backup exclusions and retention require implementation decisions before private persistence. Offline devices cannot verify revocation or receive unpublication. New sign-in requires network. These limitations must appear in the product where relevant.

## Windows

Windows uses the same durable Drift outbox and server revisions as mobile. Implement an authenticated HTTPS API adapter for Windows rather than the unsupported cloud_functions plugin. Validate Firebase ID tokens server-side, check revoked/disabled sessions according to policy, preserve operation IDs across retries, and test the selected App Check strategy without disabling authorization. Verify Windows-to-mobile concurrent changes, termination/restart with pending writes and offline account isolation. This transport is planned, not implemented.

## Implemented local boundary in Phase 2

Native Drift outbox records operation ID, UID, installation device ID, word ID, desired status, base server revision, per-UID installation sequence, creation time, retry count/state/error. Swipe, queue, session outcomes and operation insert are one tested transaction. No uploader, acknowledgement, dedup server API or rebasing is implemented; UI labels all operations pending and never cloud-backed. Full content snapshot download is implemented with durable staging, manifest revision equality, exact nine-group counts and atomic commit. New content versions invalidate other cached groups' completeness until downloaded again. Incremental tombstone feeds and stale-history recovery remain for the publication/sync phase.

## Phase 3 implemented publication feed

The trusted contentApi now atomically writes each word mutation, a global revision, manifest/counts, safe change/tombstone/noop, audit and retry result. Noop records advance the global cursor without exposing private draft IDs. Feed payloads never include draft text. Restore returns unpublished; publish/review is explicit. The existing full-snapshot downloader remains unchanged. Incremental student feed consumption and progress upload are still unimplemented. See publication_api.md for retention/watermark/retry contracts and the server-produced-snapshot Dart compatibility probe.
