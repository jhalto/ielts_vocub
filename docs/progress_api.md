# Trusted progress API (Phase 6)

## Phase 11 managed account access

The endpoint now also rejects enrolled accounts while pending/disabled, with stale adminRevision/role claims, or with auth_time before their post-revocation sign-in barrier. account-change-pending/session-stale are 401 outcomes; preserve the existing outbox IDs/payloads and obtain a fresh eligible sign-in after management completes. Progress wire bodies, receipts, revisions and publication rules are unchanged. Missing membership retains legacy behavior. See user_admin_api.md for coordinated rule/API rollout, revocation and explicit limits. No deployment or progress migration was performed.

Phase 7 follow-up: the native Student client now implements this contract; see phase7_handoff.md and sync_protocol.md for durable local migration, safe acknowledgements and explicit conflict resolution. Server wire behavior is unchanged. References below to the future/unconnected client describe the original Phase 6 boundary; this follow-up supersedes those delivery-status notes.

Implementation: users/firebase/functions/src/progress.ts and progress_validation.ts. This is an authenticated HTTPS JSON service, not a Firebase callable envelope. The Student sync client is not connected.

- Live URL after a separately authorized deployment: POST https://us-central1-PROJECT_ID.cloudfunctions.net/progressApi.
- Isolated emulator URL: POST http://localhost:15001/demo-vocabulary/us-central1/progressApi.
- Send Content-Type: application/json and Authorization: Bearer FIREBASE_ID_TOKEN. Windows can use the same HTTPS transport pattern as accountApi; no native cloud_functions dependency is required by this protocol.

## Identity and policy

UID is derived only from verifyIdToken(token, true). The server fetches the current Auth user and requires an enabled account and verified email both in the current account and token. Anonymous/guest accounts cannot use this endpoint. These checks apply to uploads, retrieval and replay, regardless of role. No editable profile field grants access. A stale unverified token needs refresh after email verification.

REQUIRE_PROGRESS_APP_CHECK=true additionally verifies X-Firebase-AppCheck. Enforcement is opt-in until supported client attestation providers and header forwarding are configured, including the Windows strategy. Authentication and UID isolation always apply. No App Check provider was configured or real attestation acceptance tested here.

Authorization is checked at the request boundary. Auth changes cannot be atomic with Firestore commits; a bounded already-authorized request may finish while revocation happens. The next request, including a replay, checks revocation/disabled status again. An in-flight request remains pinned to its verified UID, never an incoming client account. The existing owner-only Firestore progress read permission remains; this endpoint's fresh Auth checks do not change the SDK/rules' token-lifetime behavior. All direct client progress writes stay denied, including editor/admin claims.

## Upload

```json
{
  "action": "upload",
  "operations": [
    {
      "operationId": "IMMUTABLE_OPERATION_ID",
      "deviceId": "INSTALLATION_ID",
      "wordId": "STABLE_WORD_ID",
      "desiredStatus": "didnt_know",
      "baseRevision": 0,
      "sequence": 1
    }
  ]
}
```

All fields shown on an operation are required. Optional supersedesOperationId links a deliberate rebase to a retained revision-conflict receipt for the same UID/word. Self-links, missing receipts, receipts for another word and non-conflict receipts cannot authorize a linked rebase. An unlinked ordinary operation with a fresh ID and exact revision is also valid; the server does not infer human intent from a link.

Bounds: 1-25 operations; operation IDs distinct within the batch; raw body at most 64 KiB and canonical JSON at most 32 KiB. IDs use 1-128 ASCII letters/digits/underscore/hyphen, beginning with a letter/digit. baseRevision is an integer from zero through Number.MAX_SAFE_INTEGER-1; sequence is a positive integer below Number.MAX_SAFE_INTEGER. Status is exactly already_know, learned or didnt_know. Unmarked means absent progress, not a fourth status. Unknown fields, UID/role, client timestamps and client-assigned server revisions are rejected. The whole request is validated before any progress operation starts.

The existing Drift outbox projects directly to this envelope:

| Drift field | Wire field |
| --- | --- |
| operation_id | operationId |
| device_id | deviceId |
| word_id | wordId |
| desired_status | desiredStatus |
| base_revision | baseRevision |
| sequence | sequence |

