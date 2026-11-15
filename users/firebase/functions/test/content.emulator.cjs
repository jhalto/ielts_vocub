const { test, before, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("../../node_modules/@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  getDocs,
  setDoc,
  deleteDoc,
  collection,
  query,
  where,
  orderBy,
  limit,
} = require("../../node_modules/firebase/firestore");
let app, env, manager, superadmin, student, unverified;
let sequence = 0;
const project = "demo-vocabulary";
const base = `http://127.0.0.1:15001/${project}/us-central1/contentApi`;
const content = (spelling = "Synthetic Fixture") => ({
  spelling,
  pronunciation: "fixture",
  category: "basic",
  difficulty: "easy",
  ordering: 0,
  senses: [
    {
      id: "sense-1",
      partOfSpeech: "noun",
      englishMeaning: "Synthetic test data only.",
      bengaliMeaning: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
      ordering: 0,
      examples: [
        {
          english: "Fixture only.",
          bengali: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
        },
      ],
    },
  ],
});
const operation = (wordId, action, expectedRevision, extra = {}) => ({
  wordId,
  action,
  expectedRevision,
  operationId: `publication-op-${++sequence}`,
  ...extra,
});
async function login(email) {
  const result = await fetch(
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
  const data = await result.json();
  assert.ok(data.idToken);
  return data.idToken;
}
async function user(email, role, verified = true) {
  const record = await getAuth().createUser({
    email,
    password: "Fixture-password-123!",
    emailVerified: verified,
  });
  if (role) await getAuth().setCustomUserClaims(record.uid, { role });
  return { uid: record.uid, token: await login(email), email };
}
async function call(body, token = manager.token) {
  const response = await fetch(base, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(35000),
  });
  return { status: response.status, body: await response.json() };
}
async function mutate(wordId, action, revision, extra = {}) {
  const response = await call(operation(wordId, action, revision, extra));
  assert.equal(response.status, 200, JSON.stringify(response));
  return response.body;
}
async function create(id = "word-1", data = content()) {
  return mutate(id, "create", 0, { content: data });
}
async function manifest() {
  return (await getFirestore().doc("contentManifest/current").get()).data();
}
async function invariants() {
  const db = getFirestore();
  const m = await manifest();
  const words = (await db.collection("words").get()).docs.map((x) => x.data());
  const counts = {};
  for (const c of ["basic", "intermediate", "advanced"])
    for (const d of ["easy", "medium", "advanced"]) counts[`${c}/${d}`] = 0;
  for (const word of words) {
    assert.ok(word.revision <= m.currentRevision);
    if (word.isPublished && !word.isRetired)
      counts[`${word.category}/${word.difficulty}`]++;
  }
  assert.deepEqual(m.groupCounts, counts);
  assert.equal(
    m.totalPublished,
    Object.values(counts).reduce((a, b) => a + b, 0),
  );
  const changes = (
    await db.collection("contentChanges").orderBy("revision").get()
  ).docs.map((x) => x.data());
  assert.deepEqual(
    changes.map((c) => c.revision),
    Array.from({ length: m.currentRevision }, (_, i) => i + 1),
  );
  assert.equal(
    (await db.collection("adminAudit").get()).size,
    m.currentRevision,
  );
  assert.equal(
    (await db.collection("contentOperations").get()).size,
    m.currentRevision,
  );
  for (const change of changes) {
    assert.equal("senses" in change, false);
    assert.equal("spelling" in change, false);
    if (change.action === "noop") assert.equal("wordId" in change, false);
  }
}
before(async () => {
  if (
    !process.env.FIREBASE_AUTH_EMULATOR_HOST ||
    !process.env.FIRESTORE_EMULATOR_HOST
  )
    throw new Error("Demo emulators required");
  app = initializeApp({ projectId: project });
  env = await initializeTestEnvironment({ projectId: project });
  manager = await user("publication-manager@example.test", "content_manager");
  superadmin = await user("publication-super@example.test", "super_admin");
  student = await user("publication-student@example.test", "student");
  unverified = await user(
    "publication-unverified@example.test",
    "content_manager",
    false,
  );
});
beforeEach(async () => {
  const response = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${project}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  assert.ok(response.ok);
});
after(async () => {
  await env?.cleanup();
  await deleteApp(app);
});
test("authentication, current claims, email verification and bounded input are enforced", async () => {
  const input = operation("denied", "create", 0, { content: content() });
  assert.equal((await call(input, null)).status, 401);
  assert.equal((await call(input, student.token)).status, 403);
  assert.equal(
    (await call(input, unverified.token)).body.code,
    "email-unverified",
  );
  const stale = await user("publication-stale@example.test", "content_manager");
  await getAuth().setCustomUserClaims(stale.uid, { role: "student" });
  assert.equal((await call(input, stale.token)).status, 403);
  const disabled = await user(
    "publication-disabled@example.test",
    "content_manager",
  );
  await getAuth().updateUser(disabled.uid, { disabled: true });
  assert.equal((await call(input, disabled.token)).status, 401);
  const revoked = await user(
    "publication-revoked@example.test",
    "content_manager",
  );
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await getAuth().revokeRefreshTokens(revoked.uid);
  assert.equal((await call(input, revoked.token)).body.code, "session-revoked");

  const forged = await user("publication-forged@example.test");
  await getFirestore().doc(`users/${forged.uid}`).set({ role: "super_admin" });
  assert.equal((await call(input, forged.token)).status, 403);
  assert.equal(
    (await call({ ...input, content: { ...content(), isPublished: true } }))
      .status,
    400,
  );
  assert.equal(
    (await call({ ...input, unexpected: "x".repeat(270000) })).status,
    413,
  );
  assert.equal((await getFirestore().collection("words").get()).size, 0);
  const allowed = await call(input, superadmin.token);
  assert.equal(allowed.status, 200);
  await invariants();
});
test("lifecycle creates private drafts, publishes reviewed content, and emits safe removal tombstones", async () => {
  let word = await create();
  let m = await manifest();
  assert.equal(m.schemaVersion, 1);
  assert.equal(Object.keys(m.groupCounts).length, 9);
  assert.equal(m.totalPublished, 0);
  const guest = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(guest, "words/word-1")));
  await assertSucceeds(getDoc(doc(guest, "contentChanges/0000000000000001")));
  assert.equal(
    (await call(operation("word-1", "publish", word.revision))).body.code,
    "review-required",
  );
  word = await mutate("word-1", "publish", word.revision, { reviewed: true });
  assert.equal((await manifest()).groupCounts["basic/easy"], 1);
  await assertSucceeds(getDoc(doc(guest, "words/word-1")));
  word = await mutate("word-1", "unpublish", word.revision);
  await assertFails(getDoc(doc(guest, "words/word-1")));
  assert.equal(
    (
      await getFirestore()
        .doc(`contentChanges/${String(word.revision).padStart(16, "0")}`)
        .get()
    ).data().action,
    "remove",
  );
  word = await mutate("word-1", "publish", word.revision, { reviewed: true });
  word = await mutate("word-1", "retire", word.revision);
  assert.equal(word.isRetired, true);
  assert.equal((await manifest()).totalPublished, 0);
  assert.equal(
    (
      await call(
        operation("word-1", "publish", word.revision, { reviewed: true }),
      )
    ).body.code,
    "word-retired",
  );
  word = await mutate("word-1", "restore", word.revision);
  assert.equal(word.isPublished, false);
  assert.equal(word.isRetired, false);
  await mutate("word-1", "publish", word.revision, { reviewed: true });
  await invariants();
});
test("incomplete drafts cannot publish; published edits require review and atomically move group counts", async () => {
  const draft = { ...content(), pronunciation: "", senses: [] };
  let word = await create("word-1", draft);
  assert.equal(
    (
      await call(
        operation("word-1", "publish", word.revision, { reviewed: true }),
      )
    ).body.code,
    "publication-incomplete",
  );
  word = await mutate("word-1", "edit", word.revision, { content: content() });
  word = await mutate("word-1", "publish", word.revision, { reviewed: true });
  const changed = {
    ...content("Changed Fixture"),
    category: "advanced",
    difficulty: "advanced",
  };
  assert.equal(
    (
      await call(
        operation("word-1", "edit", word.revision, { content: changed }),
      )
    ).body.code,
    "review-required",
  );
  await mutate("word-1", "edit", word.revision, {
    content: changed,
    reviewed: true,
  });
  assert.equal((await manifest()).groupCounts["basic/easy"], 0);
  assert.equal((await manifest()).groupCounts["advanced/advanced"], 1);
  await invariants();
});
test("lost-response retries are idempotent and changed operation payloads are rejected", async () => {
  const request = operation("word-1", "create", 0, { content: content() });
  const [one, two] = await Promise.all([call(request), call(request)]);
  assert.equal(one.status, 200);
  assert.equal(two.status, 200);
  assert.equal(one.body.revision, two.body.revision);
  assert.equal([one, two].filter((r) => r.body.replayed).length, 1);
  const replay = await call({ ...request, content: { ...request.content } });
  assert.equal(replay.body.replayed, true);
  assert.equal(
    (await call({ ...request, content: content("Different") })).body.code,
    "operation-id-reused",
  );
  assert.equal((await manifest()).currentRevision, 1);
  await invariants();
});
test("concurrent same-word editors cannot overwrite a committed revision", async () => {
  const word = await create();
  const results = await Promise.all(
    ["Edit A", "Edit B"].map((spelling) =>
      call(
        operation("word-1", "edit", word.revision, {
          content: content(spelling),
        }),
      ),
    ),
  );
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
  assert.equal(
    results.find((r) => r.status === 409).body.code,
    "revision-conflict",
  );
  await invariants();
});
test("normalized spelling registry handles concurrent duplicates and atomic rename release", async () => {
  const requests = [
    operation("one", "create", 0, { content: content("TEST") }),
    operation("two", "create", 0, {
      content: content(" \uff34\uff25\uff33\uff34 "),
    }),
  ];
  const results = await Promise.all(requests.map((x) => call(x)));
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
  assert.equal(
    results.find((r) => r.status === 409).body.code,
    "duplicate-spelling",
  );
  let winner = results.find((r) => r.status === 200).body;
  winner = await mutate(winner.wordId, "edit", winner.revision, {
    content: content("Renamed"),
  });
  await create("released", content("test"));
  await mutate(winner.wordId, "retire", winner.revision);
  assert.equal(
    (
      await call(
        operation("third", "create", 0, { content: content("renamed") }),
      )
    ).body.code,
    "duplicate-spelling",
  );
  await invariants();
});
test("distinct concurrent publications preserve revision continuity and exact aggregate counts", async () => {
  const words = [];
  for (let i = 0; i < 4; i++)
    words.push(await create(`group-${i}`, content(`Fixture ${i}`)));
  const published = await Promise.all(
    words.map((w) =>
      call(operation(w.wordId, "publish", w.revision, { reviewed: true })),
    ),
  );
  for (const result of published)
    assert.equal(result.status, 200, JSON.stringify(result));
  assert.equal((await manifest()).totalPublished, 4);
  await invariants();
});
test("guests cannot read drafts or private metadata and no role can bypass the publication function", async () => {
  const word = await create();
  const guest = env.unauthenticatedContext().firestore();
  await assertFails(getDocs(collection(guest, "words")));
  await assertSucceeds(
    getDocs(
      query(
        collection(guest, "words"),
        where("isPublished", "==", true),
        where("isRetired", "==", false),
        orderBy("__name__"),
        limit(100),
      ),
    ),
  );
  for (const context of [
    env.unauthenticatedContext(),
    env.authenticatedContext("student", { role: "student" }),
    env.authenticatedContext("manager", { role: "content_manager" }),
    env.authenticatedContext("super", { role: "super_admin" }),
  ]) {
    const db = context.firestore();
    for (const path of [
      "words/word-1",
      "contentManifest/current",
      "contentChanges/new",
      "wordSpellings/key",
      "contentOperations/key",
      "contentRateLimits/key",
    ]) {
      await assertFails(
        setDoc(doc(db, path), { isPublished: true, revision: 999 }),
      );
      await assertFails(deleteDoc(doc(db, path)));
    }
    for (const path of [
      "wordSpellings/key",
      "contentOperations/key",
      "contentRateLimits/key",
    ])
      await assertFails(getDoc(doc(db, path)));
  }
  const changes = (
    await getFirestore().collection("contentChanges").get()
  ).docs.map((d) => d.data());
  assert.equal(JSON.stringify(changes).includes(word.wordId), false);
  await invariants();
});
test("unmanaged content or incompatible manifests require explicit migration instead of fabricated totals", async () => {
  await getFirestore()
    .doc("words/legacy")
    .set({ ...content(), isPublished: true, isRetired: false, revision: 1 });
  assert.equal(
    (await call(operation("new", "create", 0, { content: content("New") })))
      .body.code,
    "initialization-required",
  );
  assert.equal(
    (await getFirestore().doc("contentManifest/current").get()).exists,
    false,
  );
  await getFirestore()
    .doc("contentManifest/current")
    .set({
      schemaVersion: 1,
      currentRevision: 1,
      groupCounts: { "basic/easy": 1 },
    });
  assert.equal(
    (await call(operation("new", "create", 0, { content: content("New") })))
      .body.code,
    "initialization-required",
  );
  assert.equal(
    (await getFirestore().collection("contentChanges").get()).size,
    0,
  );
});

