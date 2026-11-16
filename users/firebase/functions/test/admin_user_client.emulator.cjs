const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { resolve } = require("node:path");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const { bootstrapFirstAdmin } = require("../lib/bootstrap");
const {
  initializeUserAdministration,
  userStateFingerprint,
} = require("../lib/user_admin");
const { operationKey } = require("../lib/user_admin_validation");
test("real Admin user client uses only demo accounts and immutable managed operations", async () => {
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
      throw Error("Loopback required");
  }
  if (
    !(process.env.GCLOUD_PROJECT ?? "").startsWith("demo-") ||
    !process.env.VOCAB_FLUTTER_TOOLS_SNAPSHOT
  )
    throw Error("Demo project and Flutter snapshot required");
  const projectId = "demo-vocabulary",
    app = initializeApp({ projectId });
  try {
    const db = getFirestore(),
      auth = getAuth();
    const reset = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: "DELETE" },
    );
    assert.ok(reset.ok);
    let page;
    do {
      page = await auth.listUsers(1000);
      if (page.users.length)
        await auth.deleteUsers(page.users.map((u) => u.uid));
    } while (page.users.length);
    async function create(uid, role = "student") {
      const user = await auth.createUser({
        uid,
        email: `${uid}@example.test`,
        emailVerified: true,
        password: "Fixture-password-123!",
        displayName: "Synthetic account only",
      });
      await auth.setCustomUserClaims(uid, { role, feature: "preserved" });
      return user;
    }
    async function login(uid) {
      const response = await fetch(
        `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            email: `${uid}@example.test`,
            password: "Fixture-password-123!",
            returnSecureToken: true,
          }),
        },
      );
      const data = await response.json();
      assert.ok(data.idToken);
      return data.idToken;
    }
    const rootUid = "zz-demo-user-root";
    await create(rootUid);
    await bootstrapFirstAdmin(rootUid);
    await initializeUserAdministration(rootUid);
    const managerUid = "demo-user-manager",
      targetUid = "demo-user-target",
      pendingUid = "demo-user-pending";
    await create(managerUid, "content_manager");
    await create(targetUid);
    await create(pendingUid);
    for (let i = 0; i < 27; i++)
      await create(`demo-filler-${String(i).padStart(2, "0")}`);
    const token = await login(rootUid),
      managerToken = await login(managerUid),
      endpoint = `http://127.0.0.1:15001/${projectId}/us-central1/userAdminApi`;
    const id = "pending-browser-operation",
      key = operationKey(rootUid, id),
      collision = db.doc(`adminAudit/user_admin_complete_${key}`);
    await collision.set({ syntheticFault: true });
    const pending = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        action: "setRole",
        operationId: id,
        targetUid: pendingUid,
        expectedRevision: 0,
        expectedState: userStateFingerprint(await auth.getUser(pendingUid)),
        confirmed: true,
        reason: "Synthetic pending operation fixture",
        role: "content_manager",
      }),
    });
    const outcome = await pending.json();
    assert.equal(pending.status, 200);
    assert.equal(outcome.state, "pending");
    assert.equal(outcome.workerActive, false);
    await collision.delete();
    const result = spawnSync(
      process.env.VOCAB_DART_BIN ?? "dart",
      [
        process.env.VOCAB_FLUTTER_TOOLS_SNAPSHOT,
        "test",
        "test/user_admin_emulator_probe.dart",
        "--reporter",
        "expanded",
      ],
      {
        cwd: resolve(__dirname, "../../../../admin/admin_panel"),
        encoding: "utf8",
        timeout: 240000,
        env: {
          ...process.env,
          VOCAB_USER_ADMIN_DEMO_CONFIG: JSON.stringify({
            projectId,
            endpoint,
            uid: rootUid,
            token,
            managerUid,
            managerToken,
            targetUid,
            pendingKey: key,
          }),
        },
      },
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    process.stdout.write(result.stdout);
    const target = await auth.getUser(targetUid);
    assert.equal(target.disabled, false);
    assert.equal(target.customClaims.role, "content_manager");
    assert.equal(target.customClaims.adminRevision, 3);
    assert.equal(target.customClaims.feature, "preserved");
    assert.equal(
      (await db.doc("serverControl/userAdministration").get()).data()
        .activeSuperAdmins,
      1,
    );
    assert.equal(
      (await db.doc("serverControl/userAdministration").get()).data()
        .pendingOperation,
      null,
    );
    assert.equal(
      (await db.doc(`managedAccounts/${pendingUid}`).get()).data()
        .pendingOperation,
      null,
    );
    assert.equal((await db.collection("words").get()).size, 0);
  } finally {
    await deleteApp(app);
  }
});