The future client must check the row's UID equals the current authenticated UID before transport; UID is not sent as authority. created_at/retry_count/state/last_error are local metadata and are omitted. Local tables/IDs were not changed in Phase 6. Persisting optional rebase linkage and safely acknowledging/rebasing local rows belong to the separately approved client implementation.

## Ordering, atomicity and conflicts

Each UID has a trusted monotonically increasing progress counter. Each word records the counter value from its last accepted update. baseRevision must equal that word's current revision, or zero when absent. Word revisions are not vocabulary publication revisions, and they need not be consecutive for an individual word. Example: word A at revision 1, word B at revision 2, then A at revision 3.

One Firestore transaction reads the UID-scoped receipt, progress, counter and current vocabulary publication. An accepted update writes progress, increments the UID counter and creates its receipt atomically. Vocabulary must exist, be published and non-retired at serialization time. The publication backend reads/writes the same word, so an upload racing retirement either commits before retirement or returns word-unavailable afterward. No draft text or publication metadata is returned by this service.

The first successful matching-revision transaction commits. Competing same-word updates conflict instead of silently overwriting. The winner depends on commit order, not a fixed device priority or client wall clock. Different-word updates can both succeed; the UID counter serializes their revisions. sequence/deviceId are validated immutable metadata, not trusted ordering clocks or global uniqueness constraints. This preserves compatibility with Phase 2's sequence reset on explicit logout. Old operations with stale base revisions cannot overwrite newer progress.

No automatic server rebase or last-write-wins merge occurs. On conflict the future client must preserve its pending local intent, obtain current authoritative progress and deliberately choose whether to rebase the latest still-pending intent under a new operation ID/base revision. Optional supersedesOperationId records that link. Bound conflict/restart retries and surface unresolved contention. Continued edits can keep causing conflicts; convergence is conditional on edits stopping and the client performing its selected reconciliation policy.

HTTP 200 returns a bounded ordered results array, including terminal business failures:

```json
{
  "schemaVersion": 1,
  "results": [
    {
      "operationId": "IMMUTABLE_OPERATION_ID",
      "wordId": "STABLE_WORD_ID",
      "code": "applied",
      "progress": {
        "wordId": "STABLE_WORD_ID",
        "status": "didnt_know",
        "revision": 1,
        "lastOperationId": "IMMUTABLE_OPERATION_ID"
      },
      "replayed": false
    }
  ]
}
```

| Per-operation code | Meaning / future client behavior |
| --- | --- |
| applied | Authoritative committed status/revision. Acknowledge only the matching UID/operation; do not erase or overwrite a newer local intent. |
| revision-conflict | No progress change; progress contains the authoritative state at this attempt, or null. Preserve local intent, reconcile and deliberately rebase under a new ID if appropriate. |
| word-unavailable | Missing, draft, unpublished, retired or invalid publication share one response; no content leakage. Preserve history, exclude unavailable content from the active queue, and surface a rejected pending operation rather than claiming backup. |
| invalid-rebase | Link is not an existing same-word conflict receipt. Correct the workflow with a new operation ID. |
| operation-id-reused | Same UID/ID with different validated payload. Do not retry a modified payload under the old ID. progress is null. |

Terminal results other than operation-id-reused are also receipted. Republishing a word does not cause an old word-unavailable operation to start applying on retry. A deliberate new attempt requires a new operation ID. Similarly, replaying a conflict returns its original conflict snapshot even after progress changes; retrieve current state before a new rebase.

Batches use serial, independent per-operation transactions, not all-or-nothing batch commits. Mixed applied/conflict results are normal. A timeout, network error or server failure can hide earlier committed operations. Retry the entire batch with the same operation IDs and exact payloads; accepted operations replay without incrementing revisions or changing timestamps. Do not interpret a failed HTTP request as proof that nothing saved. Firestore may rerun transaction callbacks; they contain no external side effects.

## Receipt retention and stale operations

users/{uid}/syncOps/{sha256(operationId)} binds a canonical validated operation fingerprint to the original result. UID scoping is supplied by its parent path. Exact replays do not recheck current publication or change progress; they return the original result after current request authorization. Reuse across another UID is independent and never accesses the original UID's receipt.