test("exports a real published snapshot for the unchanged Dart download contract", async () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const one = await create("contract-basic", content("Contract Basic Fixture"));
  await mutate(one.wordId, "publish", one.revision, { reviewed: true });
  const two = await create("contract-advanced", {
    ...content("Contract Advanced Fixture"),
    category: "advanced",
    difficulty: "advanced",
  });
  await mutate(two.wordId, "publish", two.revision, { reviewed: true });
  const guest = env.unauthenticatedContext().firestore();
  const downloaded = await getDocs(
    query(
      collection(guest, "words"),
      where("isPublished", "==", true),
      where("isRetired", "==", false),
      orderBy("__name__"),
      limit(100),
    ),
  );
  const fixture = {
    manifest: await manifest(),
    words: downloaded.docs.map((doc) => ({ id: doc.id, ...doc.data() })),
  };
  const target = path.resolve(
    __dirname,
    "../../../.dart_tool/phase3-publication-contract.json",
  );
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(fixture));
  await invariants();
});

test("corrupt counts and rate limits fail closed without partial publication writes", async () => {
  let word = await create();
  const db = getFirestore();
  const manifestRef = db.doc("contentManifest/current");
  const original = await manifest();
  await manifestRef.update({
    groupCounts: { ...original.groupCounts, "basic/easy": -1 },
  });
  assert.equal(
    (
      await call(
        operation(word.wordId, "publish", word.revision, { reviewed: true }),
      )
    ).body.code,
    "content-state-invalid",
  );
  assert.equal((await db.collection("contentChanges").get()).size, 1);
  assert.equal(
    (await db.doc(`words/${word.wordId}`).get()).data().isPublished,
    false,
  );
  await manifestRef.set(original);
  await db
    .doc(`contentRateLimits/${manager.uid}`)
    .set({ window: Math.floor(Date.now() / 60000), count: 60 });
  assert.equal(
    (
      await call(
        operation(word.wordId, "publish", word.revision, { reviewed: true }),
      )
    ).status,
    429,
  );
  assert.equal((await manifest()).currentRevision, 1);
});
