# Trusted user administration API (Phase 11)

Implementation: users/firebase/functions/src/user_admin.ts, user_admin_validation.ts, managed_access.ts and user_admin_cli.ts. New HTTPS function userAdminApi, region us-central1, timeout 60 seconds, maxInstances 5. Not deployed. No Admin user-management screen, deletion, export or private learning-summary scan is included.

## Authorization and initial adoption

POST application/json to `https://us-central1-PROJECT_ID.cloudfunctions.net/userAdminApi`; isolated tests use `http://127.0.0.1:15001/demo-vocabulary/us-central1/userAdminApi`. Supply a Firebase ID token in Authorization: Bearer. The server verifies signature/revocation/disabled state, current verified Auth identity, matching super_admin token/current claims and a ready server-owned managed membership. Content managers, students, unverified/disabled users, stale/revoked sessions and unmanaged super-admin claims cannot use this API. Request bodies never choose the acting UID. A Firestore profile role is never authority.

Initialization is a separate IAM/Application Default Credentials CLI action, never an HTTP self-bootstrap. It requires the existing completed serverControl/adminBootstrap reservation and the same enabled, email-verified super admin. It scans Auth only during this operator step (up to 100 pages of 1000) and refuses any other existing super-admin claim, enabled or disabled. It refuses existing incompatible managed state or a pre-existing nonzero adminRevision claim. Existing multiple-super-admin projects need a separately reviewed migration, not deletion of users or a fabricated count. A maintenance window must exclude concurrent bootstrap, Auth administration and registry writers.

Initialization atomically creates serverControl/userAdministration and the bootstrap member at revision 0 with activeSuperAdmins=1. It performs no Auth write, so ordinary bootstrap sessions remain usable. Repeating initialization for the same initialized UID is idempotent, not a repair/regrant action. The old bootstrap CLI is sealed after this step; a completed bootstrap also no longer regrants a role that was subsequently changed.

REQUIRE_USER_ADMIN_APP_CHECK=true additionally verifies X-Firebase-AppCheck. This is off until valid caller attestation/token forwarding is configured. Authentication/current role checks always apply. CORS is not authorization. All responses are no-store. Raw requests are capped at 16 KiB. Authorized requests, reads, malformed action bodies and retries share 60 requests per actor per server minute; rejected unauthenticated/non-super requests create no quota documents. Reasons use NFC, 5-500 trimmed text characters/code units within the validator bounds, excluding invalid/control text.

## Directory contract

Exact lookup: `{action:"get",uid:"TARGET_UID"}` or `{action:"get",email:"exact@example.test"}`, exactly one identity selector. UIDs are nonempty, at most 128 code units and must fit the repository's Firestore document layout (no slash, control characters, dot/dot-dot). Email lookup uses Firebase Auth's exact-address lookup, not prefix/substrings. Unknown users return 404 user-not-found. No arbitrary name/email full-text search is promised.

Success is `{schemaVersion:1,user:{uid,name,email,providers,emailVerified,disabled,role,createdAt,lastSignInAt,administrationRevision,administrationPending,authState}}`.

- Auth supplies identity/provider/verification/account state. providers contains provider IDs only, not external provider UIDs or credentials. Missing role means student; unrecognized existing roles display unsupported and cannot be overwritten through this API.
- administrationRevision is 0 for an unmanaged target; authState is a SHA-256 fingerprint of UID/account incarnation, claims, disabled and verified state. It is a precondition, not a credential or ordering clock. Name/photo changes do not invalidate a role precondition. No raw custom claims, password hashes/salts, tokens, phone/MFA details, refresh credentials or personal learning records are returned.
- Pending targets show observed Auth state and administrationPending=true; changes are not represented as a completed cross-service update. Fetch again after completion before issuing a new mutation.

List: `{action:"list",limit:25,filters:{role:"student",disabled:false,verified:true,provider:"password"},cursor:"CONTINUATION"}`. All fields except action are optional. limit is 1-100; filters are exact role (three approved values), disabled/verified booleans and provider ID. Unsupported filter/search fields fail validation.