Receipt metadata is bounded in size, but count grows with operations. Receipts, including terminal conflicts/unavailable results, are retained indefinitely in this phase. No TTL, receipt pruning, silent eviction, progress deletion or revision reset is implemented. This supports retries after long offline periods without guessing age from an untrusted client clock. A new operation's age cannot be inferred from its random ID; safety is determined by revision/publication checks. Production retention/deletion requires a separately tested expiry/watermark protocol. Never remove receipts or roll back just the counter as routine cleanup.

No method clears progress to unmarked or deletes an account. Existing unmanaged remote progress without a compatible counter is rejected with progress-initialization-required instead of adopting it, inventing revisions or overwriting it. Corrupt state fails closed. Review/migration and disaster recovery are trusted operator work outside this phase.

## Paginated retrieval

```json
{"action":"list","limit":50}
```

limit defaults to 50, range 1-100. Response: {schemaVersion:1, revision, progress:[...], nextCursor:null-or-string}. Rows contain wordId/status/revision/lastOperationId plus server-created createdAt/updatedAt ISO-8601 UTC timestamps. An empty new account returns revision=0 and an empty array. History for unavailable words remains in the owner's results; no word payloads are fetched. Only bounded ID-ordered progress queries are performed, with one lookahead; no per-word vocabulary lookups or collection scans. The standard document-ID index suffices; no new composite index is needed.

To continue send {action:'list', limit:50, cursor:PREVIOUS_NEXT_CURSOR}. Cursors carry version, owner hash, snapshot revision and last word ID in base64url JSON. They are opaque navigation values, not encrypted/signed authorization tokens. All reads derive their collection from the verified UID; copied cross-UID cursors are rejected. Do not invent or edit cursors.

Each page transaction reads the UID counter and its bounded query consistently. Any accepted update between pages changes the counter and returns HTTP 409 progress-snapshot-changed, with no partial page. Discard staged remote pages and restart from page one. Only publish a complete staged retrieval to local state after the final page, preserving newer pending local intent. No progress deletion exists in this phase; adding deletion must participate in this versioning protocol. A server restore that improperly reuses revisions cannot be detected by a simple counter and is unsupported.

## HTTP failures, rate limits and operations

| HTTP | Codes / required action |
| --- | --- |
| 400 | invalid-input, invalid-cursor, duplicate-operation-id: fix request; do not blindly retry. |
| 401 | unauthenticated, session-revoked, user-disabled: stop protected work; token refresh/sign-in only where appropriate. |
| 403 | email-unverified, app-check-required, app-check-invalid: satisfy policy; never bypass it. |
| 405 / 415 / 413 | Wrong method/media type/body size; correct transport. |
| 409 | progress-snapshot-changed: restart staged retrieval. |
| 429 | rate-limited: Retry-After: 60, back off with jitter; retain exact operation IDs. |
| 503 | transaction-contention, service-unavailable: bounded backoff and retry immutable operations. progress-state-invalid, progress-initialization-required or revision-exhausted require operator inspection; do not reset data to retry. |

Per UID, a separate transaction permits 200 units per server minute. Each uploaded operation costs one unit, retrieval costs one. Replays and terminal results consume quota; repeated failures cannot roll back the limiter. Whole validated batches reserve their quota before processing. This is a fixed-window operational guard, not an account-wide/global abuse-prevention guarantee. Configure App Check, budget monitoring and deployment limits separately. The endpoint uses no-store responses, maximum 60-second execution and maxInstances=5. Errors do not expose raw SDK exceptions, tokens, private requests or drafts.

## Verification and setup

From users/: npm.cmd --prefix firebase/functions test and npm.cmd --prefix firebase/functions run check. The existing project-local CLI runner now includes progress.emulator.cjs. Use Java 21, firebase.test.json and demo-vocabulary as in setup.md; the runner clears demo data and must not share a manual acceptance dataset. The new test words are synthetic and published only inside emulators.

Nothing has been deployed. Before separately authorized live use review the development project, existing remote data, verified-email policy, HTTPS region/URL, rules, quotas, backups and attestation strategy. Back up progress, UID counters and receipts together; restoring only one can invalidate retry and revision safety. No Firebase provider/registration change is required by this API. Actual Node 22 runtime and real App Check/provider acceptance remain release checks. Existing client behavior remains local-only; Phase 6 does not upload any stored Student outbox or mark it cloud-backed.
