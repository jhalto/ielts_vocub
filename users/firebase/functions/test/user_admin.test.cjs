const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  validateUserRequest,
  encodeUserCursor,
  decodeUserCursor,
  operationKey,
} = require("../lib/user_admin_validation");
const { managedTokenMatches } = require("../lib/managed_access");
const { userStateFingerprint } = require("../lib/user_admin");
const mutation = () => ({
  action: "setRole",
  operationId: "operation-one",
  targetUid: "target",
  expectedRevision: 0,
  expectedState: "a".repeat(64),
  confirmed: true,
  reason: "Reviewed access request",
  role: "content_manager",
});
test("user mutations require explicit allowed role, state, revision, confirmation and bounded reason", () => {
  const input = mutation();
  assert.equal(validateUserRequest(input).role, "content_manager");
  for (const edit of [
    (x) => (x.role = "owner"),
    (x) => (x.confirmed = false),
    (x) => (x.reason = "no"),
    (x) => (x.reason = "x".repeat(501)),
    (x) => (x.reason = "bad\u0000reason"),
    (x) => (x.expectedRevision = -1),
    (x) => (x.expectedRevision = 0.1),
    (x) => (x.expectedState = "x"),
    (x) => (x.targetUid = "../bad"),
    (x) => (x.uid = "actor"),
    (x) => (x.disabled = true),
    (x) => (x.operationId = ""),
  ]) {
    const value = mutation();
    edit(value);
    assert.throws(() => validateUserRequest(value));
  }
});
test("enable/disable is explicit and cannot carry arbitrary account or claims updates", () => {
  const input = { ...mutation(), action: "setDisabled", disabled: true };
  delete input.role;
  assert.equal(validateUserRequest(input).disabled, true);
  for (const extra of [
    { customClaims: { role: "super_admin" } },
    { password: "secret" },
    { disabled: "true" },
    { delete: true },
  ])
    assert.throws(() => validateUserRequest({ ...input, ...extra }));
});
test("directory lookup supports one exact identity and bounded explicit page filters only", () => {
  assert.deepEqual(validateUserRequest({ action: "get", uid: "user" }), {
    action: "get",
    uid: "user",
  });
  assert.equal(
    validateUserRequest({ action: "get", email: "fixture@example.test" }).email,
    "fixture@example.test",
  );
  assert.equal(
    validateUserRequest({
      action: "list",
      limit: 100,
      filters: {
        role: "student",
        disabled: false,
        verified: true,
        provider: "google.com",
      },
    }).limit,
    100,
  );
  for (const body of [
    { action: "get" },
    { action: "get", uid: "user", email: "fixture@example.test" },
    { action: "list", search: "arbitrary" },
    { action: "list", limit: 101 },
    { action: "list", filters: { prefix: "name" } },
    { action: "list", filters: { verified: "true" } },
    { action: "list", filters: { role: "other" } },
    { action: "constructor" },
  ])
    assert.throws(() => validateUserRequest(body));
});
test("directory cursor binds actor, filters and limit and is never an authorization credential", () => {
  const value = encodeUserCursor("actor", 25, { disabled: false }, "sdk-page");
  assert.equal(
    decodeUserCursor("actor", 25, { disabled: false }, value),
    "sdk-page",
  );
  for (const args of [
    ["other", 25, { disabled: false }, value],
    ["actor", 100, { disabled: false }, value],
    ["actor", 25, { disabled: true }, value],
    ["actor", 25, {}, "bad"],
  ])
    assert.throws(() => decodeUserCursor(...args));
});
test("operation identities are durable and namespaced by verified actor", () => {
  assert.equal(operationKey("actor", "op"), operationKey("actor", "op"));
  assert.notEqual(operationKey("actor", "op"), operationKey("other", "op"));
  assert.notEqual(operationKey("actor", "op"), operationKey("actor", "other"));
  assert.equal(
    validateUserRequest({ action: "resume", operationKey: "a".repeat(64) })
      .action,
    "resume",
  );
  assert.throws(() =>
    validateUserRequest({ action: "resume", operationKey: "../escape" }),
  );
});
test("managed access denies pending, disabled, stale and role-mismatched tokens while supporting version-zero bootstrap", () => {
  const token = { uid: "user", role: "super_admin" },
    state = {
      schemaVersion: 1,
      uid: "user",
      role: "super_admin",
      revision: 0,
      disabled: false,
      pendingOperation: null,
    };
  assert.equal(managedTokenMatches(token, state), true);
  for (const change of [
    { pendingOperation: "op" },
    { disabled: true },
    { revision: 1 },
    { role: "student" },
    { uid: "other" },
    { schemaVersion: 2 },
  ])
    assert.equal(managedTokenMatches(token, { ...state, ...change }), false);
  assert.equal(
    managedTokenMatches(
      { ...token, adminRevision: 2 },
      { ...state, revision: 2 },
    ),
    true,
  );
  assert.equal(
    managedTokenMatches(
      { ...token, adminRevision: 2, auth_time: 9 },
      { ...state, revision: 2, minAuthTime: 10 },
    ),
    false,
  );
  assert.equal(
    managedTokenMatches(
      { ...token, adminRevision: 2, auth_time: 10 },
      { ...state, revision: 2, minAuthTime: 10 },
    ),
    true,
  );
});
test("Auth state fingerprint includes security claims, eligibility, disabled state and account incarnation", () => {
  const user = {
    uid: "user",
    disabled: false,
    emailVerified: true,
    customClaims: { role: "student", extra: "keep" },
    metadata: { creationTime: "date" },
  };
  const value = userStateFingerprint(user);
  assert.equal(
    value,
    userStateFingerprint({ ...user, displayName: "Updated profile" }),
  );
  for (const change of [
    { disabled: true },
    { emailVerified: false },
    { customClaims: { role: "student", extra: "changed" } },
    { metadata: { creationTime: "new-date" } },
  ])
    assert.notEqual(value, userStateFingerprint({ ...user, ...change }));
});