Each request reads ONE native Firebase Auth page of at most limit users and at most one managed membership document per listed UID. Filters apply to that bounded native page. The API does not keep scanning to fill a filtered page. An empty users array can still have a non-null nextCursor; callers must follow it. Return `{schemaVersion:1,users:[...],scanned,nextCursor}` with null at end. No fabricated total, stable page number or point-in-time export is supplied. Pagination is live under account changes.

Cursors encode schema, verified actor UID, limit, filters and the native opaque Auth continuation. Reusing with another actor/filter/limit is rejected. They are not signed authorization credentials; every request independently rechecks super-admin access and the native SDK validates its token. No client cursor can select an untrusted acting identity. No new Firestore index or searchable profile mirror is required.

## Mutations and idempotency

After fetching current details, send one explicit action:

```json
{
  "action": "setRole",
  "operationId": "STABLE_CLIENT_OPERATION_ID",
  "targetUid": "TARGET_UID",
  "expectedRevision": 0,
  "expectedState": "64_LOWERCASE_HEX_CHARACTERS_FROM_AUTHSTATE",
  "confirmed": true,
  "reason": "Operator supplied access-change reason",
  "role": "content_manager"
}
```

This is a contract illustration, not a real operation. setRole accepts only student/content_manager/super_admin; assigning student revokes the administrative role. setDisabled uses the same common fields with `action:"setDisabled",disabled:true|false` and no role. Other Auth/profile/claims/password/delete fields are rejected. Operation IDs use the existing 1-128 ASCII ID convention. Confirmation is the authorized caller's explicit intent; backend code cannot verify a human actually saw a UI dialog.

Both the administration revision and observed Auth-state hash must match. A new operation cannot silently overwrite changed claims, eligibility or account status. Unrelated custom claims are preserved; projected claims must still fit Firebase's 1000-byte limit. Grants require an enabled, verified target. Unsupported roles and unknown managed-member schemas fail closed. No-op state requests return 409 already-in-state without revoking sessions. Self-directed role/status changes are refused (self-change-not-allowed), including self-disable/demotion; use another managed super admin. This is stricter than merely refusing the last self-demotion and avoids a request losing its own recovery authority midway.

Operation key is SHA-256 of canonical [verified actor UID,operationId]. The normalized original payload, reason, preconditions, security-only before/after snapshots and planned revision are immutable. Same actor/ID/same payload finds the original operation; changed payload returns operation-id-reused. A completed replay returns the old receipt without applying it again, even if later operations changed the account. Fetch current details when current state is needed. Different actors have separate operation namespaces.

Operation view:

`{schemaVersion:1,operationKey,operationId,actorUid,targetUid,action,state,phase,revision,before:{role,disabled,emailVerified},after:{role,disabled,emailVerified},workerActive,lastError,result}`.

States: pending, complete, recovery_required. A completed result contains uid, administrationRevision, authState, role/disabled/verification and reauthenticateAfter (server epoch seconds). HTTP 200 can be a pending/busy/recovery-required view; it does NOT mean completion. lastError is null or a safe `{code,retryable}`. Phase labels reserved/claims/account-status/revocation/confirmation/complete describe the current attempt and may restart on retry; they are not a monotonic percentage.

Read status: `{action:"operation",operationKey:"64_HEX_KEY"}`. Resume: `{action:"resume",operationKey:"64_HEX_KEY"}`. Either requires a current managed super admin; a different current super admin can resume the SAME frozen intent. Original actor/reason remain immutable and the actual resumer is audited. Retrying the original mutation also finds its operation key after a lost reservation/creation reply. Concurrent resume of an active worker returns its status without starting another Auth writer. Do not invent a new ID just because an HTTP request timed out.

## Cross-service workflow and last-admin protection

