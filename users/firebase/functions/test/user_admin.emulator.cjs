const { test, before, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("../../node_modules/@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
} = require("../../node_modules/firebase/firestore");
const { bootstrapFirstAdmin } = require("../lib/bootstrap");
const {
  initializeUserAdministration,
  runUserOperation,
  unlockUserOperation,
} = require("../lib/user_admin");
const { operationKey } = require("../lib/user_admin_validation");
let app,
  env,
  root,
  student,
  manager,
  sequence = 0;
const project = "demo-vocabulary",
  base = `http://127.0.0.1:15001/${project}/us-central1/`;
async function login(email) {
  const response = await fetch(
    `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email,
        password: "Fixture-password-123!",
        returnSecureToken: true,
      }),
    },
  );
  const data = await response.json();
  assert.ok(data.idToken);
  return data.idToken;
}
async function user(email, role = "student", verified = true) {
  const record = await getAuth().createUser({
    email,
    password: "Fixture-password-123!",
    emailVerified: verified,
    displayName: "Synthetic account",
  });
  await getAuth().setCustomUserClaims(record.uid, {
    role,
    feature: "preserved",
  });
  return { uid: record.uid, email, token: await login(email) };
}
async function freshLogin(target) {
  const saved = (
    await getFirestore().doc(`managedAccounts/${target.uid}`).get()
  ).data();
  const wait = (saved?.minAuthTime ?? 0) * 1000 - Date.now() + 20;
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  return login(target.email);
}
async function call(body, actor = root, api = "userAdminApi") {
  const response = await fetch(base + api, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(actor ? { Authorization: `Bearer ${actor.token}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(65000),
  });
  return { status: response.status, body: await response.json() };
}
async function ok(body, actor = root, api = "userAdminApi") {
  const result = await call(body, actor, api);
  assert.equal(result.status, 200, JSON.stringify(result));
  return result.body;
}
async function request(target, action, extra, actor = root) {
  const current = (await ok({ action: "get", uid: target.uid }, actor)).user;
  return {
    action,
    operationId: `user-operation-${++sequence}`,
    targetUid: target.uid,
    expectedRevision: current.administrationRevision,
    expectedState: current.authState,
    confirmed: true,
    reason: "Reviewed synthetic account change",
    ...extra,
  };
}
async function promote() {
  const candidate = await user(`super-${++sequence}@example.test`);
  const result = await ok(
    await request(candidate, "setRole", { role: "super_admin" }),
  );
  assert.equal(result.state, "complete");
  candidate.token = await freshLogin(candidate);
  return candidate;
}
async function pendingWithCollision(target) {
  const input = await request(target, "setRole", { role: "content_manager" }),
    key = operationKey(root.uid, input.operationId);
  const collision = getFirestore().doc(`adminAudit/user_admin_complete_${key}`);
  await collision.set({ syntheticFault: true });
  const result = await ok(input);
  assert.equal(result.state, "pending");
  assert.equal(result.workerActive, false);
  return { input, key, collision };
}
before(async () => {
  for (const key of [
    "FIRESTORE_EMULATOR_HOST",
    "FIREBASE_AUTH_EMULATOR_HOST",
  ]) {
    const value = process.env[key];
    if (!value) throw Error("Demo emulators required");
    const uri = new URL(`http://${value}`);
    if (
      !["127.0.0.1", "localhost"].includes(uri.hostname) ||
      !uri.port ||
      uri.username ||
      uri.password ||
      uri.pathname !== "/"
    )
      throw Error("Loopback emulators required");
  }
  if (!(process.env.GCLOUD_PROJECT ?? "").startsWith("demo-"))
    throw Error("Demo project required");
  app = initializeApp({ projectId: project });
  env = await initializeTestEnvironment({ projectId: project });
});
beforeEach(async () => {
  const reset = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${project}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  assert.ok(reset.ok);
  // This file runs last and resets only its hardcoded demo Auth namespace.
  let page;
  do {
    page = await getAuth().listUsers(1000);
    if (page.users.length)
      await getAuth().deleteUsers(page.users.map((u) => u.uid));
  } while (page.users.length);
  root = await user("user-admin-root@example.test");
  await bootstrapFirstAdmin(root.uid);
  await initializeUserAdministration(root.uid);
  root.token = await login(root.email);
  student = await user("user-admin-student@example.test");
  manager = await user("user-admin-manager@example.test", "content_manager");
});
after(async () => {
  await env?.cleanup();
  if (app) await deleteApp(app);
});

