const { test, before, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const {
  initializeTestEnvironment,
  assertFails,
} = require("../../node_modules/@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
} = require("../../node_modules/firebase/firestore");
const { canonical, hash } = require("../lib/content_validation");
const project = "demo-vocabulary",
  root = `http://127.0.0.1:15001/${project}/us-central1/`;
let app,
  env,
  manager,
  other,
  student,
  unverified,
  sequence = 0;
const content = (spelling = "Synthetic import fixture") => ({
  spelling,
  pronunciation: "test",
  category: "basic",
  difficulty: "easy",
  ordering: 0,
  senses: [
    {
      id: "sense",
      partOfSpeech: "noun",
      englishMeaning: "Synthetic fixture only",
      bengaliMeaning: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
      ordering: 0,
      examples: [
        { english: "First test", bengali: "\u09aa" },
        { english: "Second test", bengali: "\u09ac" },
      ],
    },
  ],
});
const create = (
  itemId = "one",
  wordId = "import-one",
  spelling = "Synthetic import fixture",
) => ({
  itemId,
  decision: "create",
  wordId,
  expectedRevision: 0,
  content: content(spelling),
});
const file = (...items) => ({ schemaVersion: 1, items });
const ref = (jobId, uid = manager.uid) =>
  getFirestore().doc(`importJobs/${hash(canonical([uid, jobId]))}`);
async function user(email, role, verified = true) {
  const auth = getAuth(),
    record = await auth.createUser({
      email,
      password: "Fixture-password-123!",
      emailVerified: verified,
    });
  await auth.setCustomUserClaims(record.uid, { role });
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
  const credentials = await response.json();
  assert.ok(credentials.idToken);
  return { uid: record.uid, token: credentials.idToken };
}
async function call(
  body,
  token = manager.token,
  api = "importApi",
  extra = {},
) {
  const response = await fetch(root + api, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(65000),
    ...extra,
  });
  return { status: response.status, body: await response.json() };
}
async function ok(body, token = manager.token, api = "importApi") {
  const response = await call(body, token, api);
  assert.equal(response.status, 200, JSON.stringify(response));
  return response.body;
}
const make = (jobId, ...items) =>
  ok({ action: "create", jobId, import: file(...items) });
const processItems = (jobId, ...itemIds) =>
  ok({ action: "process", jobId, itemIds });