1. A Firestore transaction validates current managed actor/target, revision and registry. Only one global administration operation may be pending. It quarantines the target with a new managed revision/pending key, reserves the immutable operation and emits a safe reservation audit.
2. Any currently active target super admin is removed from activeSuperAdmins WHILE pending. Reservation cannot reduce the count below one. A promotion is not counted until its Auth state is confirmed and the final transaction succeeds. Combined with serialized operations, transactional actor checks and refusal of self-changes, competing demotions/disables cannot each remove the other remaining managed admin.
3. One durable worker owner is claimed transactionally. It verifies Auth matches the frozen before, after or known claims-first intermediate state. It sets role/adminRevision while preserving other claims, applies disabled state as needed, revokes refresh tokens, then reads Auth back. Known completed side effects can be skipped/repeated safely within the same frozen operation; observed unexpected security changes stop as drift rather than being overwritten.
4. Only after exact Auth confirmation does a transaction release target quarantine, set its minAuthTime barrier, update the active count, clear the global pending key, store the result and emit the completion audit. Word/progress data is never changed by this workflow.

Auth and Firestore do NOT share an atomic transaction. The pending gate deliberately blocks protected target access during an intermediate state, including a freshly minted privileged JWT. After completion, managed access requires matching role/adminRevision, not disabled/pending, and auth_time >= minAuthTime. minAuthTime is strictly after the Auth revoke second, closing the second-resolution pre-revocation token window. Targets must sign in again after reauthenticateAfter, potentially waiting for the next second; force-refresh of an older session is insufficient. Newly granted role claims do not grant Firestore access before finalization.

The managed gate is added to account/content/import/progress HTTPS APIs and owner/editor/super-admin Firestore rules. Client-editable profile roles remain irrelevant. Public published content/manifest/feed remain public, including for disabled users browsing as guests; offline caches cannot be remotely erased. Already-authorized in-flight requests may finish; this does not retroactively cancel committed work.

Missing managed membership records preserve existing legacy behavior in older endpoints/rules. Only the initialized bootstrap member and targets of this workflow are enrolled. Unmanaged super-admin claims cannot use userAdminApi or be silently adopted as counted members. Existing content managers continue to work until explicitly managed, then must meet the new version/sign-in barrier. This compatibility boundary is not a guarantee for arbitrary IAM/Console or client-SDK account changes outside the workflow.

## Failure and trusted recovery

- Known settled failures before/after confirmed Auth calls leave the operation pending with retryable=true and worker released. Resume the SAME key with bounded backoff; no changed payload or automatic conflict rebase is permitted.
- An uncertain Auth write/revocation response retains the durable worker and marks recovery_required. A hard process crash may leave pending with workerActive=true. Unknown Auth/security drift also remains quarantined. New administration mutations stay blocked; at least the surviving actor remains available under the managed protocol.
- Worker locks have NO automatic expiry/takeover. Firestore fencing cannot cancel a delayed Firebase Auth RPC. Blind lease expiry can let an old writer overwrite a later account change; the implementation intentionally refuses that shortcut.
- IAM-only unlock requires at least 120 seconds since worker start AND explicit operator confirmation that the old invocation has terminated and all uncertain Auth RPCs have settled. The elapsed time is only a guard, NEVER proof of settlement. Inspect runtime/provider outcomes first. The helper verifies compatible Auth state, the same worker and pending registry, clears only that worker and audits the unlock. It does not change the plan, undo Auth changes or declare completion. An authorized API resume still performs confirmation/finalization afterward.

If Auth state is neither before/after/known intermediate, no helper guesses which change to keep. Operator diagnosis/reconciliation is required; do not delete locks, reset revisions/counts or edit frozen operations. No public unlock/force/cancel/rollback endpoint exists. There is no background dispatcher in this phase. If the original actor lost its operation key, trusted operators can find the global pending key or safe reservation audit, then another current managed super admin can inspect/resume it.

