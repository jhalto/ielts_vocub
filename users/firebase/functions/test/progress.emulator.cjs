const { test, before, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
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
const { hash } = require("../lib/content_validation");
const project = "demo-vocabulary";
const base = `http://127.0.0.1:15001/${project}/us-central1`;
let app, env, alice, bob, editor, unverified;
async function user(label, verified = true, role) {
  const email = `progress-${label}@example.test`;
  const record = await getAuth().createUser({
    email,
    password: "Fixture-password-123!",
    emailVerified: verified,
  });
  if (role) await getAuth().setCustomUserClaims(record.uid, { role });
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
  return { uid: record.uid, token: data.idToken };
}
async function call(body, token = alice.token, endpoint = "progressApi") {
  const response = await fetch(`${base}/${endpoint}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(65000),
  });
  return { status: response.status, body: await response.json() };
}
function op(wordId = "word-a", extra = {}) {
  return {
    operationId: randomUUID(),
    deviceId: "windows-device",
    wordId,
    desiredStatus: "didnt_know",
    baseRevision: 0,
    sequence: 1,
    ...extra,
  };
}
const upload = (...operations) => ({ action: "upload", operations });
async function one(operation, token = alice.token) {
  const response = await call(upload(operation), token);
  assert.equal(response.status, 200, JSON.stringify(response));
  return response.body.results[0];
}
async function content(wordId, action, expectedRevision, extra = {}) {
  const response = await call(
    { operationId: randomUUID(), wordId, action, expectedRevision, ...extra },
    editor.token,
    "contentApi",
  );
  assert.equal(response.status, 200, JSON.stringify(response));
  return response.body;
}
before(async () => {
  if (
    !process.env.FIRESTORE_EMULATOR_HOST ||
    !process.env.FIREBASE_AUTH_EMULATOR_HOST ||
    !(process.env.GCLOUD_PROJECT ?? project).startsWith("demo-")
  )
    throw new Error("Demo emulators required");
  app = initializeApp({ projectId: project });
  env = await initializeTestEnvironment({ projectId: project });
  alice = await user("alice");
  bob = await user("bob");
  editor = await user("editor", true, "content_manager");
  unverified = await user("unverified", false);
});
beforeEach(async () => {
  const reset = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${project}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  assert.ok(reset.ok);
  for (const wordId of ["word-a", "word-b", "word-c"]) {
    const draft = await content(wordId, "create", 0, {
      content: {
        spelling: `Synthetic Progress ${wordId}`,
        pronunciation: "test",
        category: "basic",
        difficulty: "easy",
        ordering: 0,
        senses: [
          {
            id: "sense",
            partOfSpeech: "noun",
            englishMeaning: "Test only",
            bengaliMeaning: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
            ordering: 0,
            examples: [
              {
                english: "Test only",
                bengali: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
              },
            ],
          },
        ],
      },
    });
    await content(wordId, "publish", draft.revision, { reviewed: true });
  }
});
after(async () => {
  await env?.cleanup();
  await deleteApp(app);
});

test("verified identity is mandatory and forged UID/role/unknown fields never authorize writes", async () => {
  assert.equal((await call(upload(op()), null)).status, 401);
  assert.equal(
    (await call(upload(op()), unverified.token)).body.code,
    "email-unverified",
  );
  assert.equal((await call({ action: "list" }, unverified.token)).status, 403);
  assert.equal((await call({ ...upload(op()), uid: bob.uid })).status, 400);
  assert.equal(
    (await call(upload(op("word-a", { uid: bob.uid })))).status,
    400,
  );
  assert.equal(
    (await call(upload(op("word-a", { desiredStatus: "learning" })))).status,
    400,
  );
  assert.equal(
    (await call(upload(op("word-a", { createdAt: "tomorrow" })))).status,
    400,
  );
  const valid = await one(op());
  assert.equal(valid.code, "applied");
  assert.equal(
    (await getFirestore().collection(`users/${bob.uid}/progress`).get()).size,
    0,
  );
  assert.equal(
    (
      await call({
        action: "upload",
        operations: [op(), op("word-b", { sequence: 0 })],
      })
    ).status,
    400,
  );
  const huge = await call({ action: "list", extra: "x".repeat(70000) });
  assert.equal(huge.status, 413);
  assert.equal(
    (
      await call({
        action: "upload",
        operations: Array.from({ length: 26 }, () => op()),
      })
    ).status,
    400,
  );
});

test("accepted retries replay exact results without changing revisions, timestamps or other UIDs", async () => {
  const operation = op();
  const accepted = await one(operation);
  const ref = getFirestore().doc(`users/${alice.uid}/progress/word-a`);
  const before = (await ref.get()).data();
  const replay = await one(operation);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.progress, accepted.progress);
  assert.deepEqual((await ref.get()).data(), before);
  const changed = await one({ ...operation, desiredStatus: "learned" });
  assert.equal(changed.code, "operation-id-reused");
  const bobResult = await one(operation, bob.token);
  assert.equal(bobResult.replayed, false);
  assert.equal(bobResult.progress.revision, 1);
  assert.equal(
    (await getFirestore().collection(`users/${alice.uid}/syncOps`).get()).size,
    1,
  );
});

test("simultaneous identical retries commit once and competing devices cannot silently overwrite", async () => {
  const operation = op();
  const identical = await Promise.all([one(operation), one(operation)]);
  assert.equal(identical.filter((result) => !result.replayed).length, 1);
  assert.equal(
    (
      await getFirestore().doc(`users/${alice.uid}/syncState/progress`).get()
    ).data().revision,
    1,
  );
  const races = await Promise.all([
    one(
      op("word-a", { baseRevision: 1, sequence: 2, desiredStatus: "learned" }),
    ),
    one(
      op("word-a", {
        deviceId: "android-device",
        baseRevision: 1,
        desiredStatus: "already_know",
      }),
    ),
  ]);
  assert.deepEqual(races.map((result) => result.code).sort(), [
    "applied",
    "revision-conflict",
  ]);
  const winner = races.find((result) => result.code === "applied");
  const loser = races.find((result) => result.code === "revision-conflict");
  assert.equal(loser.progress.revision, winner.progress.revision);
  assert.equal(loser.progress.status, winner.progress.status);
});

test("conflict receipts remain immutable; an explicit linked rebase creates a new revision", async () => {
  await one(op());
  const stale = op("word-a", {
    desiredStatus: "learned",
    deviceId: "ios-device",
  });
  const conflict = await one(stale);
  assert.equal(conflict.code, "revision-conflict");
  const rebased = await one({
    ...stale,
    operationId: randomUUID(),
    baseRevision: conflict.progress.revision,
    supersedesOperationId: stale.operationId,
  });
  assert.equal(rebased.code, "applied");
  assert.equal(rebased.progress.status, "learned");
  const replay = await one(stale);
  assert.equal(replay.replayed, true);
  assert.equal(replay.code, "revision-conflict");
  assert.equal(replay.progress.revision, 1);
  const forged = await one(
    op("word-b", { supersedesOperationId: stale.operationId }),
  );
  assert.equal(forged.code, "invalid-rebase");
  // A restarted local sequence after explicit logout is compatible: sequence is
  // metadata, never a server clock or a global device ordering authority.
  const reset = await one(
    op("word-a", {
      baseRevision: 2,
      sequence: 1,
      desiredStatus: "already_know",
    }),
  );
  assert.equal(reset.code, "applied");
});

test("bounded mixed batches preserve earlier commits and stable IDs recover a partially failed request", async () => {
  const a = op(),
    b = op("word-b");
  await getFirestore()
    .doc(`users/${alice.uid}/progress/word-b`)
    .set({ schemaVersion: 999 });
  // Establish an otherwise valid state so the corrupt later word is the fault.
  await getFirestore()
    .doc(`users/${alice.uid}/syncState/progress`)
    .set({ schemaVersion: 1, revision: 1 });
  const failure = await call(upload(a, b));
  assert.equal(failure.status, 503);
  assert.equal(failure.body.code, "progress-state-invalid");
  assert.equal(
    (
      await getFirestore().doc(`users/${alice.uid}/progress/word-a`).get()
    ).data().revision,
    2,
  );
  await getFirestore().doc(`users/${alice.uid}/progress/word-b`).delete();
  const retry = await call(upload(a, b));
  assert.equal(retry.status, 200);
  assert.equal(retry.body.results[0].replayed, true);
  assert.equal(retry.body.results[1].progress.revision, 3);
  const mixed = await call(upload(op("word-a"), op("word-c")));
  assert.deepEqual(
    mixed.body.results.map((result) => result.code),
    ["revision-conflict", "applied"],
  );
});

test("ID-ordered pages are private, bounded and invalidated by concurrent progress changes", async () => {
  await call(upload(op("word-c"), op("word-a"), op("word-b")));
  const first = await call({ action: "list", limit: 2 });
  assert.equal(first.status, 200);
  assert.deepEqual(
    first.body.progress.map((row) => row.wordId),
    ["word-a", "word-b"],
  );
  assert.ok(first.body.nextCursor);
  const second = await call({
    action: "list",
    limit: 2,
    cursor: first.body.nextCursor,
  });
  assert.deepEqual(
    second.body.progress.map((row) => row.wordId),
    ["word-c"],
  );
  assert.equal(second.body.nextCursor, null);
  assert.match(second.body.progress[0].updatedAt, /Z$/);
  assert.equal(
    (await call({ action: "list", cursor: first.body.nextCursor }, bob.token))
      .body.code,
    "invalid-cursor",
  );
  assert.deepEqual(
    (await call({ action: "list" }, bob.token)).body.progress,
    [],
  );
  const original = first.body.progress[0];
  await one(
    op("word-a", {
      baseRevision: original.revision,
      desiredStatus: "learned",
      sequence: 2,
    }),
  );
  assert.equal(
    (await call({ action: "list", cursor: first.body.nextCursor })).body.code,
    "progress-snapshot-changed",
  );
  assert.equal((await call({ action: "list", limit: 101 })).status, 400);
});

test("draft, missing and retired words give the same safe terminal result; accepted history survives retirement", async () => {
  const acceptedOp = op();
  const accepted = await one(acceptedOp);
  const current = (await getFirestore().doc("words/word-a").get()).data();
  await content("word-a", "retire", current.revision);
  const draft = (await getFirestore().doc("words/word-b").get()).data();
  await content("word-b", "unpublish", draft.revision);
  for (const id of ["word-a", "word-b", "missing"])
    assert.equal((await one(op(id))).code, "word-unavailable");
  const replay = await one(acceptedOp);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.progress, accepted.progress);
  assert.equal((await call({ action: "list" })).body.progress.length, 1);
  const failed = op("word-b");
  assert.equal((await one(failed)).code, "word-unavailable");
  const unpublished = (await getFirestore().doc("words/word-b").get()).data();
  await content("word-b", "publish", unpublished.revision, { reviewed: true });
  assert.equal((await one(failed)).code, "word-unavailable");
  assert.equal(
    (await one({ ...failed, operationId: randomUUID() })).code,
    "applied",
  );
});

test("publication races serialize with progress writes and leave no inconsistent receipt/state", async () => {
  const revision = (await getFirestore().doc("words/word-a").get()).data()
    .revision;
  const [result] = await Promise.all([
    one(op()),
    content("word-a", "retire", revision),
  ]);
  assert.ok(["applied", "word-unavailable"].includes(result.code));
  const stored = await getFirestore()
    .doc(`users/${alice.uid}/progress/word-a`)
    .get();
  assert.equal(stored.exists, result.code === "applied");
  assert.equal(
    (await one(op("word-a", { baseRevision: result.progress?.revision ?? 0 })))
      .code,
    "word-unavailable",
  );
  assert.equal(
    (await getFirestore().doc("words/word-a").get()).data().isPublished,
    false,
  );
});

test("revoked/disabled sessions cannot retrieve or replay previously accepted operations", async () => {
  const disabled = await user("disabled");
  const command = op();
  await one(command, disabled.token);
  await getAuth().updateUser(disabled.uid, { disabled: true });
  assert.equal((await call(upload(command), disabled.token)).status, 401);
  assert.equal((await call({ action: "list" }, disabled.token)).status, 401);
  const revoked = await user("revoked");
  await one(op(), revoked.token);
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await getAuth().revokeRefreshTokens(revoked.uid);
  assert.equal(
    (await call({ action: "list" }, revoked.token)).body.code,
    "session-revoked",
  );
});

test("direct writes and private ledgers remain denied even to editor claims", async () => {
  await one(op());
  const own = env
    .authenticatedContext(alice.uid, { email_verified: true })
    .firestore();
  await assertSucceeds(getDoc(doc(own, `users/${alice.uid}/progress/word-a`)));
  const contexts = [
    env.unauthenticatedContext(),
    env.authenticatedContext(bob.uid),
    env.authenticatedContext("admin", { role: "super_admin" }),
  ];
  for (const context of contexts) {
    const db = context.firestore();
    await assertFails(getDoc(doc(db, `users/${alice.uid}/progress/word-a`)));
    await assertFails(
      setDoc(doc(db, `users/${alice.uid}/progress/word-a`), {
        status: "learned",
      }),
    );
    await assertFails(getDoc(doc(db, `users/${alice.uid}/syncState/progress`)));
    await assertFails(getDoc(doc(db, `users/${alice.uid}/syncOps/receipt`)));
  }
  await assertFails(
    setDoc(doc(own, `users/${alice.uid}/progress/word-a`), {
      status: "learned",
    }),
  );
  await assertFails(getDoc(doc(own, `users/${alice.uid}/syncOps/receipt`)));
});

test("request rate limits and corrupt/legacy state fail closed without extra progress writes", async () => {
  const db = getFirestore();
  const rate = db.doc(`progressRateLimits/${hash(alice.uid)}`);
  await rate.set({ window: Math.floor(Date.now() / 60000), count: 200 });
  assert.equal((await call(upload(op()))).status, 429);
  assert.equal(
    (await db.collection(`users/${alice.uid}/progress`).get()).size,
    0,
  );
  await rate.delete();
  await db.doc(`users/${alice.uid}/progress/word-c`).set({ status: "learned" });
  assert.equal(
    (await call({ action: "list" })).body.code,
    "progress-initialization-required",
  );
  assert.equal(
    (await call(upload(op()))).body.code,
    "progress-initialization-required",
  );
  assert.equal(
    (await db.collection(`users/${alice.uid}/syncOps`).get()).size,
    0,
  );
});