async function mutate(wordId, action, expectedRevision, extra = {}) {
  return ok(
    {
      operationId: `import-fixture-${++sequence}`,
      wordId,
      action,
      expectedRevision,
      ...extra,
    },
    manager.token,
    "contentApi",
  );
}
async function invariants() {
  const db = getFirestore(),
    manifest = (await db.doc("contentManifest/current").get()).data();
  const words = (await db.collection("words").get()).docs.map((s) => s.data());
  const counts = {};
  for (const c of ["basic", "intermediate", "advanced"])
    for (const d of ["easy", "medium", "advanced"]) counts[`${c}/${d}`] = 0;
  for (const word of words)
    if (word.isPublished && !word.isRetired)
      counts[`${word.category}/${word.difficulty}`]++;
  assert.deepEqual(manifest.groupCounts, counts);
  assert.equal(
    manifest.totalPublished,
    Object.values(counts).reduce((a, b) => a + b, 0),
  );
  const changes = (
    await db.collection("contentChanges").orderBy("revision").get()
  ).docs.map((s) => s.data());
  assert.deepEqual(
    changes.map((s) => s.revision),
    Array.from({ length: manifest.currentRevision }, (_, i) => i + 1),
  );
  for (const change of changes) {
    assert.equal("senses" in change, false);
    if (change.action === "noop") assert.equal("wordId" in change, false);
  }
  assert.equal(
    (await db.collection("contentOperations").get()).size,
    manifest.currentRevision,
  );
  return manifest;
}
before(async () => {
  for (const key of [
    "FIRESTORE_EMULATOR_HOST",
    "FIREBASE_AUTH_EMULATOR_HOST",
  ]) {
    const value = process.env[key];
    if (!value) throw Error("Demo emulators required");
    const url = new URL(`http://${value}`);
    if (
      !["127.0.0.1", "localhost"].includes(url.hostname) ||
      !url.port ||
      url.username ||
      url.password ||
      url.pathname !== "/"
    )
      throw Error("Loopback emulators required");
  }
  if (!(process.env.GCLOUD_PROJECT ?? "").startsWith("demo-"))
    throw Error("Demo project required");
  app = initializeApp({ projectId: project });
  env = await initializeTestEnvironment({ projectId: project });
  manager = await user("import-manager@example.test", "content_manager");
  other = await user("import-other@example.test", "super_admin");
  student = await user("import-student@example.test", "student");
  unverified = await user(
    "import-unverified@example.test",
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
  if (app) await deleteApp(app);
});

test("only current verified editors can import; identities and job ownership cannot be injected", async () => {
  const input = { action: "preview", import: file(create()) };
  assert.equal((await call(input, null)).status, 401);
  assert.equal((await call(input, student.token)).status, 403);
  assert.equal(
    (await call(input, unverified.token)).body.code,
    "email-unverified",
  );
  assert.equal((await call({ ...input, uid: other.uid })).status, 400);
  await make("private-job", create());
  assert.equal(
    (await call({ action: "get", jobId: "private-job" }, other.token)).status,
    404,
  );
  assert.equal(
    (
      await call(
        { action: "process", jobId: "private-job", itemIds: ["one"] },
        other.token,
      )
    ).status,
    404,
  );
  const temporary = await user(
    "import-demoted@example.test",
    "content_manager",
  );
  await getAuth().setCustomUserClaims(temporary.uid, { role: "student" });
  assert.equal((await call(input, temporary.token)).status, 403);
  const disabled = await user(
    "import-disabled@example.test",
    "content_manager",
  );
  await getAuth().updateUser(disabled.uid, { disabled: true });
  assert.equal((await call(input, disabled.token)).status, 401);
  const stale = await user("import-stale@example.test", "content_manager");
  await getAuth().setCustomUserClaims(stale.uid, { role: "super_admin" });
  assert.equal((await call(input, stale.token)).body.code, "claims-stale");
  const revoked = await user("import-revoked@example.test", "content_manager");
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await getAuth().revokeRefreshTokens(revoked.uid);
  assert.equal((await call(input, revoked.token)).body.code, "session-revoked");
});
test("dry run reports row errors, normalized collisions and existing duplicates without jobs or publication writes", async () => {
  const original = await mutate("existing", "create", 0, {
    content: content("Existing spelling"),
  });
  const a = create("a", "a", " Existing SPELLING "),
    b = create("b", "b", "\uff26\uff29\uff38\uff34\uff35\uff32\uff25"),
    c = create("c", "c", "fixture");
  const invalid = { ...create("bad", "bad"), decision: "update" };
  const preview = await ok({
    action: "preview",
    import: file(a, b, c, invalid),
  });
  assert.equal(preview.valid, false);
  assert.ok(preview.items[0].errors.includes("duplicate-spelling"));
  assert.equal(preview.items[0].duplicateWordId, "existing");
  assert.ok(preview.items[1].errors.includes("duplicate-import-spelling"));
  assert.ok(preview.items[2].errors.includes("duplicate-import-spelling"));
  assert.ok(preview.items[3].errors.includes("update-revision-required"));
  const rejected = await call({
    action: "create",
    jobId: "invalid",
    import: file(a, b, c, invalid),
  });
  assert.equal(rejected.status, 422);
  assert.equal((await getFirestore().collection("importJobs").get()).size, 0);
  assert.equal((await invariants()).currentRevision, original.revision);
  assert.equal((await getFirestore().collection("adminAudit").get()).size, 1);
});
test("JSON type, schema, nested shape and file/item/batch limits are enforced", async () => {
  for (const action of ["toString", "constructor", "__proto__", "publish"]) {
    assert.equal((await call({ action })).status, 400);
  }
  assert.equal(
    (
      await call({
        action: "preview",
        import: { schemaVersion: 2, items: [create()] },
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await call({
        action: "preview",
        import: file(...Array(51).fill(create())),
      })
    ).body.code,
    "import-item-limit",
  );
  assert.equal(
    (
      await call({}, manager.token, "importApi", {
        headers: {
          Authorization: `Bearer ${manager.token}`,
          "Content-Type": "text/csv",
        },
        body: "word,meaning",
      })
    ).status,
    415,
  );
  assert.equal(
    (
      await call({
        action: "preview",
        import: {
          schemaVersion: 1,
          items: [
            {
              ...create(),
              content: { ...content(), spelling: "a".repeat(530000) },
            },
          ],
        },
      })
    ).status,
    413,
  );
  const bad = create();
  bad.content.senses[0].examples[0].isPublished = true;
  assert.equal(
    (await ok({ action: "preview", import: file(bad) })).valid,
    false,
  );
  await make("bounds", create());
  assert.equal(
    (
      await call({
        action: "process",
        jobId: "bounds",
        itemIds: Array(6).fill("one"),
      })
    ).body.code,
    "import-batch-limit",
  );
  assert.equal(
    (
      await call({
        action: "process",
        jobId: "bounds",
        itemIds: ["one", "missing"],
      })
    ).status,
    404,
  );
  assert.equal(
    (await getFirestore().doc("words/import-one").get()).exists,
    false,
  );
});
test("new imported words stay drafts, skip is durable, Unicode/order survive and direct writes remain denied", async () => {
  const data = await make("drafts", create(), {
    itemId: "skip",
    decision: "skip",
  });
  assert.deepEqual(data.counts, {
    total: 2,
    pending: 1,
    applied: 0,
    skipped: 1,
    failed: 0,
  });
  const done = await processItems("drafts", "one", "skip");
  assert.equal(done.status, "completed");
  const db = getFirestore(),
    word = (await db.doc("words/import-one").get()).data();
  assert.equal(word.isPublished, false);
  assert.equal(word.isRetired, false);
  assert.deepEqual(word.senses[0].examples, content().senses[0].examples);
  assert.equal((await invariants()).totalPublished, 0);
  const guest = env.unauthenticatedContext().firestore(),
    editor = env
      .authenticatedContext(manager.uid, { role: "content_manager" })
      .firestore();
  await assertFails(getDoc(doc(guest, "words/import-one")));
  await assertFails(getDoc(doc(guest, ref("drafts").path)));
  for (const client of [guest, editor]) {
    await assertFails(
      setDoc(doc(client, "words/bypass"), {
        ...content(),
        isPublished: false,
        isRetired: false,
        revision: word.revision,
      }),
    );
    await assertFails(
      setDoc(doc(client, ref("drafts").path), { status: "completed" }),
    );
    await assertFails(
      setDoc(doc(client, `${ref("drafts").path}/items/one`), {
        state: "applied",
      }),
    );
    await assertFails(getDoc(doc(client, `${ref("drafts").path}/items/one`)));
  }
  assert.equal(
    (
      await db
        .collection("adminAudit")
        .where("action", "==", "import_item_applied")
        .get()
    ).size,
    1,
  );
});
test("immutable job/item retries and concurrent processing cannot apply an item twice", async () => {
  const original = create();
  await make("retries", original);
  const results = await Promise.all([
    processItems("retries", "one"),
    processItems("retries", "one"),
  ]);
  assert.ok(results.every((x) => x.counts.applied === 1));
  const before = await invariants();
  assert.equal((await make("retries", original)).replayed, true);
  await processItems("retries", "one");
  assert.equal((await invariants()).currentRevision, before.currentRevision);
  assert.equal(
    (
      await call({
        action: "create",
        jobId: "retries",
        import: file({ ...original, content: content("Changed payload") }),
      })
    ).body.code,
    "import-job-id-reused",
  );
  assert.equal(
    (
      await call({
        action: "process",
        jobId: "retries",
        itemIds: ["one"],
        content: content(),
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await getFirestore()
        .collection("adminAudit")
        .where("action", "==", "import_item_applied")
        .get()
    ).size,
    1,
  );
});
test("interrupted job and lost acknowledgement resume from durable receipts with paginated status", async () => {
  await make(
    "resume",
    create("a", "a", "Fixture A"),
    create("b", "b", "Fixture B"),
    create("c", "c", "Fixture C"),
  );
  await processItems("resume", "a"); // completed request whose reply the caller can lose
  const first = await ok({ action: "get", jobId: "resume", limit: 1 });
  assert.equal(first.items[0].itemId, "a");
  assert.equal(first.items[0].state, "applied");
  assert.equal(first.nextAfterItemId, "a");
  const next = await ok({
    action: "get",
    jobId: "resume",
    limit: 1,
    afterItemId: first.nextAfterItemId,
  });
  assert.equal(next.items[0].itemId, "b");
  const done = await processItems("resume", "a", "b", "c");
  assert.equal(done.counts.applied, 3);
  assert.equal(done.status, "completed");
  assert.equal((await invariants()).currentRevision, 3);
  const last = await ok({ action: "get", jobId: "resume", afterItemId: "c" });
  assert.equal(last.nextAfterItemId, null);
  assert.deepEqual(last.items, []);
});
test("stale revisions fail one item without overwriting newer content or rolling back other successful items", async () => {
  const created = await mutate("existing", "create", 0, {
    content: content("Existing"),
  });
  const update = {
    ...create("update", "existing", "Imported replacement"),
    decision: "update",
    expectedRevision: created.revision,
  };
  await make("partial", update, create("new", "new", "Unrelated new fixture"));
  const newer = await mutate("existing", "edit", created.revision, {
    content: content("Newer editor intent"),
  });
  const result = await processItems("partial", "update", "new");
  assert.equal(result.status, "completed_with_errors");
  assert.equal(result.counts.failed, 1);
  assert.equal(result.counts.applied, 1);
  assert.equal(result.items[0].lastError.code, "revision-conflict");
  assert.equal(
    (await getFirestore().doc("words/existing").get()).data().spelling,
    "Newer editor intent",
  );
  assert.equal((await invariants()).currentRevision, newer.revision + 1);
  const retried = await processItems("partial", "update");
  assert.equal(retried.items[0].state, "failed");
  assert.equal(
    (
      await getFirestore()
        .collection("adminAudit")
        .where("action", "==", "import_item_failed")
        .get()
    ).size,
    1,
  );
});
test("concurrent jobs creating equivalent spellings preserve uniqueness and feed consistency", async () => {
  await make("first", create("one", "first", "Collision"));
  await make("second", create("one", "second", " COLLISION "));
  const results = await Promise.all([
    processItems("first", "one"),
    processItems("second", "one"),
  ]);
  assert.equal(
    results.reduce((n, x) => n + x.counts.applied, 0),
    1,
  );
  assert.equal(
    results.reduce((n, x) => n + x.counts.failed, 0),
    1,
  );
  const failure = results.find((x) => x.counts.failed);
  assert.equal(failure.items[0].lastError.code, "duplicate-spelling");
  assert.equal((await invariants()).currentRevision, 1);
});
test("published updates require explicit review, preserve IDs/progress and atomically move public counts", async () => {
  const created = await mutate("published", "create", 0, {
    content: content("Published fixture"),
  });
  const published = await mutate("published", "publish", created.revision, {
    reviewed: true,
  });
  const update = {
    ...create("update", "published", "Reviewed imported edit"),
    decision: "update",
    expectedRevision: published.revision,
  };
  const preview = await ok({ action: "preview", import: file(update) });
  assert.ok(preview.items[0].errors.includes("review-required"));
  update.reviewed = true;
  update.content.category = "intermediate";
  update.content.difficulty = "advanced";
  const progress = {
    wordId: "published",
    status: "learned",
    revision: 1,
    lastOperationId: "existing-progress",
  };
  await getFirestore()
    .doc("users/demo-import-learner/progress/published")
    .set(progress);
  await make("published-edit", update);
  await processItems("published-edit", "update");
  const word = (await getFirestore().doc("words/published").get()).data();
  assert.equal(word.isPublished, true);
  assert.deepEqual(
    (
      await getFirestore()
        .doc("users/demo-import-learner/progress/published")
        .get()
    ).data(),
    progress,
  );
  const manifest = await invariants();
  assert.equal(manifest.groupCounts["basic/easy"], 0);
  assert.equal(manifest.groupCounts["intermediate/advanced"], 1);
  assert.equal(
    (
      await getFirestore()
        .doc(
          `contentChanges/${String(manifest.currentRevision).padStart(16, "0")}`,
        )
        .get()
    ).data().action,
    "upsert",
  );
});
test("retirement after preview is a durable failure; restored content is never implicitly published", async () => {
  const created = await mutate("retired", "create", 0, {
    content: content("Retirement fixture"),
  });
  const update = {
    ...create("update", "retired", "Import against retired word"),
    decision: "update",
    expectedRevision: created.revision,
  };
  await make("retirement", update);
  const retired = await mutate("retired", "retire", created.revision);
  const failed = await processItems("retirement", "update");
  assert.equal(failed.items[0].state, "failed");
  const restored = await mutate("retired", "restore", retired.revision);
  await make("restored", { ...update, expectedRevision: restored.revision });
  await processItems("restored", "update");
  assert.equal(
    (await getFirestore().doc("words/retired").get()).data().isPublished,
    false,
  );
  await invariants();
});
test("receipt/audit failure rolls back publication and remains safely retryable", async () => {
  await make("atomic", create());
  const auditId = `import_${hash(canonical([manager.uid, "atomic", "one", "import_item_applied"]))}`;
  const collision = getFirestore().doc(`adminAudit/${auditId}`);
  await collision.set({ syntheticFault: true });
  const failed = await processItems("atomic", "one");
  assert.equal(failed.items[0].state, "pending");
  assert.equal(failed.items[0].lastError.retryable, true);
  assert.equal(
    (await getFirestore().doc("words/import-one").get()).exists,
    false,
  );
  assert.equal(
    (await getFirestore().doc("contentManifest/current").get()).exists,
    false,
  );
  assert.equal(
    (await getFirestore().collection("contentOperations").get()).size,
    0,
  );
  assert.equal((await ref("atomic").get()).data().counts.pending, 1);
  await collision.delete();
  assert.equal((await processItems("atomic", "one")).counts.applied, 1);
  assert.equal((await invariants()).currentRevision, 1);
});
test("per-editor request quota bounds dry runs and leaves publication untouched", async () => {
  const window = Math.floor(Date.now() / 60000);
  await getFirestore()
    .doc(`importRateLimits/${manager.uid}`)
    .set({ window, count: 60 });
  const response = await call({ action: "preview", import: file(create()) });
  assert.equal(response.status, 429);
  assert.equal(response.body.code, "rate-limited");
  assert.equal((await getFirestore().collection("words").get()).size, 0);
});
