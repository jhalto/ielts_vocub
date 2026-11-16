# Trusted vocabulary JSON import API (Phase 9)

## Phase 11 managed authorization

Enrolled actors must also pass pending/disabled/role/version/fresh-sign-in gates. account-change-pending/session-stale are 401 access outcomes, not reasons to rewrite frozen jobs or IDs. Obtain a new eligible sign-in after a role/status workflow; completed receipts and local intent remain intact. Missing membership preserves legacy behavior. Updated privileged-read rules and protected APIs must accompany administration rollout; see user_admin_api.md. No deployment occurred.

## Phase 10 Admin client

The Admin Panel now implements this API under JSON imports. The Phase 9 backend boundary below remains its original contract; Admin screens were added in Phase 10 without changing that backend. See phase10_handoff.md for UI behavior, exact checks and manual acceptance. Files supply schema-1 items; the UI clears uploaded reviewed flags, requires explicit published-edit confirmation, and invalidates previews/reviews after edits. New jobs always use the existing draft-only create behavior.

The client keeps a frozen creation request in account/environment-scoped browser sessionStorage before sending it, retaining identical job/item IDs and JSON across bounded retries. Successful confirmation drops cached draft text and retains only job ID/owner/schema for lookup. A pending process response is reconciled through complete paginated status before selecting up to five more items. The UI renders receipts 25/page. A completed HTTP call is never presented as success for every item. Terminal conflicts stay in the old job; users explicitly create a new plan with fresh revision preconditions. Browser recovery is best effort, not a backup: keep job IDs outside the tab if needed. No tokens are stored in these checkpoints.

The existing backend still supplies all mutations. The Admin client performs no direct job/vocabulary Firestore writes. Current approved target reads reuse the existing vocabulary repository. No new backend endpoint, rule, index or dependency is added by Phase 10.

Implementation: users/firebase/functions/src/imports.ts and import_validation.ts. New HTTPS function importApi, region us-central1, timeout 60 seconds, maxInstances 5. Not deployed. No browser Admin SDK, file-storage upload, background worker or Admin import screen is included.

## Authentication and bounds

POST application/json to `https://us-central1-PROJECT_ID.cloudfunctions.net/importApi`. Isolated test endpoint: `http://127.0.0.1:15001/demo-vocabulary/us-central1/importApi`. Supply `Authorization: Bearer FIREBASE_ID_TOKEN`. The server verifies revocation, disabled state, verified email, current Auth role (content_manager/super_admin), and matching token claims on every request. Firestore profile role fields do not authorize imports. Jobs are UID-namespaced; even another super admin cannot process/read a job through this API on behalf of its owner. Role removal/revocation prevents subsequent requests; previously committed items remain committed.

The existing REQUIRE_CONTENT_APP_CHECK=true setting also enforces a verified X-Firebase-AppCheck token here. Do not enable enforcement until a supported client attestation strategy is configured. CORS grants no authorization. Responses use Cache-Control: no-store. Errors/audits contain codes and safe IDs/metadata, not uploaded text, passwords or tokens.

Limits: 512 KiB raw JSON request including its action envelope, 1-50 rows per immutable job, the publication validator's 192 KiB mutation limit per row, 5 requested items per process call, 1-25 status rows/page, and 60 import requests per authenticated editor per server minute (including previews, reads and retries). Applied mutations also share the existing content service's 60 accepted transactions/replays per editor/minute. Oversized input is rejected before privileged work. Multipart, CSV and non-JSON media types are unsupported. This is an API receiving a JSON document, not a filename-based trust check.

## File format

The JSON file/document is the import property of preview/create requests:

```json
{
  "schemaVersion": 1,
  "items": [
    {
      "itemId": "row-001",
      "decision": "create",
      "wordId": "EDITOR_SELECTED_STABLE_ID",
      "expectedRevision": 0,
      "content": {
        "spelling": "EDITOR_SUPPLIED_SPELLING",
        "pronunciation": "",
        "category": "basic",
        "difficulty": "easy",
        "ordering": 0,
        "senses": []
      }
    },
    { "itemId": "row-002", "decision": "skip" }
  ]
}
```

This is a schema illustration of an incomplete draft, not production vocabulary. IDs (job/item/word/sense) use the existing 1-128 ASCII letters/digits/underscore/hyphen policy, starting with a letter/digit. Job and item IDs must be generated once and retained by the caller for retries. Every row requires an explicit decision:

| Decision | Required fields and behavior |
| --- | --- |
| skip | Only itemId and decision; do not retain untrusted content in a skip row. Immediately recorded skipped when the job is created. |
| create | wordId, expectedRevision=0, full content; no reviewed field. Target must be absent. Always creates an unpublished, non-retired draft, even if complete. |
| update | Existing stable wordId, positive expectedRevision, full replacement content; optional boolean reviewed (defaults false). Target must be non-retired and revision must still match when applied. |

All content/sense/example fields and limits are exactly those in publication_api.md. Reuse stable sense IDs when editing; preserve zero-based sense ordering, repeated POS and ordered English/Bengali example pairs. Unknown enums, extra fields, server publication/timestamp/revision/UID/role fields, malformed Unicode and invalid nested shapes are rejected. NFC normalizes displayed text; NFKC + collapsed whitespace + lowercase defines spelling uniqueness, matching the existing wordSpellings registry. No new normalization policy or packages are introduced.

Incomplete drafts are allowed and have publishable=false in preview. Every colliding item ID, target word ID or normalized spelling in the file is reported; duplicates are never silently merged. Skip rows participate only in item-ID uniqueness. Database spelling conflicts report duplicateWordId so an editor can deliberately select a target/decision; the server never changes create to update. Swaps or dependent renames against occupied spellings must be handled through separate reviewed editorial operations, not ordered assumptions within a batch.

An update preserves the current publication state. Editing a published word requires reviewed=true and complete bilingual content under the existing publication policy; it immediately updates that published projection. To prepare an unpublished edit, explicitly unpublish through contentApi first and obtain the new revision. New imports are never auto-published. Imports cannot retire, restore, publish, unpublish or hard-delete words. A restored word remains draft unless separately reviewed and published.

## Request and response contracts

Unknown request keys/actions are rejected. No action accepts a UID, role, arbitrary operation ID or server status.

### Preview

`{action:"preview", import:FILE}` returns HTTP 200 with `{schemaVersion:1, valid, items:[...]}`. Each item contains zero-based index, itemId/decision when parsed, errors (safe code strings), normalizedSpelling, normalized content when valid, publishable, existing target metadata (wordId/revision/publication/retirement), and duplicateWordId where applicable. Invalid file containers/schema/limits return HTTP 400/413; valid containers with invalid rows use valid=false and per-row errors. Invalid rows can have null content/metadata.

Preview reads at most two direct documents per structurally valid row (word and spelling registry). It writes no job, vocabulary, feed or audit; only the editor's request-quota document is updated. Database checks are advisory point-in-time reads, not locks or a reservation. Every mutation rechecks authoritative constraints inside the publication transaction.

### Create immutable job

`{action:"create", jobId:"STABLE_JOB_ID", import:FILE}` validates all rows/current database state, then atomically creates the job and every frozen item. If any row fails, HTTP 422 returns `{schemaVersion:1, code:"import-invalid", valid:false, items:[...]}` and no job/items/publication changes are created. Correct input may reuse an ID that was never successfully reserved.

Success: `{schemaVersion:1, jobId, status, counts:{total,pending,applied,skipped,failed}, replayed:false}`. Normalized plan, decisions, IDs, review choice, revisions and example order are fingerprinted. Same owner/job ID with the same normalized plan returns the existing summary and replayed=true, including after processing changed the database. A different valid plan under a reserved ID returns HTTP 409 import-job-id-reused. Created jobs/items cannot be edited; correction requires a new job/operation identity.

### Process bounded items

`{action:"process", jobId:"STABLE_JOB_ID", itemIds:["row-001"]}` requests 1-5 distinct known IDs. Unknown IDs reject the request before any selected item runs. The server processes the requested order sequentially. A terminal failure does not prevent other selected items from running; a transient pending failure stops this call to avoid a busy retry loop. Unattempted IDs are not included in the returned items array.

HTTP 200 returns the current job summary plus processed item receipts. HTTP 200 does not mean every item succeeded: inspect state and lastError. Each receipt has itemId, original index, decision, state, wordId (null for skip), attempts, result (null until applied/skip), lastError (null or `{code,retryable}`). Success result is the existing publication result `{wordId,revision,contentRevision,isPublished,isRetired,replayed}` retained as committed. Polling/replaying an applied item returns that receipt; it does not recompute publication or add a new revision/audit.