test("only verified current managed super admins can use the private directory or mutate roles", async () => {
  const get = { action: "list" };
  assert.equal((await call(get, null)).status, 401);
  assert.equal((await call(get, student)).status, 403);
  assert.equal((await call(get, manager)).status, 403);
  const unverified = await user(
    "unverified-root@example.test",
    "super_admin",
    false,
  );
  assert.equal((await call(get, unverified)).body.code, "email-unverified");
  const unmanaged = await user("unmanaged-root@example.test", "super_admin");
  assert.equal((await call(get, unmanaged)).status, 403);
  await getFirestore().doc(`users/${student.uid}`).set({ role: "super_admin" });
  assert.equal((await call(get, student)).status, 403);
  assert.equal((await call({ action: "list", uid: student.uid })).status, 400);
  const elevate = await request(student, "setRole", { role: "super_admin" });
  assert.equal((await call(elevate, student)).status, 403);
  await getAuth().updateUser(root.uid, { disabled: true });
  assert.equal((await call(get)).status, 401);
});
test("directory exposes only allowlisted identity metadata, exact lookup and bounded native pagination", async () => {
  const result = await ok({ action: "get", email: student.email });
  assert.equal(result.user.uid, student.uid);
  assert.deepEqual(result.user.providers, ["password"]);
  assert.equal(result.user.role, "student");
  assert.equal(result.user.administrationRevision, 0);
  assert.deepEqual(
    Object.keys(result.user).sort(),
    [
      "uid",
      "name",
      "email",
      "providers",
      "emailVerified",
      "disabled",
      "role",
      "createdAt",
      "lastSignInAt",
      "administrationRevision",
      "administrationPending",
      "authState",
    ].sort(),
  );
  const seen = new Set();
  let cursor;
  do {
    const page = await ok({
      action: "list",
      limit: 2,
      ...(cursor ? { cursor } : {}),
    });
    assert.ok(page.scanned <= 2);
    for (const entry of page.users) {
      assert.equal(seen.has(entry.uid), false);
      seen.add(entry.uid);
    }
    cursor = page.nextCursor;
  } while (cursor);
  assert.equal(seen.size, 3);
  const filtered = await ok({
    action: "list",
    limit: 1,
    filters: { role: "student", disabled: false, provider: "password" },
  });
  assert.ok(filtered.users.every((u) => u.role === "student" && !u.disabled));
  assert.ok(filtered.scanned <= 1);
  assert.equal(
    (await call({ action: "get", email: "not-found@example.test" })).status,
    404,
  );
  assert.equal(
    (await call({ action: "list", search: "substring" })).status,
    400,
  );
});
test("directory cursors cannot be reused under another actor, filter or page size", async () => {
  const second = await promote();
  const first = await ok({ action: "list", limit: 1 });
  assert.ok(first.nextCursor);
  assert.equal(
    (await call({ action: "list", limit: 1, cursor: first.nextCursor }, second))
      .body.code,
    "invalid-cursor",
  );
  assert.equal(
    (await call({ action: "list", limit: 2, cursor: first.nextCursor })).body
      .code,
    "invalid-cursor",
  );
  assert.equal(
    (
      await call({
        action: "list",
        limit: 1,
        filters: { disabled: true },
        cursor: first.nextCursor,
      })
    ).body.code,
    "invalid-cursor",
  );
});
test("role grant and revocation preserve unrelated claims and idempotently commit revision/audit", async () => {
  const input = await request(student, "setRole", { role: "content_manager" });
  const applied = await ok(input);
  assert.equal(applied.state, "complete");
  assert.equal(applied.revision, 1);
  const record = await getAuth().getUser(student.uid);
  assert.equal(record.customClaims.feature, "preserved");
  assert.equal(record.customClaims.adminRevision, 1);
  assert.equal((await call(input)).body.state, "complete");
  assert.equal(
    (await call({ ...input, role: "super_admin" })).body.code,
    "operation-id-reused",
  );
  const audits = await getFirestore()
    .collection("adminAudit")
    .where("action", "==", "user_admin_completed")
    .get();
  assert.equal(audits.size, 1);
  const fresh = { ...student, token: await freshLogin(student) };
  assert.equal(
    (await call({ action: "adminAccess" }, fresh, "accountApi")).status,
    200,
  );
  const revoked = await ok(
    await request(student, "setRole", { role: "student" }),
  );
  assert.equal(revoked.state, "complete");
  const after = await getAuth().getUser(student.uid);
  assert.equal(after.customClaims.role, "student");
  assert.equal(after.customClaims.adminRevision, 2);
  assert.equal(after.customClaims.feature, "preserved");
  assert.equal(
    (await call({ action: "adminAccess" }, fresh, "accountApi")).status,
    401,
  );
});
test("enable/disable is explicit, revision-aware and forces old sessions to fail", async () => {
  const input = await request(student, "setDisabled", { disabled: true });
  assert.equal((await ok(input)).state, "complete");
  assert.equal((await getAuth().getUser(student.uid)).disabled, true);
  assert.equal(
    (await call({ action: "initializeProfile" }, student, "accountApi")).status,
    401,
  );
  const enable = await request(student, "setDisabled", { disabled: false });
  assert.equal((await ok(enable)).state, "complete");
  assert.equal((await getAuth().getUser(student.uid)).disabled, false);
  const fresh = { ...student, token: await freshLogin(student) };
  assert.equal(
    (await call({ action: "initializeProfile" }, fresh, "accountApi")).status,
    200,
  );
  assert.equal((await call(input)).body.state, "complete");
  assert.equal((await getAuth().getUser(student.uid)).disabled, false);
});
test("confirmation, reasons, revision and observed Auth-state preconditions prevent silent overwrite", async () => {
  const input = await request(student, "setDisabled", { disabled: true });
  assert.equal((await call({ ...input, confirmed: false })).status, 400);
  assert.equal((await call({ ...input, reason: "x" })).status, 400);
  assert.equal(
    (await call({ ...input, expectedRevision: 2 })).body.code,
    "revision-conflict",
  );
  await getAuth().setCustomUserClaims(student.uid, {
    role: "student",
    feature: "new external intent",
  });
  assert.equal((await call(input)).body.code, "auth-state-conflict");
  assert.equal((await getAuth().getUser(student.uid)).disabled, false);
  assert.equal(
    (await getFirestore().collection("userAdminOperations").get()).size,
    0,
  );
  await getFirestore().doc(`managedAccounts/${student.uid}`).set({
    schemaVersion: 2,
    uid: student.uid,
    role: "student",
    disabled: false,
    emailVerified: true,
    revision: 0,
    pendingOperation: null,
  });
  assert.equal(
    (await call(await request(student, "setDisabled", { disabled: true }))).body
      .code,
    "admin-state-drift",
  );
});
test("self changes and removal of the final counted active admin fail without reservations", async () => {
  assert.equal(
    (await call(await request(root, "setRole", { role: "student" }))).body.code,
    "self-change-not-allowed",
  );
  assert.equal(
    (await call(await request(root, "setDisabled", { disabled: true }))).body
      .code,
    "self-change-not-allowed",
  );
  const other = await promote();
  // A conservative corrupt count must fail closed, never be decremented to zero.
  await getFirestore()
    .doc("serverControl/userAdministration")
    .update({ activeSuperAdmins: 1 });
  assert.equal(
    (await call(await request(other, "setDisabled", { disabled: true }))).body
      .code,
    "last-super-admin",
  );
  assert.equal(
    (await getFirestore().doc("serverControl/userAdministration").get()).data()
      .activeSuperAdmins,
    1,
  );
  assert.equal((await getAuth().getUser(other.uid)).disabled, false);
});
test("competing super-admin disable requests leave at least one usable active super admin", async () => {
  const other = await promote();
  const a = await request(other, "setDisabled", { disabled: true });
  const b = await request(root, "setDisabled", { disabled: true }, other);
  const results = await Promise.all([call(a), call(b, other)]);
  assert.equal(
    results.filter((r) => r.status === 200 && r.body.state === "complete")
      .length,
    1,
  );
  const users = await Promise.all([
    getAuth().getUser(root.uid),
    getAuth().getUser(other.uid),
  ]);
  const survivors = users.filter(
    (u) =>
      !u.disabled && u.emailVerified && u.customClaims.role === "super_admin",
  );
  assert.equal(survivors.length, 1);
  const state = (
    await getFirestore().doc("serverControl/userAdministration").get()
  ).data();
  assert.equal(state.activeSuperAdmins, 1);
  assert.equal(state.pendingOperation, null);
  const survivor = {
    uid: survivors[0].uid,
    token: await freshLogin(survivors[0]),
  };
  assert.equal((await call({ action: "list" }, survivor)).status, 200);
});
test("competing demotions and grants serialize without silently reusing stale target revisions", async () => {
  const a = await request(student, "setRole", { role: "content_manager" }),
    b = await request(student, "setRole", { role: "super_admin" });
  const outcomes = await Promise.all([call(a), call(b)]);
  assert.equal(
    outcomes.filter((r) => r.status === 200 && r.body.state === "complete")
      .length,
    1,
  );
  const user = await getAuth().getUser(student.uid),
    state = (
      await getFirestore().doc(`managedAccounts/${student.uid}`).get()
    ).data();
  assert.equal(user.customClaims.adminRevision, 1);
  assert.equal(state.revision, 1);
  assert.equal(state.pendingOperation, null);
});
test("a final Firestore failure leaves Auth changes quarantined and resumes without a second revision", async () => {
  const { input, key, collision } = await pendingWithCollision(student);
  const saved = (
    await getFirestore().doc(`managedAccounts/${student.uid}`).get()
  ).data();
  assert.equal(saved.pendingOperation, key);
  const fresh = { ...student, token: await login(student.email) };
  assert.equal(
    (await call({ action: "adminAccess" }, fresh, "accountApi")).body.code,
    "account-change-pending",
  );
  assert.equal(
    (
      await call(
        {
          operationId: "pending-probe",
          wordId: "pending-word",
          action: "create",
          expectedRevision: 0,
          content: {},
        },
        fresh,
        "contentApi",
      )
    ).body.code,
    "account-change-pending",
  );
  assert.equal(
    (
      await call(
        { action: "preview", import: { schemaVersion: 1, items: [] } },
        fresh,
        "importApi",
      )
    ).body.code,
    "account-change-pending",
  );
  assert.equal(
    (await call({ action: "list" }, fresh, "progressApi")).body.code,
    "account-change-pending",
  );
  await collision.delete();
  const done = await ok({ action: "resume", operationKey: key });
  assert.equal(done.state, "complete");
  assert.equal(done.revision, 1);
  assert.equal((await ok(input)).revision, 1);
});
test("concurrent resumes cannot run overlapping Auth writers", async () => {
  const { key, collision } = await pendingWithCollision(student);
  await collision.delete();
  const auth = getAuth(),
    decoded = await auth.verifyIdToken(root.token, true);
  let release, started;
  const ready = new Promise((resolve) => (started = resolve));
  const pause = new Promise((resolve) => (release = resolve));
  let revocations = 0;
  const first = runUserOperation(decoded, key, {
    read: async (uid) => {
      started();
      await pause;
      return auth.getUser(uid);
    },
    claims: (uid, claims) => auth.setCustomUserClaims(uid, claims),
    disabled: (uid, disabled) => auth.updateUser(uid, { disabled }),
    revoke: async (uid) => {
      revocations++;
      await auth.revokeRefreshTokens(uid);
    },
  });
  await ready;
  const observed = await ok({ action: "resume", operationKey: key });
  assert.equal(observed.workerActive, true);
  assert.notEqual(observed.state, "complete");
  release();
  const done = await first;
  assert.equal(done.state, "complete");
  assert.equal(revocations, 1);
});
test("uncertain Auth outcomes retain their worker lock until explicit trusted settled-worker recovery", async () => {
  const { key, collision } = await pendingWithCollision(student);
  await collision.delete();
  const auth = getAuth(),
    decoded = await auth.verifyIdToken(root.token, true);
  const uncertain = await runUserOperation(decoded, key, {
    read: (uid) => auth.getUser(uid),
    claims: (uid, claims) => auth.setCustomUserClaims(uid, claims),
    disabled: (uid, disabled) => auth.updateUser(uid, { disabled }),
    revoke: async (uid) => {
      await auth.revokeRefreshTokens(uid);
      throw Error("Synthetic lost Auth acknowledgement");
    },
  });
  assert.equal(uncertain.state, "recovery_required");
  assert.equal(uncertain.workerActive, true);
  assert.equal(uncertain.lastError.retryable, false);
  assert.equal(
    (await ok({ action: "resume", operationKey: key })).state,
    "recovery_required",
  );
  await assert.rejects(unlockUserOperation(key, "wrong"));
  await assert.rejects(
    unlockUserOperation(key, `CONFIRM:TERMINATED_AND_AUTH_SETTLED:${key}`),
  );
  await getFirestore()
    .doc(`userAdminOperations/${key}`)
    .update({ workerStartedAt: Timestamp.fromMillis(Date.now() - 121000) });
  await unlockUserOperation(key, `CONFIRM:TERMINATED_AND_AUTH_SETTLED:${key}`);
  assert.equal(
    (await ok({ action: "resume", operationKey: key })).state,
    "complete",
  );
});
test("stale privileged JWTs cannot bypass managed account rules or edit server control records", async () => {
  await ok(await request(student, "setRole", { role: "content_manager" }));
  await getFirestore()
    .doc("words/private-admin-fixture")
    .set({ isPublished: false, isRetired: false });
  await getFirestore().doc(`users/${student.uid}`).set({ uid: student.uid });
  const firstLedger = (
    await getFirestore().doc(`managedAccounts/${student.uid}`).get()
  ).data();
  const preRevoke = env
    .authenticatedContext(student.uid, {
      role: "content_manager",
      adminRevision: 1,
      auth_time: firstLedger.minAuthTime - 1,
    })
    .firestore();
  await assertFails(getDoc(doc(preRevoke, "words/private-admin-fixture")));
  const stale = env
    .authenticatedContext(student.uid, {
      role: "content_manager",
      adminRevision: 1,
      auth_time: firstLedger.minAuthTime,
    })
    .firestore();
  await assertSucceeds(getDoc(doc(stale, "words/private-admin-fixture")));
  await ok(await request(student, "setRole", { role: "student" }));
  await assertFails(getDoc(doc(stale, "words/private-admin-fixture")));
  await assertFails(getDoc(doc(stale, `users/${student.uid}`)));
  const latest = (
    await getFirestore().doc(`managedAccounts/${student.uid}`).get()
  ).data();
  const current = env
    .authenticatedContext(student.uid, {
      role: "student",
      adminRevision: 2,
      auth_time: latest.minAuthTime,
    })
    .firestore();
  await assertSucceeds(getDoc(doc(current, `users/${student.uid}`)));
  const superClient = env
    .authenticatedContext(root.uid, { role: "super_admin" })
    .firestore();
  for (const path of [
    `managedAccounts/${student.uid}`,
    "serverControl/userAdministration",
    "userAdminOperations/forged",
    "userAdminRateLimits/forged",
  ]) {
    await assertFails(setDoc(doc(superClient, path), { role: "super_admin" }));
    await assertFails(getDoc(doc(superClient, path)));
  }
});
test("initialization seals bootstrap and refuses unmanaged super-admin adoption or registry recreation", async () => {
  await assert.rejects(bootstrapFirstAdmin(root.uid));
  await initializeUserAdministration(root.uid);
  await getFirestore().doc("serverControl/userAdministration").delete();
  assert.equal(
    (await call({ action: "list" })).body.code,
    "user-admin-initialization-required",
  );
  await assert.rejects(initializeUserAdministration(root.uid));
  await getFirestore().doc(`managedAccounts/${root.uid}`).delete();
  await user("extra-super@example.test", "super_admin");
  await assert.rejects(initializeUserAdministration(root.uid));
  assert.equal(
    (await getFirestore().doc("serverControl/userAdministration").get()).exists,
    false,
  );
});
test("stale claims, revoked sessions, quotas and payload allowlists deny reads and operation replays", async () => {
  const other = await promote();
  await ok(await request(other, "setRole", { role: "content_manager" }));
  assert.equal((await call({ action: "list" }, other)).status, 401);
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await getAuth().revokeRefreshTokens(root.uid);
  assert.equal((await call({ action: "list" })).body.code, "session-revoked");
  root.token = await login(root.email);
  assert.equal(
    (
      await call({
        action: "setRole",
        targetUid: student.uid,
        role: "super_admin",
        actorUid: root.uid,
      })
    ).status,
    400,
  );
  await getFirestore()
    .doc(`userAdminRateLimits/${root.uid}`)
    .set({ window: Math.floor(Date.now() / 60000), count: 60 });
  assert.equal((await call({ action: "list" })).status, 429);
});
