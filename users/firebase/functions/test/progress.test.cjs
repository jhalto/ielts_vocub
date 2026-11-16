const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  validateProgressRequest,
  encodeProgressCursor,
  decodeProgressCursor,
} = require("../lib/progress_validation");
const op = () => ({
  operationId: "op-1",
  deviceId: "device-1",
  wordId: "word-1",
  desiredStatus: "didnt_know",
  baseRevision: 0,
  sequence: 1,
});
const upload = (operation = op()) => ({
  action: "upload",
  operations: [operation],
});
const invalid = (body) =>
  assert.throws(
    () => validateProgressRequest(body),
    (error) => error.code === "invalid-input",
  );

test("existing outbox wire projection supports all three persisted statuses", () => {
  for (const desiredStatus of ["already_know", "learned", "didnt_know"]) {
    assert.equal(
      validateProgressRequest(upload({ ...op(), desiredStatus })).operations[0]
        .desiredStatus,
      desiredStatus,
    );
  }
  assert.equal(
    validateProgressRequest(upload({ ...op(), supersedesOperationId: "prior" }))
      .operations[0].supersedesOperationId,
    "prior",
  );
});
test("payload allowlists reject identity, timestamps, roles, unknown statuses and unsafe numbers", () => {
  invalid({ ...upload(), uid: "victim" });
  for (const extra of [
    { uid: "victim" },
    { role: "super_admin" },
    { createdAt: "tomorrow" },
    { revision: 10 },
    { desiredStatus: "learning" },
    { desiredStatus: null },
    { wordId: "a/b" },
    { operationId: "" },
    { deviceId: "../a" },
    { baseRevision: -1 },
    { baseRevision: 1.5 },
    { baseRevision: Number.MAX_SAFE_INTEGER },
    { sequence: 0 },
    { sequence: Infinity },
    { supersedesOperationId: "op-1" },
  ])
    invalid(upload({ ...op(), ...extra }));
});
test("bounded uploads validate the whole batch and reject duplicate IDs", () => {
  invalid({ action: "upload", operations: [] });
  invalid({
    action: "upload",
    operations: Array.from({ length: 26 }, (_, i) => ({
      ...op(),
      operationId: `op-${i}`,
    })),
  });
  assert.throws(
    () =>
      validateProgressRequest({ action: "upload", operations: [op(), op()] }),
    (error) => error.code === "duplicate-operation-id",
  );
  invalid({ ...upload(), limit: 1 });
});
test("retrieval limits and identity-bound versioned cursors are checked", () => {
  assert.deepEqual(validateProgressRequest({ action: "list" }), {
    action: "list",
    limit: 50,
  });
  for (const limit of [0, 101, 1.5, "10"]) invalid({ action: "list", limit });
  invalid({ action: "list", operations: [] });
  const cursor = encodeProgressCursor("alice", 4, "word-1");
  assert.equal(decodeProgressCursor("alice", cursor).revision, 4);
  for (const value of [
    cursor + "!",
    "x",
    Buffer.from(
      JSON.stringify({
        version: 2,
        owner: "x",
        revision: 4,
        afterWordId: "word-1",
      }),
    ).toString("base64url"),
  ]) {
    assert.throws(
      () => decodeProgressCursor("alice", value),
      (error) => error.code === "invalid-cursor",
    );
  }
  assert.throws(
    () => decodeProgressCursor("bob", cursor),
    (error) => error.code === "invalid-cursor",
  );
});
