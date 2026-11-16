const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  importRows,
  planFingerprint,
  importOperationId,
  boundedIds,
} = require("../lib/import_validation");
const content = () => ({
  spelling: " Fixture ",
  pronunciation: "test",
  category: "basic",
  difficulty: "easy",
  ordering: 0,
  senses: [0, 1].map((i) => ({
    id: `sense-${i}`,
    partOfSpeech: "noun",
    englishMeaning: "e\u0301",
    bengaliMeaning: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
    ordering: i,
    examples: [
      { english: "First", bengali: "\u09aa" },
      { english: "Second", bengali: "\u09ac" },
    ],
  })),
});
const row = (itemId = "one", wordId = "word-one") => ({
  itemId,
  decision: "create",
  wordId,
  expectedRevision: 0,
  content: content(),
});
const file = (...items) => ({ schemaVersion: 1, items });
test("import preserves normalized bilingual senses and ordered example pairs", () => {
  const [value] = importRows(file(row()));
  assert.deepEqual(value.errors, []);
  assert.equal(value.mutation.content.spelling, "Fixture");
  assert.equal(value.mutation.content.senses.length, 2);
  assert.equal(value.mutation.content.senses[0].englishMeaning, "\u00e9");
  assert.deepEqual(
    value.mutation.content.senses[1].examples.map((x) => x.english),
    ["First", "Second"],
  );
  assert.equal(value.publishable, true);
});
test("incomplete drafts are valid but identified as unpublishable", () => {
  const item = row();
  item.content.senses = [];
  item.content.pronunciation = "";
  const [value] = importRows(file(item));
  assert.deepEqual(value.errors, []);
  assert.equal(value.publishable, false);
});
test("nested publication flags, invalid enums, Unicode and example fields produce row errors", () => {
  for (const edit of [
    (x) => (x.content.isPublished = true),
    (x) => (x.content.category = "expert"),
    (x) => (x.content.spelling = "\ud800"),
    (x) => (x.content.senses[0].examples[0].role = "super_admin"),
    (x) => (x.content.senses[1].ordering = 0),
    (x) => (x.content.senses[1].id = "sense-0"),
    (x) => (x.uid = "other"),
    (x) => (x.reviewed = true),
  ]) {
    const item = row();
    edit(item);
    assert.ok(importRows(file(item))[0].errors.length);
  }
});
test("duplicate item IDs, target IDs and normalized spellings flag every colliding row", () => {
  const a = row(),
    b = row("two", "word-two");
  b.content.spelling = "\uff26\uff29\uff38\uff34\uff35\uff32\uff25";
  assert.ok(
    importRows(file(a, b)).every((x) =>
      x.errors.includes("duplicate-import-spelling"),
    ),
  );
  const c = row("one", "word-three");
  c.content.spelling = "Other";
  assert.ok(
    importRows(file(a, c)).every((x) => x.errors.includes("duplicate-item-id")),
  );
  const d = row("four");
  d.content.spelling = "Different";
  assert.ok(
    importRows(file(a, d)).every((x) =>
      x.errors.includes("duplicate-import-word-id"),
    ),
  );
});
test("skip is explicit and cannot smuggle malformed content or another decision", () => {
  assert.deepEqual(
    importRows(file({ itemId: "skip", decision: "skip" }))[0].errors,
    [],
  );
  assert.ok(
    importRows(file({ ...row(), decision: "skip" }))[0].errors.includes(
      "skip-must-omit-content",
    ),
  );
  assert.ok(importRows(file({ ...row(), decision: "auto" }))[0].errors.length);
});
test("create and update require safe explicit revision preconditions", () => {
  for (const expectedRevision of [1, -1, 0.5, "0"])
    assert.ok(
      importRows(file({ ...row(), expectedRevision }))[0].errors.length,
    );
  assert.ok(
    importRows(file({ ...row(), decision: "update" }))[0].errors.includes(
      "update-revision-required",
    ),
  );
  assert.deepEqual(
    importRows(
      file({
        ...row(),
        decision: "update",
        expectedRevision: 1,
        reviewed: true,
      }),
    )[0].errors,
    [],
  );
});
test("document, item and processing bounds reject oversized or unsupported inputs", () => {
  for (const value of [
    "csv",
    { schemaVersion: 2, items: [row()] },
    file(),
    file(...Array(51).fill(row())),
    { ...file(row()), role: "admin" },
  ])
    assert.throws(() => importRows(value));
  assert.throws(
    () =>
      importRows(
        file({
          ...row(),
          content: { ...content(), spelling: "a".repeat(530000) },
        }),
      ),
    (e) => e.status === 413,
  );
  const huge = row();
  huge.content.senses[0].englishMeaning = "x".repeat(200000);
  assert.ok(importRows(file(huge))[0].errors.includes("payload-too-large"));
  for (const ids of [[], Array(6).fill("id"), ["id", "id"], ["../escape"]])
    assert.throws(() => boundedIds(ids));
  assert.deepEqual(boundedIds(["a", "b"]), ["a", "b"]);
});
test("normalized plan and namespaced operation fingerprints are immutable and deterministic", () => {
  const a = row(),
    b = row();
  b.content.spelling = "Fixture";
  assert.equal(
    planFingerprint(importRows(file(a))),
    planFingerprint(importRows(file(b))),
  );
  b.content.senses[0].examples.reverse();
  assert.notEqual(
    planFingerprint(importRows(file(a))),
    planFingerprint(importRows(file(b))),
  );
  const id = importOperationId("uid", "job", "item");
  assert.equal(id, importOperationId("uid", "job", "item"));
  for (const args of [
    ["other", "job", "item"],
    ["uid", "other", "item"],
    ["uid", "job", "other"],
  ])
    assert.notEqual(id, importOperationId(...args));
});