Production constraints: last-admin guarantees cover ONLY initialized records and operations through this protocol. Quiesce other Auth/registry writers for initialization and management. Console/IAM role/status/verification changes, Auth client self-deletion, service-account misuse or independent backup restores can invalidate counts/availability; those paths are not controlled by this API. Do not represent this as an absolute guarantee against an external privileged actor. There is no account deletion implementation or automatic drift repair here.

## Schema, retention, errors and rollout

- serverControl/userAdministration: schema/state, immutable bootstrapUid, activeSuperAdmins and pendingOperation.
- managedAccounts/{uid}: schema/UID, role/disabled/verification, monotonic revision, minAuthTime and pendingOperation. Never remove a member merely to regain legacy access.
- userAdminOperations/{hash}: immutable actor/input/fingerprint/security snapshots/planned revision; mutable phase/state/worker/start time/lastError/result/server times. Full custom claims are retained only in this server-only recovery record, not directory/errors/audits.
- userAdminRateLimits/{uid}: server-minute quota. All these records are denied to direct client reads AND writes by catch-all rules. Safe user_admin_initialize/reserved/completed/recovery_unlock audits are readable only by current eligible super admins.

No new index/dependency/registration is needed. No automatic TTL/pruning is supplied: managed gates, frozen operations and audits must survive retry/recovery; storage and reason retention need a later reviewed policy. No Firestore/Drift progress migration or unrelated private-data scan occurs.

HTTP codes include 400 invalid-input/invalid-cursor, 401 unauthenticated/session-revoked/user-disabled/account-change-pending/session-stale, 403 permission-denied/email-unverified/claims-stale/administrator-unavailable/App Check errors, 404 user-not-found/operation-not-found, 409 initialization/registry/drift/precondition/last-super-admin/self-change/operation-ID/busy/contention errors, 413 payload-too-large, 415 json-required, 429 rate-limited and 503 service-unavailable. Processing failures may instead be returned inside the operation view; inspect state/lastError, not only HTTP status.

Rollout requires the compatible existing HTTP gates AND updated Firestore rules before registry initialization or user changes. Deploying only userAdminApi leaves stale-token read paths unprotected. Deployment/initialization were NOT performed against the development/live project. See setup.md and phase11_handoff.md for commands, actual tests and remaining manual acceptance.

## Phase 12 Admin client behavior

The Admin Web workflow now consumes this unchanged API. Only current super admins see user navigation; server authorization remains authoritative. Directory pages are 25 native Auth records, with exact UID/email lookup and explicit page-local role/status/verification/provider filters. Empty matching pages retain their continuation. Details display only the safe projection. Revision zero is labelled as legacy or initial managed revision: it cannot distinguish unmanaged users from the initialized bootstrap member.

Each confirmed change freezes its ID, exact JSON bytes, reason and both preconditions before sending. Owner/environment-scoped tab recovery is required before a new mutation is sent. After an authoritative operation view is validated, only the owner/key checkpoint remains; reasons and request bytes are dropped. Three HTTP attempts are bounded, including at most one token refresh, with 1/2-second transport backoff. Further requests require an operator action; quota errors impose a 60-second cooldown. Reloading never starts a request automatically.

Lost acknowledgements retain the original bytes for retry. Operation-key lookup and explicit same-key resume preserve the server plan. Only pending operations with no active worker may be resumed in the browser. Worker-owned and recovery-required states direct operators to the trusted process above; there is no unlock, expiry, bypass or initialization button. Completed views show the fresh-sign-in timestamp and remain historical receipts, not current account details. A rejected mutation requires deliberate new-change review and a fresh target read before a new operation is enabled; read errors cannot discard unconfirmed intent.

Changing UID, signing out or losing the super-admin role clears private UI/recovery state. Temporary same-UID reauthentication suspends/hides the workflow and requires a fresh target read. Leaving warns about unfinished work and does not cancel server operations. Browser storage is best-effort, unencrypted tab storage; keep operation IDs/keys for trusted recovery if it becomes unavailable. See phase12_handoff.md for actual verification and browser limitations.
