# Trusted vocabulary publication API (Phase 3)

## Phase 11 managed authorization

Enrolled accounts also require a non-pending/enabled server membership with matching role/adminRevision and fresh auth_time. account-change-pending/session-stale return 401; an older session's refresh may be insufficient after revocation, requiring a new sign-in after the management result's timestamp. Vocabulary mutation bodies/receipts remain unchanged. Updated rules gate privileged reads too. Missing membership preserves legacy behavior; see user_admin_api.md for adoption/rollout/trust boundaries. Nothing was deployed.

## Phase 9 trusted import integration

importApi (documented in import_api.md) reuses validateMutation/validateContent/requirePublishable and applyContentMutation. A trusted server-only transaction participant reads frozen job/item preconditions before writes and atomically commits the item receipt/counters/import audit with the existing publication transaction. The contentApi HTTP body, response, authorization, limits and direct-write denial remain unchanged; clients cannot supply this participant. Import create always produces a draft/noop. Import update preserves publication state and requires the existing reviewed=true/completeness checks for a published word. Publication revisions/counts/feed and stable IDs/progress remain authoritative. No deployment is included.

## Phase 8 Student consumer

The native Student client now consumes this existing publication contract after progress synchronization. Earlier statements below about the unchanged full downloader describe Phase 3's delivery boundary. See sync_protocol.md and phase8_handoff.md for the current per-downloaded-category checkpoints, bounded feed reads, atomic Drift commit and verified snapshot recovery. No backend API, security-rule or registration change is introduced by Phase 8.

Read contentChanges in canonical document-ID order, strictly after the saved revision and through the opening manifest revision. Every revision must appear, including payload-free noops. Upserts reference the current published/non-retired word payload; removals hide cached words and prune queues while retaining history. A changed closing manifest invalidates staged work. Published-ID lookups always include isPublished=true/isRetired=false, including in an editor-authenticated Student session. A missing payload or permission-denied ID lookup triggers the verified public full-query fallback rather than exposing drafts or inferring a tombstone. The emulator probe verifies unpublished/restored drafts remain unreadable under public credentials.

The existing published-word indexes cover these queries; contentChanges uses its document-ID index. No new index is added. Emulator success does not verify index deployment in a live Firebase project. Retention remains unpruned in production code; tests alter only demo emulator records to exercise expired cursors and gaps. Revisions must never be reset. Clients reject server rollback without downgrading their cache.

Implementation: `users/firebase/functions/src/content.ts` and `content_validation.ts`. HTTPS endpoint: `POST https://us-central1-PROJECT_ID.cloudfunctions.net/contentApi`; local isolated emulator: `http://localhost:15001/demo-vocabulary/us-central1/contentApi`. Nothing has been deployed.

## Authorization and request envelope

Send `Authorization: Bearer FIREBASE_ID_TOKEN` and `Content-Type: application/json`. The server verifies token revocation/disabled state, fetches current Auth claims, requires verified email and `content_manager` or `super_admin`, and rejects stale approved-role claims. Profile documents never authorize operations. Authorization is rechecked even for an idempotent replay. Role changes during a request cannot be transactional across Auth and Firestore; future role workflows must revoke sessions appropriately. No role/user-management endpoint is added here.

`REQUIRE_CONTENT_APP_CHECK=true` additionally requires a verified `X-Firebase-AppCheck` token. Enforcement is off until the deployment's client attestation providers are configured; authentication/role checks always apply. CORS does not grant permissions: explicit bearer authorization is required. Maximum raw body is 256 KiB, canonical request JSON is limited to 192 KiB, and accepted transactions/replays are limited to 60 per UID per server minute. Payloads, tokens and draft text are not logged or returned in errors.

Every request has:

```json
{
  "operationId": "CLIENT_GENERATED_STABLE_UUID",
  "wordId": "STABLE_WORD_ID",
  "action": "create",
  "expectedRevision": 0,
  "content": {
    "spelling": "EDITOR_SUPPLIED_SPELLING",
    "pronunciation": "EDITOR_SUPPLIED_TEXT",
    "category": "basic",
    "difficulty": "easy",
    "ordering": 0,
    "senses": []
  }
}
```

This describes an incomplete draft schema, not seed vocabulary. IDs are 1-128 ASCII letters/digits/underscore/hyphen, starting with a letter/digit; slashes are forbidden. Revision must be a nonnegative safe integer below Number.MAX_SAFE_INTEGER. Clients cannot supply publication flags, trusted revision/timestamps, role, UID or arbitrary fields. Unknown fields are rejected at every nested level.

