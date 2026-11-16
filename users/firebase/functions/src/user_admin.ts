import { randomUUID } from "node:crypto";
import { getAuth, DecodedIdToken, UserRecord } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import {
  DocumentData,
  FieldValue,
  getFirestore,
  Timestamp,
} from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { AccountError, authorizeAdmin } from "./account";
import { assertManagedAccess, managedTokenMatches } from "./managed_access";
import { canonical, fail, hash } from "./content_validation";
import {
  decodeUserCursor,
  encodeUserCursor,
  operationKey,
  roles,
  Role,
  UserMutation,
  validateUserRequest,
} from "./user_admin_validation";

const registryPath = "serverControl/userAdministration";
export function roleOf(user: UserRecord): Role | "unsupported" {
  const role = user.customClaims?.role ?? "student";
  return roles.includes(role) ? role : "unsupported";
}
function security(user: UserRecord) {
  return {
    uid: user.uid,
    createdAt: user.metadata.creationTime,
    role: roleOf(user),
    disabled: user.disabled,
    emailVerified: user.emailVerified,
    claims: user.customClaims ?? {},
  };
}
export function userStateFingerprint(user: UserRecord): string {
  return hash(canonical(security(user)));
}
function active(state: DocumentData): boolean {
  return (
    state.role === "super_admin" &&
    state.disabled === false &&
    state.emailVerified === true
  );
}
function registry(data: DocumentData | undefined): DocumentData {
  if (!data || data.schemaVersion !== 1 || data.state !== "ready")
    return fail("user-admin-initialization-required", 409);
  if (
    !Number.isSafeInteger(data.activeSuperAdmins) ||
    data.activeSuperAdmins < 1
  )
    return fail("admin-registry-invalid", 409);
  return data;
}
function safeState(value: DocumentData) {
  return {
    role: value.role,
    disabled: value.disabled,
    emailVerified: value.emailVerified,
  };
}
function operationView(key: string, value: DocumentData) {
  return {
    schemaVersion: 1,
    operationKey: key,
    operationId: value.input.operationId,
    actorUid: value.actorUid,
    targetUid: value.input.targetUid,
    action: value.input.action,
    state: value.state,
    phase: value.phase,
    revision: value.nextRevision,
    before: safeState(value.before),
    after: safeState(value.after),
    lastError: value.lastError ?? null,
    result: value.result ?? null,
    workerActive: value.worker !== null,
  };
}
function validateActor(token: DecodedIdToken, data: DocumentData | undefined) {
  if (!data || data.role !== "super_admin" || !managedTokenMatches(token, data))
    return fail("administrator-unavailable", 403);
}
async function requireSuper(token: DecodedIdToken) {
  const user = await getAuth().getUser(token.uid);
  await assertManagedAccess(token);
  if (authorizeAdmin(token, user) !== "super_admin")
    return fail("permission-denied", 403);
  const db = getFirestore();
  const [control, actor] = await db.getAll(
    db.doc(registryPath),
    db.doc(`managedAccounts/${token.uid}`),
  );
  registry(control.data());
  validateActor(token, actor.data());
}
async function details(user: UserRecord, saved?: DocumentData) {
  return {
    uid: user.uid,
    name: user.displayName ?? "",
    email: user.email ?? null,
    providers: user.providerData.map((p) => p.providerId),
    emailVerified: user.emailVerified,
    disabled: user.disabled,
    role: roleOf(user),
    createdAt: user.metadata.creationTime,
    lastSignInAt: user.metadata.lastSignInTime ?? null,
    administrationRevision: saved?.revision ?? 0,
    administrationPending: saved?.pendingOperation != null,
    authState: userStateFingerprint(user),
  };
}
/** IAM-only adoption of the existing unique completed bootstrap; no Auth writes. */
export async function initializeUserAdministration(uid: string): Promise<void> {
  const db = getFirestore(),
    auth = getAuth(),
    ref = db.doc(registryPath),
    member = db.doc(`managedAccounts/${uid}`);
  const current = await ref.get();
  if (current.exists) {
    if (registry(current.data()).bootstrapUid !== uid)
      return fail("bootstrap-mismatch", 409);
    return;
  }
  const user = await auth.getUser(uid);
  if (!active(security(user))) return fail("bootstrap-not-eligible", 409);
  if (
    user.customClaims?.adminRevision !== undefined &&
    user.customClaims.adminRevision !== 0
  )
    return fail("admin-state-drift", 409);
  let cursor: string | undefined,
    complete = false;
  for (let page = 0; page < 100; page++) {
    const listed = await auth.listUsers(1000, cursor);
    if (listed.users.some((u) => u.uid !== uid && roleOf(u) === "super_admin"))
      return fail("unmanaged-super-admin", 409);
    cursor = listed.pageToken;
    if (!cursor) {
      complete = true;
      break;
    }
  }
  if (!complete) return fail("bootstrap-scan-limit", 409);
  await db.runTransaction(async (tx) => {
    const [control, bootstrap, account] = await tx.getAll(
      ref,
      db.doc("serverControl/adminBootstrap"),
      member,
    );
    if (control.exists) {
      if (registry(control.data()).bootstrapUid !== uid)
        return fail("bootstrap-mismatch", 409);
      return;
    }
    if (
      bootstrap.data()?.uid !== uid ||
      bootstrap.data()?.state !== "complete" ||
      account.exists
    )
      return fail("bootstrap-not-ready", 409);
    tx.create(ref, {
      schemaVersion: 1,
      state: "ready",
      bootstrapUid: uid,
      activeSuperAdmins: 1,
      pendingOperation: null,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.create(member, {
      schemaVersion: 1,
      uid,
      role: "super_admin",
      disabled: false,
      emailVerified: true,
      revision: 0,
      minAuthTime: 0,
      pendingOperation: null,
    });
    tx.create(db.doc(`adminAudit/user_admin_initialize_${hash(uid)}`), {
      actorUid: "trusted-cli",
      targetId: uid,
      action: "user_admin_initialize",
      createdAt: FieldValue.serverTimestamp(),
    });
  });
}

async function reserve(
  token: DecodedIdToken,
  input: UserMutation,
): Promise<string> {
  if (input.targetUid === token.uid)
    return fail("self-change-not-allowed", 409);
  const db = getFirestore(),
    key = operationKey(token.uid, input.operationId),
    ref = db.doc(`userAdminOperations/${key}`);
  const fingerprint = hash(canonical(input));
  const prior = await ref.get();
  if (prior.exists) {
    if (prior.data()!.fingerprint !== fingerprint)
      return fail("operation-id-reused", 409);
    return key;
  }
  const user = await getAuth().getUser(input.targetUid),
    before = security(user);
  if (userStateFingerprint(user) !== input.expectedState)
    return fail("auth-state-conflict", 409);
  if (before.role === "unsupported") return fail("unsupported-role", 409);
  const nextRevision = input.expectedRevision + 1;
  const after = {
    ...before,
    role: input.role ?? before.role,
    disabled: input.disabled ?? before.disabled,
    claims: {
      ...before.claims,
      role: input.role ?? before.role,
      adminRevision: nextRevision,
    },
  };
  if (after.role === before.role && after.disabled === before.disabled)
    return fail("already-in-state", 409);
  if (
    input.role &&
    input.role !== "student" &&
    (before.disabled || !before.emailVerified)
  )
    return fail("target-not-eligible", 409);
  if (Buffer.byteLength(JSON.stringify(after.claims)) > 1000)
    return fail("custom-claims-too-large", 409);
  await db.runTransaction(async (tx) => {
    const [control, actor, target, operation] = await tx.getAll(
      db.doc(registryPath),
      db.doc(`managedAccounts/${token.uid}`),
      db.doc(`managedAccounts/${input.targetUid}`),
      ref,
    );
    const state = registry(control.data());
    validateActor(token, actor.data());
    if (operation.exists) {
      if (operation.data()!.fingerprint !== fingerprint)
        return fail("operation-id-reused", 409);
      return;
    }
    if (state.pendingOperation !== null)
      return fail("administration-busy", 409);
    const saved = target.data();
    if ((saved?.revision ?? 0) !== input.expectedRevision)
      return fail("revision-conflict", 409);
    if (
      saved &&
      (saved.schemaVersion !== 1 ||
        saved.uid !== input.targetUid ||
        saved.pendingOperation !== null ||
        saved.role !== before.role ||
        saved.disabled !== before.disabled ||
        saved.emailVerified !== before.emailVerified ||
        (before.claims.adminRevision ?? 0) !== saved.revision)
    )
      return fail("admin-state-drift", 409);
    if (!saved && before.role === "super_admin")
      return fail("unmanaged-super-admin", 409);
    const count = state.activeSuperAdmins - (active(before) ? 1 : 0);
    if (count < 1) return fail("last-super-admin", 409);
    tx.update(control.ref, { pendingOperation: key, activeSuperAdmins: count });
    tx.set(target.ref, {
      schemaVersion: 1,
      uid: input.targetUid,
      ...safeState(before),
      revision: nextRevision,
      minAuthTime: saved?.minAuthTime ?? 0,
      pendingOperation: key,
    });
    tx.create(ref, {
      schemaVersion: 1,
      actorUid: token.uid,
      input,
      fingerprint,
      before,
      after,
      nextRevision,
      state: "pending",
      phase: "reserved",
      worker: null,
      lastError: null,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.create(db.doc(`adminAudit/user_admin_reserved_${key}`), {
      actorUid: token.uid,
      targetId: input.targetUid,
      action: "user_admin_reserved",
      operationId: input.operationId,
      operationKey: key,
      reason: input.reason,
      before: safeState(before),
      after: safeState(after),
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return key;
}

export interface UserAdminEffects {
  read(uid: string): Promise<UserRecord>;
  claims(uid: string, claims: Record<string, unknown>): Promise<void>;
  disabled(uid: string, disabled: boolean): Promise<unknown>;
  revoke(uid: string): Promise<void>;
}
function effects(): UserAdminEffects {
  const auth = getAuth();
  return {
    read: (uid) => auth.getUser(uid),
    claims: (uid, claims) => auth.setCustomUserClaims(uid, claims),
    disabled: (uid, disabled) => auth.updateUser(uid, { disabled }),
    revoke: (uid) => auth.revokeRefreshTokens(uid),
  };
}
function compatible(current: DocumentData, op: DocumentData): boolean {
  return [
    op.before,
    op.after,
    { ...op.before, role: op.after.role, claims: op.after.claims },
  ].some((value) => canonical(current) === canonical(value));
}
/** No expiring worker lease: uncertain Auth writers require trusted recovery. */
export async function runUserOperation(
  token: DecodedIdToken,
  key: string,
  io: UserAdminEffects = effects(),
) {
  const db = getFirestore(),
    ref = db.doc(`userAdminOperations/${key}`),
    worker = randomUUID();
  const op = await db.runTransaction(async (tx) => {
    const [control, actor, operation] = await tx.getAll(
      db.doc(registryPath),
      db.doc(`managedAccounts/${token.uid}`),
      ref,
    );
    registry(control.data());
    validateActor(token, actor.data());
    if (!operation.exists) return fail("operation-not-found", 404);
    const saved = operation.data()!;
    if (saved.state === "complete") return saved;
    if (control.data()!.pendingOperation !== key)
      return fail("admin-registry-invalid", 409);
    if (saved.worker !== null) return saved; // Status only; never overlap an existing Auth writer.
    tx.update(ref, {
      worker,
      workerStartedAt: FieldValue.serverTimestamp(),
      resumedBy: token.uid,
      state: "pending",
    });
    return saved;
  });
  if (op.state === "complete" || op.worker !== null)
    return operationView(key, op);
  let uncertain = false;
  async function stage(phase: string) {
    await db.runTransaction(async (tx) => {
      const saved = await tx.get(ref);
      if (saved.data()?.worker !== worker) return fail("worker-changed", 409);
      tx.update(ref, { phase, updatedAt: FieldValue.serverTimestamp() });
    });
  }
  try {
    const uid = op.input.targetUid;
    let current = security(await io.read(uid));
    if (!compatible(current, op)) return fail("admin-state-drift", 409);
    await stage("claims");
    if (canonical(current.claims) !== canonical(op.after.claims)) {
      uncertain = true;
      await io.claims(uid, op.after.claims);
      uncertain = false;
    }
    await stage("account-status");
    current = security(await io.read(uid));
    if (!compatible(current, op)) return fail("admin-state-drift", 409);
    if (current.disabled !== op.after.disabled) {
      uncertain = true;
      await io.disabled(uid, op.after.disabled);
      uncertain = false;
    }
    await stage("revocation");
    uncertain = true;
    await io.revoke(uid);
    uncertain = false;
    await stage("confirmation");
    const confirmed = await io.read(uid);
    if (canonical(security(confirmed)) !== canonical(op.after))
      return fail("admin-state-drift", 409);
    // Auth/ID tokens use seconds. Require a sign-in strictly AFTER the revoke
    // second, including a token that acquired new claims while still pending.
    const minAuthTime =
      Math.floor(Date.parse(confirmed.tokensValidAfterTime ?? "") / 1000) + 1;
    if (!Number.isSafeInteger(minAuthTime) || minAuthTime < 1)
      return fail("admin-state-drift", 409);
    await db.runTransaction(async (tx) => {
      const [control, operation, target] = await tx.getAll(
        db.doc(registryPath),
        ref,
        db.doc(`managedAccounts/${uid}`),
      );
      const state = registry(control.data());
      if (
        operation.data()?.worker !== worker ||
        state.pendingOperation !== key ||
        target.data()?.pendingOperation !== key
      )
        return fail("admin-registry-invalid", 409);
      const result = {
        uid,
        administrationRevision: op.nextRevision,
        authState: userStateFingerprint(confirmed),
        reauthenticateAfter: minAuthTime,
        ...safeState(op.after),
      };
      tx.update(target.ref, {
        ...safeState(op.after),
        minAuthTime,
        pendingOperation: null,
      });
      tx.update(control.ref, {
        pendingOperation: null,
        activeSuperAdmins: state.activeSuperAdmins + (active(op.after) ? 1 : 0),
      });
      tx.update(ref, {
        state: "complete",
        phase: "complete",
        worker: null,
        lastError: null,
        result,
        completedAt: FieldValue.serverTimestamp(),
      });
      tx.create(db.doc(`adminAudit/user_admin_complete_${key}`), {
        actorUid: op.actorUid,
        resumedBy: token.uid,
        targetId: uid,
        action: "user_admin_completed",
        operationId: op.input.operationId,
        operationKey: key,
        reason: op.input.reason,
        before: safeState(op.before),
        after: safeState(op.after),
        revision: op.nextRevision,
        createdAt: FieldValue.serverTimestamp(),
      });
    });
  } catch (e) {
    const code = e instanceof AccountError ? e.code : "service-unavailable";
    const recovery = uncertain || code === "admin-state-drift";
    await db.runTransaction(async (tx) => {
      const saved = await tx.get(ref);
      if (saved.data()?.worker !== worker) return;
      tx.update(ref, {
        state: recovery ? "recovery_required" : "pending",
        worker: recovery ? worker : null,
        lastError: { code, retryable: !recovery },
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
  return operationView(key, (await ref.get()).data()!);
}

/** IAM-only; operator must establish old invocation AND unknown Auth RPC settled. */
export async function unlockUserOperation(
  key: string,
  confirmation: string,
): Promise<void> {
  if (
    !/^[a-f0-9]{64}$/.test(key) ||
    confirmation !== `CONFIRM:TERMINATED_AND_AUTH_SETTLED:${key}`
  )
    return fail("recovery-confirmation-required", 400);
  const db = getFirestore(),
    ref = db.doc(`userAdminOperations/${key}`),
    saved = await ref.get(),
    op = saved.data();
  if (
    !op ||
    op.state === "complete" ||
    op.worker === null ||
    !(op.workerStartedAt instanceof Timestamp) ||
    Date.now() - op.workerStartedAt.toMillis() < 120000
  )
    return fail("worker-not-recoverable", 409);
  if (!compatible(security(await getAuth().getUser(op.input.targetUid)), op))
    return fail("admin-state-drift", 409);
  await db.runTransaction(async (tx) => {
    const [control, current] = await tx.getAll(db.doc(registryPath), ref);
    if (
      registry(control.data()).pendingOperation !== key ||
      current.data()?.worker !== op.worker ||
      current.data()?.state === "complete"
    )
      return fail("worker-changed", 409);
    tx.update(ref, { state: "pending", worker: null, lastError: null });
    tx.create(db.collection("adminAudit").doc(), {
      actorUid: "trusted-cli",
      targetId: op.input.targetUid,
      action: "user_admin_recovery_unlock",
      operationKey: key,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
}

/** Trusted server service; token was verified with revocation checks by HTTPS. */
export async function userAdminAction(token: DecodedIdToken, body: unknown) {
  await requireSuper(token);
  const db = getFirestore();
  await db.runTransaction(async (tx) => {
    const ref = db.doc(`userAdminRateLimits/${token.uid}`),
      saved = (await tx.get(ref)).data(),
      window = Math.floor(Date.now() / 60000);
    const count = saved?.window === window ? saved.count : 0;
    if (!Number.isSafeInteger(count) || count < 0)
      return fail("admin-registry-invalid", 409);
    if (count >= 60) return fail("rate-limited", 429);
    tx.set(ref, { window, count: count + 1 });
  });
  const input = validateUserRequest(body);
  if (input.action === "setRole" || input.action === "setDisabled")
    return runUserOperation(token, await reserve(token, input));
  if (input.action === "resume")
    return runUserOperation(token, input.operationKey);
  if (input.action === "operation") {
    const saved = await db
      .doc(`userAdminOperations/${input.operationKey}`)
      .get();
    if (!saved.exists) return fail("operation-not-found", 404);
    return operationView(input.operationKey, saved.data()!);
  }
  if (input.action === "get") {
    const user = input.uid
      ? await getAuth().getUser(input.uid)
      : await getAuth().getUserByEmail(input.email!);
    return {
      schemaVersion: 1,
      user: await details(
        user,
        (await db.doc(`managedAccounts/${user.uid}`).get()).data(),
      ),
    };
  }
  if (input.action !== "list") return fail();
  const cursor = input.cursor
    ? decodeUserCursor(token.uid, input.limit, input.filters, input.cursor)
    : undefined;
  const page = await getAuth().listUsers(input.limit, cursor);
  const managed = page.users.length
    ? await db.getAll(
        ...page.users.map((u) => db.doc(`managedAccounts/${u.uid}`)),
      )
    : [];
  const users = await Promise.all(
    page.users.map((u, i) => details(u, managed[i].data())),
  );
  return {
    schemaVersion: 1,
    users: users.filter(
      (u) =>
        (input.filters.role === undefined || u.role === input.filters.role) &&
        (input.filters.disabled === undefined ||
          u.disabled === input.filters.disabled) &&
        (input.filters.verified === undefined ||
          u.emailVerified === input.filters.verified) &&
        (input.filters.provider === undefined ||
          u.providers.includes(input.filters.provider)),
    ),
    scanned: page.users.length,
    nextCursor: page.pageToken
      ? encodeUserCursor(token.uid, input.limit, input.filters, page.pageToken)
      : null,
  };
}

export const userAdminApi = onRequest(
  { cors: true, timeoutSeconds: 60, maxInstances: 5 },
  async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (req.method !== "POST") {
      res.status(405).json({ code: "method-not-allowed" });
      return;
    }
    if (req.rawBody.length > 16384) {
      res.status(413).json({ code: "payload-too-large" });
      return;
    }
    if (!req.is("application/json")) {
      res.status(415).json({ code: "json-required" });
      return;
    }
    try {
      const header = req.headers.authorization;
      if (!header?.startsWith("Bearer ")) return fail("unauthenticated", 401);
      let token: DecodedIdToken;
      try {
        token = await getAuth().verifyIdToken(header.slice(7), true);
      } catch (e) {
        const code = (e as { code?: string }).code;
        return fail(
          code === "auth/id-token-revoked"
            ? "session-revoked"
            : code === "auth/user-disabled"
              ? "user-disabled"
              : "unauthenticated",
          401,
        );
      }
      if (process.env.REQUIRE_USER_ADMIN_APP_CHECK === "true") {
        const attestation = req.header("X-Firebase-AppCheck");
        if (!attestation) return fail("app-check-required", 403);
        try {
          await getAppCheck().verifyToken(attestation);
        } catch {
          return fail("app-check-invalid", 403);
        }
      }
      res.json(await userAdminAction(token, req.body));
    } catch (e) {
      if (e instanceof AccountError) {
        res.status(e.status).json({ code: e.code });
        return;
      }
      const code = (e as { code?: string | number }).code;
      res
        .status(
          code === "auth/user-not-found"
            ? 404
            : code === "auth/invalid-page-token"
              ? 400
              : code === 10 || code === "aborted"
                ? 409
                : 503,
        )
        .json({
          code:
            code === "auth/user-not-found"
              ? "user-not-found"
              : code === "auth/invalid-page-token"
                ? "invalid-cursor"
                : code === 10 || code === "aborted"
                  ? "transaction-contention"
                  : "service-unavailable",
        });
    }
  },
);
