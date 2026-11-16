const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { resolve } = require("node:path");
const { randomUUID } = require("node:crypto");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");

test("real Dart client synchronizes only disposable demo accounts/databases", async () => {
  if (
    !process.env.FIRESTORE_EMULATOR_HOST ||
    !process.env.FIREBASE_AUTH_EMULATOR_HOST ||
    !(process.env.GCLOUD_PROJECT ?? "").startsWith("demo-")
  )
    throw new Error("Demo emulators required");
  const projectId = "demo-vocabulary";
  const app = initializeApp({ projectId });
  try {
    const reset = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: "DELETE" },
    );
    assert.ok(reset.ok);
    async function account(name, role) {
      const email = `client-probe-${name}@example.test`;
      const user = await getAuth().createUser({
        email,
        emailVerified: true,
        password: "Fixture-password-123!",
      });
      if (role) await getAuth().setCustomUserClaims(user.uid, { role });
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
      const result = await response.json();
      assert.ok(result.idToken);
      return { uid: user.uid, token: result.idToken };
    }
    const editor = await account("editor", "content_manager"),
      student = await account("student"),
      bob = await account("bob");
    const base = `http://127.0.0.1:15001/${projectId}/us-central1`;
    const words = [];
    for (const [ordering, id] of [
      "client-a",
      "client-b",
      "client-c",
    ].entries()) {
      async function mutate(action, expectedRevision, extra = {}) {
        const response = await fetch(`${base}/contentApi`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${editor.token}`,
          },
          body: JSON.stringify({
            operationId: randomUUID(),
            wordId: id,
            action,
            expectedRevision,
            ...extra,
          }),
        });
        const data = await response.json();
        assert.equal(response.status, 200, JSON.stringify(data));
        return data;
      }
      const draft = await mutate("create", 0, {
        content: {
          spelling: `Synthetic client fixture ${id}`,
          pronunciation: "test",
          category: "basic",
          difficulty: "easy",
          ordering,
          senses: [
            {
              id: "sense",
              partOfSpeech: "noun",
              englishMeaning: "Test fixture only",
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
      await mutate("publish", draft.revision, { reviewed: true });
      words.push({
        id,
        ...(await getFirestore().doc(`words/${id}`).get()).data(),
      });
    }
    const fixture = {
      projectId,
      endpoint: `${base}/progressApi`,
      uid: student.uid,
      token: student.token,
      bobUid: bob.uid,
      bobToken: bob.token,
      words,
      manifest: (
        await getFirestore().doc("contentManifest/current").get()
      ).data(),
    };
    const result = spawnSync(
      process.env.VOCAB_DART_BIN ?? "dart",
      ["run", "test/progress_emulator_probe.dart"],
      {
        cwd: resolve(__dirname, "../../../packages/local_learning"),
        input: JSON.stringify(fixture),
        encoding: "utf8",
        timeout: 180000,
        env: process.env,
      },
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /PASS: real HTTPS client/);
    process.stdout.write(result.stdout);
  } finally {
    await deleteApp(app);
  }
});