Each successful item uses applyContentMutation with a trusted server-only transaction participant: read the frozen item/job before writes, then commit its receipt, counters and import audit in the SAME transaction as word, spelling uniqueness, manifest/counts, public change/noop, publication audit and operation ledger. A transaction retry or lost HTTP reply cannot leave a word applied without its import receipt or apply an item twice. Clients cannot supply this participant.

Each item is atomic; a whole process call/job is deliberately not an all-or-nothing bulk mutation. Earlier successes survive a later failure or HTTP timeout. Resume by fetching status and resending the same job/item IDs. Concurrent workers/jobs serialize on the existing word/manifest/registry and job/item preconditions. Never assume a timeout means nothing committed.

### Read paginated status

`{action:"get", jobId:"STABLE_JOB_ID", limit:25, afterItemId:"LAST_RETURNED_ID"}` (limit/cursor optional). Returns summary, bounded receipt items sorted by item document ID, and nextAfterItemId (null at end). Input index is included to restore original file order in a future UI. No raw imported content or token is returned in status.

Status is a live view, not a revision-frozen cross-page snapshot; items move only from pending to a terminal state. Concurrent workers can advance counts/items between reads. Refetch after processing to obtain final counts. This endpoint does not list all users' jobs or expose privileged Auth data.

## State, failures and retry policy

Item states: pending, applied, skipped, failed. Job status: ready while pending>0, completed when all terminal without failures, completed_with_errors when all terminal with at least one failure. Counts always sum to total. Skip/job creation, each successful item and each terminal failure have idempotent audit entries; publication audits remain separate word events.

Revision conflicts, duplicate spelling/target, retired/missing words, review/completeness violations and other semantic failures become durable failed items. Retrying those IDs returns the recorded failure without changing content. Fetch current content, explicitly review the change and create a new job/item payload with fresh expectedRevision. Do not silently rebase or reuse an old operation ID with modified content.

Quota, transaction contention and service failures leave an item pending with durable lastError.retryable=true and attempts metadata. Known failed attempts increment attempts; an unobserved process crash before any commit cannot be counted. Retry the same IDs later with bounded exponential backoff/jitter; respect minute quotas. There is no automatic server loop, queue worker, client retry scheduler or durable retry-time timer in this phase. HTTP-level authentication/quota/service failures can happen before an item is attempted. Ordinary malformed JSON can be rejected by the Functions HTTP parser before this handler runs.

Relevant response codes: 400 invalid-input/import-schema-unsupported/import-item-limit/import-batch-limit/duplicate-item-id; 401 unauthenticated/session-revoked/user-disabled; 403 permission-denied/email-unverified/claims-stale/App Check errors; 404 import-job-not-found/import-item-not-found; 409 import-job-id-reused/transaction-contention; 413 payload-too-large; 415 json-required; 422 import-invalid; 429 rate-limited; 503 service-unavailable. Processing outcomes additionally carry publication codes such as revision-conflict, duplicate-spelling and review-required inside receipts.

## Storage, security and retention

`importJobs/{sha256(canonical([uid,jobId]))}` stores schema, owner UID, job ID, canonical plan fingerprint, status/counts and server timestamps. `items/{itemId}` stores immutable index/decision/mutation/mutationHash, state, known attempts, result/error and timestamps. Operation IDs are `import_` plus SHA-256 of canonical [uid,jobId,itemId]; they are immutable and namespace-separated from caller-chosen word operations.

Existing direct client writes stay denied for jobs, nested items, words, receipts and progress. Nested item reads stay denied; only the authorized owner API exposes receipts. Existing editor reads of parent importJobs metadata remain unchanged (parents contain no uploaded content). Audit reads remain super-admin only. importRateLimits is server-only under catch-all denial. No new composite index, Storage rule, Firebase registration or dependency is needed.

There is no TTL/cleanup/cancellation/job deletion in Phase 9. Jobs/items, publication retry receipts and safe audit history are retained indefinitely, preserving retry safety at a storage cost. Do not prune receipts or reuse job IDs until a separately reviewed retention protocol exists. No existing production data adoption/reset or student progress migration occurs. Provision budgets/monitoring and validate Node 22 deployment/runtime in a separately authorized release task.
