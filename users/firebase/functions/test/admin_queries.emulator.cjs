const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const {
  initializeTestEnvironment,
  assertFails,
} = require("../../node_modules/@firebase/rules-unit-testing");
const {
  collection,
  query,
  where,
  orderBy,
  documentId,
  limit,
  startAfter,
  getDocs,
} = require("../../node_modules/firebase/firestore");
let app, env;
const fixtures = [];
before(async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST)
    throw new Error("Demo emulator required");
  app = initializeApp({ projectId: "demo-vocabulary" });
  env = await initializeTestEnvironment({ projectId: "demo-vocabulary" });
  const reset = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/demo-vocabulary/databases/(default)/documents`,
    { method: "DELETE" },
  );
  assert.ok(reset.ok);
  const batch = getFirestore().batch();
  for (let i = 0; i < 32; i++) {
    const id = `admin-query-${i.toString().padStart(2, "0")}`;
    const data = {
      spelling: i < 30 ? `Alpha ${i.toString().padStart(2, "0")}` : `beta ${i}`,
      pronunciation: "Synthetic fixture",
      category: i % 2 ? "advanced" : "basic",
      difficulty: i % 3 ? "medium" : "easy",
      ordering: i,
      isPublished: i % 3 === 0,
      isRetired: i % 3 === 1,
      revision: i + 1,
      senses: [],
    };
    fixtures.push({ id, ...data });
    batch.set(getFirestore().doc(`words/${id}`), data);
  }
  await batch.commit();
});
after(async () => {
  await env?.cleanup();
  await deleteApp(app);
});
function clauses(state, category, difficulty) {
  const fields = [];
  if (state === "published")
    fields.push(
      where("isPublished", "==", true),
      where("isRetired", "==", false),
    );
  if (state === "draft")
    fields.push(
      where("isPublished", "==", false),
      where("isRetired", "==", false),
    );
  if (state === "retired") fields.push(where("isRetired", "==", true));
  if (category) fields.push(where("category", "==", category));
  if (difficulty) fields.push(where("difficulty", "==", difficulty));
  return fields;
}
test("indexed Admin prefix/status/category/difficulty combinations return only matching records", async () => {
  const db = env
    .authenticatedContext("editor", { role: "content_manager" })
    .firestore();
  for (const state of ["all", "published", "draft", "retired"])
    for (const category of [null, "advanced"])
      for (const difficulty of [null, "medium"]) {
        const page = await getDocs(
          query(
            collection(db, "words"),
            ...clauses(state, category, difficulty),
            where("spelling", ">=", "Alpha"),
            where("spelling", "<", "Alphb"),
            orderBy("spelling"),
            orderBy(documentId()),
            limit(26),
          ),
        );
        const expected = fixtures
          .filter(
            (w) =>
              w.spelling.startsWith("Alpha") &&
              (!category || w.category === category) &&
              (!difficulty || w.difficulty === difficulty) &&
              (state === "all" ||
                (state === "published" && w.isPublished && !w.isRetired) ||
                (state === "draft" && !w.isPublished && !w.isRetired) ||
                (state === "retired" && w.isRetired)),
          )
          .slice(0, 26);
        assert.deepEqual(
          page.docs.map((d) => d.id),
          expected.map((w) => w.id),
        );
      }
  const lower = await getDocs(
    query(
      collection(db, "words"),
      where("spelling", ">=", "alpha"),
      where("spelling", "<", "alphb"),
      orderBy("spelling"),
      orderBy(documentId()),
      limit(26),
    ),
  );
  assert.equal(lower.size, 0);
});
test("bounded cursor pages preserve stable order and non-editors cannot use the Admin query", async () => {
  const db = env
    .authenticatedContext("super", { role: "super_admin" })
    .firestore();
  const collectionRef = collection(db, "words");
  const first = await getDocs(
    query(collectionRef, orderBy("spelling"), orderBy(documentId()), limit(26)),
  );
  assert.equal(first.size, 26);
  const displayed = first.docs.slice(0, 25);
  const second = await getDocs(
    query(
      collectionRef,
      orderBy("spelling"),
      orderBy(documentId()),
      startAfter(displayed.at(-1)),
      limit(26),
    ),
  );
  assert.equal(second.size, 7);
  const ids = [...displayed, ...second.docs].map((d) => d.id);
  assert.equal(new Set(ids).size, 32);
  for (const context of [
    env.unauthenticatedContext(),
    env.authenticatedContext("student", { role: "student" }),
  ]) {
    await assertFails(
      getDocs(
        query(
          collection(context.firestore(), "words"),
          orderBy("spelling"),
          orderBy(documentId()),
          limit(26),
        ),
      ),
    );
  }
});