| Action | Content | Preconditions/result |
| --- | --- | --- |
| create | Full content object | expectedRevision=0, word ID absent; creates unpublished, non-retired draft |
| edit | Full replacement content | Existing non-retired word, exact expected revision; preserves publication state; published edits also require reviewed=true and completeness |
| publish | Omitted | Existing non-retired word, exact expected revision, reviewed=true, complete bilingual content |
| unpublish | Omitted | Exact expected revision; retains ID, payload and progress references; removes public visibility |
| retire | Omitted | Exact expected revision; sets retired=true and published=false; no hard delete |
| restore | Omitted | Word must be retired and revision exact; restores as unpublished, requiring a separate reviewed publish |

Even repeated state commands with a new operation ID create a new revision/audit event; reuse the original operation ID for network retries. Success returns `{wordId, revision, contentRevision, isPublished, isRetired, replayed}`. Replays return the original result with replayed=true, even if subsequent edits changed the word. Refetch the editor document when current state is needed.

## Content validation and editorial policy

Categories basic/intermediate/advanced and difficulties easy/medium/advanced remain separate enums. Ordering is 0..2147483647. Spelling is required (max 128 UTF-16 code units); pronunciation is textual (max 256), not an audio URL. Drafts may have empty pronunciation, senses or translations, allowing incomplete editing without publication.

Senses: max 100, stable unique IDs, recognized POS, English/Bengali meanings (max 4000 each), zero-based ordering matching array position. Repeated POS is allowed. Incomplete drafts are editor-form data, not valid published VocabularyWord DTOs; future Admin forms must not force them through the strict published-word decoder. Examples: max 100 per sense, ordered English/Bengali string pairs (max 4000 each). Nested arrays are preserved, not flattened or sorted by POS. NFC normalization preserves bilingual text; malformed UTF-16 and non-text controls are rejected. Unknown enums require an explicit schema migration.

Publication requires pronunciation, at least one sense and one example per sense, and every meaning/example translation nonempty. `reviewed=true` is the authorized editor's explicit attestation; code cannot verify translation accuracy. No automatic translations or invented production vocabulary are introduced. Editing a published word updates its public projection immediately only after explicit review; to prepare an unpublished revision, unpublish first. A separate unpublished working-copy workflow is not implemented.

## Duplicate spelling policy

Display spelling is NFC/trimmed. Uniqueness uses NFKC, collapsed whitespace and lowercase, hashed into private `wordSpellings/{sha256(normalizedSpelling)}`. The registry covers drafts, published and retired words; retirement does not free a spelling. Rename atomically releases the old reservation and obtains the new one. Case/compatibility variants race on the same registry document and cannot both succeed. These normalization rules are server-authoritative and must be reused by future editor/import validation.

## Atomicity, revisions and retry semantics

