# Phase 11 handoff: trusted user administration backend

## Completed scope

Implemented userAdminApi with current verified managed-super-admin authorization, exact UID/email lookup, bounded native Auth pagination/page-local filters, allowlisted account details, enable/disable and assignment/revocation of approved roles. Mutations require stable IDs, target revision and observed Auth-state preconditions, confirmation intent and bounded reasons. Quotas, immutable operation receipts and safe reservation/completion/recovery audits are included.

The existing repository structure, registrations, content/progress data and prior work are preserved. No Admin user-management screens, account deletion, exports, packages, indexes, deployment, live initialization or real-user changes were performed. No private progress scan is introduced. The directory never returns raw claims, tokens, password hashes/salts, phone/MFA data or private learning records. It reads one native Auth page/request; exact filters apply to that bounded page, so an empty filtered page may still have a continuation cursor. No unsupported full-text search or fabricated totals are claimed.

## Security and consistency

An IAM-only initialization adopts the existing sole completed bootstrap member at revision zero. It verifies eligible Auth state and refuses additional unmanaged super admins or incompatible records instead of inventing a count. It performs no Auth write. Old bootstrap is sealed afterward and cannot regrant a role that was changed later. Initialization requires a maintenance window excluding other Auth/registry/bootstrap writers.

Management mutations serialize through a global pending reservation. Pending targets are quarantined and removed from the active-super-admin count; reservation cannot reduce that count below one. Grants are counted only after Auth confirmation and final commit. Transactional actor checks and refusal of all self role/status changes protect competing reduction requests. Existing unrelated custom claims are preserved; target revision, security fingerprint, UID and managed schema are checked before mutation.

A durable worker sets claims/status, revokes sessions and confirms Auth against frozen before/after/known-intermediate snapshots. Only then does a Firestore transaction release quarantine, update the active count and commit result/audit. Auth and Firestore are NOT atomic: Auth can already have changed while access remains blocked pending confirmation. Account/content/import/progress HTTPS gates and owner/editor/super-admin rules now enforce managed role/adminRevision, non-disabled/non-pending state and post-revocation auth_time. The barrier is strictly after the revoke second, including tokens that acquired new claims while pending. Targets must sign in again after reauthenticateAfter; an older session's force-refresh is insufficient.

Missing managed records retain legacy behavior in older endpoints/rules; only initialized managed super admins can use userAdminApi. All targets changed through it are enrolled before Auth writes. Public published vocabulary remains public and offline caches cannot be erased remotely. Already-authorized in-flight requests may finish. Guarantees cover the controlled workflow and coherent registry, not independent Console/IAM changes, Auth client self-deletion, external verification/status/claim writers or security-ledger rollback. No absolute protection against an external privileged actor is claimed.

Known settled failures release the worker and allow same-key resume. Uncertain Auth outcomes retain ownership and mark recovery_required; a hard crash can leave pending/workerActive. There is NO automatic worker expiry/takeover because a delayed Auth RPC cannot be fenced by a Firestore lease. IAM recovery requires explicit confirmation that the invocation terminated AND unknown Auth RPCs settled, a minimum 120-second age and compatible observed Auth state. Age alone is never proof. Unlock clears ownership only; authorized resume still confirms/finalizes. Drift requires operator diagnosis, not changed retry payloads, deleted locks or reset counters. Frozen intent is never silently rebased.

See user_admin_api.md for complete request/response/error/state schemas, pagination, adoption, protected-read compatibility, retention and recovery guarantees. No background dispatcher, public force/unlock, rollback, deletion or automatic multi-admin adoption is supplied. Operations/claims snapshots/audit reasons remain in denied server-only records until a reviewed retention policy exists.

## Actual verification

| Check | Result |
| --- | --- |
| npm.cmd run check | Passed, strict TypeScript/no-unused analysis |
| npm.cmd test | 27 passed: 20 prior tests + 7 administration/access validation tests; includes build |
| Complete isolated emulator regression | 60 Node checks passed: 45 prior + 15 administration cases |
| Final targeted administration run | 15 passed against fresh demo emulators after final schema/quota hardening; repeats are not extra unique tests |
| Focused source/test formatting, Node syntax, git diff --check | Passed; existing LF/CRLF conversion notices remain |

