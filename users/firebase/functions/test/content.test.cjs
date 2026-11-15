const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  validateMutation,
  requirePublishable,
  normalizeSpelling,
  canonical,
  emptyCounts,
} = require("../lib/content_validation");
const content = () => ({
  spelling: " Test ",
  pronunciation: "test",
  category: "advanced",
  difficulty: "advanced",
  ordering: 0,
  senses: [0, 1].map((i) => ({
    id: `sense-${i}`,
    partOfSpeech: "noun",
    englishMeaning: `Synthetic fixture ${i}`,
    bengaliMeaning: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
    ordering: i,
    examples: [
      {
        english: "Test fixture only.",
        bengali: "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
      },
    ],
  })),
});
const mutation = () => ({
  operationId: "op-1",
  wordId: "word-1",
  action: "create",
  expectedRevision: 0,
  content: content(),
});
const rejects = (body, code = "invalid-input") =>
  assert.throws(
    () => validateMutation(body),
    (error) => error.code === code,
  );
test("validation preserves bilingual pairs, repeated POS, ordering and separate advanced enums", () => {
  const result = validateMutation(mutation());
  assert.equal(result.content.senses.length, 2);
  assert.equal(
    result.content.senses[0].bengaliMeaning,
    "\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be",
  );
  assert.equal(result.content.category, "advanced");
  assert.equal(result.content.difficulty, "advanced");
  assert.equal(result.content.spelling, "Test");
  assert.doesNotThrow(() => requirePublishable(result.content, true));
});
test("invalid wire values, IDs, revisions and server field injection are rejected", () => {
  for (const edit of [
    (x) => (x.wordId = "../escape"),
    (x) => (x.operationId = ""),
    (x) => (x.expectedRevision = 0.5),
    (x) => (x.expectedRevision = -1),
    (x) => (x.role = "super_admin"),
    (x) => (x.content.revision = 999),
    (x) => (x.content.isPublished = true),
    (x) => (x.content.category = "expert"),
    (x) => (x.content.difficulty = "basic"),
    (x) => (x.content.senses[0].partOfSpeech = "other"),
    (x) => (x.reviewed = "yes"),
  ]) {
    const x = mutation();
    edit(x);
    rejects(x);
  }
  const x = mutation();
  x.expectedRevision = 1;
  rejects(x, "create-revision-must-be-zero");
});
test("sense identity/order and nested schema are enforced", () => {
  const x = mutation();
  x.content.senses[1].id = "sense-0";
  rejects(x, "duplicate-sense-id");
  const y = mutation();
  y.content.senses[1].ordering = 0;
  rejects(y, "invalid-sense-order");
  const z = mutation();
  z.content.senses[0].examples[0].translation = "extra";
  rejects(z);
});
test("drafts may be incomplete but publishing requires explicit review and complete bilingual content", () => {
  const x = mutation();
  x.content.pronunciation = "";
  x.content.senses = [];
  const draft = validateMutation(x);
  assert.throws(
    () => requirePublishable(draft.content, true),
    (e) => e.code === "publication-incomplete",
  );
  assert.throws(
    () => requirePublishable(content(), false),
    (e) => e.code === "review-required",
  );
  const incomplete = content();
  incomplete.senses[0].examples[0].bengali = "";
  assert.throws(
    () => requirePublishable(incomplete, true),
    (e) => e.code === "publication-incomplete",
  );
});
test("Unicode and size limits reject malformed/control/excessive text without corrupting valid Unicode", () => {
  for (const spelling of ["\ud800", "bad\u0000text", "x".repeat(129)]) {
    const x = mutation();
    x.content.spelling = spelling;
    rejects(x);
  }
  const x = mutation();
  x.content.senses[0].englishMeaning = "e\u0301 \ud83d\ude00";
  assert.equal(
    validateMutation(x).content.senses[0].englishMeaning,
    "\u00e9 \ud83d\ude00",
  );
  const huge = mutation();
  huge.content.senses[0].englishMeaning = "x".repeat(200000);
  rejects(huge, "payload-too-large");
});
test("normalization, canonical retry fingerprint and nine zero groups are deterministic", () => {
  assert.equal(
    normalizeSpelling("  \uff34\uff25\uff33\uff34  Word "),
    "test word",
  );
  assert.equal(normalizeSpelling("E\u0301"), normalizeSpelling("\u00c9"));
  assert.equal(canonical({ b: 2, a: [1, 2] }), canonical({ a: [1, 2], b: 2 }));
  assert.notEqual(canonical([1, 2]), canonical([2, 1]));
  assert.equal(Object.keys(emptyCounts()).length, 9);
});