One Firestore transaction checks expected revision and the uniqueness reservation, then writes the word, spelling registry, manifest/counts, public change record, private audit and private idempotency result. There are no external side effects in the transaction callback. Firestore may retry the callback; transaction contention returns a typed conflict if retries are exhausted. See [Firebase transactions](https://firebase.google.com/docs/firestore/manage-data/transactions).

All successful operations, including private draft edits, obtain the next global revision from the manifest. Thus every word revision is <= the manifest revision as required by the existing Dart downloader. The public feed has exactly one record per revision, with no gaps:

- upsert: `{schemaVersion:1, revision, action:'upsert', wordId, updatedAt}` for a currently published result.
- remove: the same safe shape with action='remove' when a previously published word becomes hidden/retired.
- noop: `{schemaVersion:1, revision, action:'noop', updatedAt}` for draft-only/nonpublic changes. It exposes neither draft IDs nor text. Revision/time metadata reveals editorial activity, not draft payloads.

The feed never embeds vocabulary payloads or actor/operation identifiers. A future delta reader fetches current published words for upserts, treats a no-longer-readable historical upsert as removed, and consumes later tombstones. It must process noop records when advancing its cursor. Incremental student sync is not implemented here.

`contentOperations/{sha256(uid + ':' + operationId)}` stores a canonical normalized request fingerprint, original result, UID and server creation time. Same-ID/same-payload retries do not create a second word revision, audit or feed entry. Reusing an ID for another payload returns operation-id-reused. Ledger records, audit and feed are retained indefinitely in this phase, with no TTL or pruning job. Do not prune records or reset revisions without a separately tested retention/retry protocol. Storage grows with editorial operations; point reads and per-operation work stay bounded.

## Manifest and download compatibility

`contentManifest/current` contains `schemaVersion:1`, `publisherVersion:1`, trusted `currentRevision`, `oldestRetainedRevision:0`, `groupCounts` (all nine category/difficulty keys), `totalPublished`, and `updatedAt`. Only published/non-retired words contribute to counts. Group moves decrement the old group and increment the new group in the same transaction. Zero groups remain explicit; 180 is never a fabricated actual count.

Existing clients continue to read this manifest, fetch published/non-retired words in bounded ID-ordered pages, compare closing revision, validate group counts, and commit their staged snapshot atomically in Drift. No student production code was changed. A changing manifest causes a safe download retry rather than a false completeness claim.

Initialization is lazy only when words, change feed and spelling registry are all empty. Existing unmanaged data, legacy/demo fixture manifests without publisherVersion=1, incompatible schemas or corrupt counters return initialization-required/content-state-invalid. The API does not invent zeros, silently adopt a dataset, or rebuild a registry by scanning a production collection. Review/migration of existing production data is a separate explicitly authorized maintenance task.

The feed is currently unpruned, so oldestRetainedRevision remains zero. Future retention must atomically advance that watermark when deleting only a contiguous prefix; clients below it must reconcile a full verified snapshot. The current client already uses full snapshots, not feed cursors.

## Errors and client behavior

| HTTP | Codes/examples | Required caller behavior |
| --- | --- | --- |
| 400 | invalid-input, invalid-sense-order, duplicate-sense-id, create-revision-must-be-zero | Correct input; never blindly retry |
| 401 | unauthenticated, session-revoked, user-disabled | Refresh/sign in or stop protected work |
| 403 | permission-denied, email-unverified, claims-stale, app-check-required/invalid | Verify/refresh privileges or deny entry |
| 404 | word-not-found | Refetch; no implicit create |
| 409 | word-exists, duplicate-spelling, revision-conflict, operation-id-reused, word-retired, word-not-retired | Refetch/resolve; use a new operation ID only for a new explicit user intent |
| 409 | initialization-required, content-state-invalid | Stop mutations and inspect server state; no automatic reset |
| 409 | transaction-contention | Bounded backoff, same operation ID and payload |
| 413 | payload-too-large | Reduce payload |
| 422 | review-required, publication-incomplete | Complete editorial review/content |
| 429/503 | rate-limited/service-unavailable | Bounded delayed retries with unchanged operation ID/payload |

Firestore rules continue to deny every direct client write, including admin claims. Registry, operations and rate documents are also unreadable to clients. Safe public queries must filter isPublished=true and isRetired=false; drafts require an editor claim. No rules bypass endpoint, Admin CRUD screen, import/user-management API or hard-deletion API is introduced.

## Operations and recovery

Before any separately approved deployment: verify environment, trusted editor claims, Auth domains, App Check policy, existing-data migration needs, backup/export and rules/index configuration. The development project is ielts-vocubs. Do not run the publication API against the old demo seed dataset expecting it to adopt it; use a fresh isolated demo database for publication testing.

Back up words, manifest, change feed, registry, audit and operation results consistently. Audit/feed preserve revision/action history, not old text payloads; recover historical text from a consistent backup/export. Republish reviewed recovered content through fresh API operations at higher revisions. Never roll the counter backwards or restore only the manifest: the existing offline client rejects revision rollback. In a disaster, quiesce writes and reconcile all related state under a trusted maintenance procedure before reopening mutations. A production migration/restore tool is not delivered in this phase.

The single manifest counter is deliberately simple for the initial editorial workload. It serializes writes and may become a contention point at high volume. No imports or high-throughput publication promises are made. ID-token validation follows [Firebase Admin verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens), with revocation checks enabled in this API.

## Verification commands

From `users/`: `npm.cmd --prefix firebase/functions test` and `npm.cmd --prefix firebase/functions run check`. Use the project-local CLI, Java 21 and the isolated firebase.test.json configuration as documented in setup.md. The existing runner now includes publication emulator tests and exports a synthetic public snapshot into `users/.dart_tool/phase3-publication-contract.json`.

Then from `users/packages/local_learning/`:

```
dart run test/publication_contract_probe.dart ../../.dart_tool/phase3-publication-contract.json
dart test
dart analyze
```

The probe passes actual server-produced public words/manifest through the shared Dart decoder and unchanged Drift downloader, checks Bengali text and marks all nine groups complete only after the same validation used by the app. Test fixtures stay in the demo emulator/ignored test output; none are production vocabulary.