Tests cover actor permissions, safe projection, exact lookup, cursor/filter/actor binding, bounded pages, role grant/revoke, preserved unrelated claims, enable/disable, immutable duplicate receipts, changed intent/revision/Auth-state and unknown-schema rejection, self/last-count guards, competing reductions/grants, stale claims, quotas and direct server-control bypass denial.

An audit-collision fault after Auth effects proves quarantine persists until same-key finalization without another revision. Coordinated resumes prove only one Auth worker runs. Another adapter performs real demo revocation then throws a synthetic lost acknowledgement: ownership remains locked until guarded trusted recovery. Rules reject stale versions AND matching-version tokens predating the sign-in barrier. Pending targets are denied across all four existing protected APIs. Bootstrap sealing and legacy compatibility are tested.

The recovery test simulates a settled failed worker and advances only its demo timestamp to test the age guard without waiting two minutes. No deployed process was killed; actual termination/provider-settlement verification remains manual. The full suite also reruns existing real Student HTTP/Drift probes and the real Admin import Flutter probe. No Dart source changed, so Flutter analysis/widget suites and platform/Web builds were not rerun. Local Node is 24.7 while Functions target Node 22; deployed IAM/runtime/real attestation remain unverified.

All checks used guarded loopback demo-vocabulary emulators, synthetic users and temporary client databases. The new suite runs last and resets only that hardcoded demo Auth/Firestore namespace. No personal app/browser storage, real account, service-account key or live Firebase data was accessed. No app was installed/launched and no real administrator was provisioned or modified.

## Modified files

- users/firebase/functions/src/user_admin.ts (new): directory, registry, immutable reservations, Auth workflow, safe views, quotas, trusted initialization/recovery and HTTPS endpoint.
- users/firebase/functions/src/user_admin_validation.ts (new): strict requests, approved roles, reasons/preconditions and bound cursors.
- users/firebase/functions/src/managed_access.ts (new): pending/disabled/role/version/fresh-sign-in checks.
- users/firebase/functions/src/user_admin_cli.ts (new): guarded IAM-only adoption/unlock.
- users/firebase/functions/src/errors.ts (new): shared AccountError without a circular authorization dependency; account.ts retains its re-export.
- users/firebase/functions/src/account.ts, content.ts, imports.ts and progress.ts: managed gate in existing authenticated paths; request bodies/receipts preserved except documented new access-state errors.
- users/firebase/functions/src/bootstrap.ts: seal after adoption and prevent completed bootstrap from regranting changed roles.
- users/firebase/functions/src/index.ts: exports userAdminApi.
- users/firebase/firestore.rules: managed checks on protected reads; existing/new control writes and control reads remain denied.
- users/firebase/functions/test/user_admin.test.cjs and user_admin.emulator.cjs (new): 7 unit and 15 integration/fault cases.
- users/firebase/functions/test/run-emulators.cjs: administration suite last.
- docs/user_admin_api.md and phase11_handoff.md (new), implementation_plan.md, data_schema.md, setup.md, publication_api.md, import_api.md and progress_api.md: contracts, rollout, schema, evidence and limitations.

Earlier uncommitted changes remain intact and are not newly attributed here. Generated functions/lib output/logs are ignored. No dependency/lockfile, index, registration, client source or Drift layout changed.

## Manual setup and remaining boundary

A future authorized rollout must deploy compatible protected HTTP gates AND updated rules before initializing/using userAdminApi. Deploying only the new endpoint leaves stale-token paths unprotected. Verify server IAM for Auth get/list/update/revocation and Firestore transactions. No deployment was performed.

Use the existing sole verified bootstrap UID and a quiescent operator window. Exact confirmation commands/refusal conditions are in setup.md. Multiple unmanaged super admins require separate migration. Confirm all old invocations/unknown Auth RPCs have settled before initialization/recovery; never infer this from age alone. Keep registry/members/receipts coherent with Auth/backups and never remove a gate or rewind a security version to regain access.

Configure valid App Check callers before enabling REQUIRE_USER_ADMIN_APP_CHECK. Managed targets need a fresh sign-in after the returned timestamp. Existing clients may show generic messages for account-change-pending/session-stale; detailed administration UI/error UX is a separate phase. Their bounded stale-token retries cannot bypass the gate or silently erase learning intent.

Use disposable demo accounts/data for manual runtime/IAM/provider checks, competing requests, controlled worker termination and recovery/retention/backup acceptance. Admin user-management screens, deletion and deployment remain separately approved. Phase 11 is complete; stop and await approval.
