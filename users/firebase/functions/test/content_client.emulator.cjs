const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { resolve } = require("node:path");
const { randomUUID } = require("node:crypto");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");

test("real content client reconciles only public demo feed into temporary SQLite", async () => {
  const isLoopback = (host) => {
    if (typeof host !== "string") return false;
    try {
      const url = new URL(`http://${host}`);
      return (
        ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) &&
        url.port !== "" &&
        url.username === "" &&
        url.password === "" &&
        url.pathname === "/"
      );
    } catch {
      return false;
    }
  };
  if (
    !isLoopback(process.env.FIRESTORE_EMULATOR_HOST) ||
    !isLoopback(process.env.FIREBASE_AUTH_EMULATOR_HOST) ||
    !(process.env.GCLOUD_PROJECT ?? "").startsWith("demo-")
  )
    throw new Error("Demo emulators required");
  const projectId = "demo-vocabulary",
    app = initializeApp({ projectId });
  try {
    const reset = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: "DELETE" },
    );
    assert.ok(reset.ok);
    const email = "content-client-editor@example.test";
    const editor = await getAuth().createUser({
      email,
      emailVerified: true,
      password: "Fixture-password-123!",
    });
    await getAuth().setCustomUserClaims(editor.uid, {
      role: "content_manager",
    });
    const login = await fetch(
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
    const credentials = await login.json();
    assert.ok(credentials.idToken);
    const publicationEndpoint = `http://127.0.0.1:15001/${projectId}/us-central1/contentApi`;
    for (const [index, category] of [
      "basic",
      "intermediate",
      "advanced",
    ].entries()) {
      const wordId = `content-${String.fromCharCode(97 + index)}`;
      async function mutate(action, expectedRevision, extra = {}) {
        const response = await fetch(publicationEndpoint, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${credentials.idToken}`,
          },
          body: JSON.stringify({
            operationId: randomUUID(),
            wordId,
            action,
            expectedRevision,
            ...extra,
          }),
        });
        const result = await response.json();
        assert.equal(response.status, 200, JSON.stringify(result));
        return result;
      }
      const draft = await mutate("create", 0, {
        content: {
          spelling: `Synthetic ${wordId}`,
          pronunciation: "test",
          category,
          difficulty: "easy",
          ordering: index,
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
    }
    const result = spawnSync(
      process.env.VOCAB_DART_BIN ?? "dart",
      ["run", "test/content_emulator_probe.dart"],
      {
        cwd: resolve(__dirname, "../../../packages/local_learning"),
        input: JSON.stringify({
          projectId,
          publicationEndpoint,
          editorToken: credentials.idToken,
          firestoreHost: process.env.FIRESTORE_EMULATOR_HOST,
        }),
        encoding: "utf8",
        timeout: 180000,
        env: process.env,
      },
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /PASS: public Firestore feed/);
    process.stdout.write(result.stdout);
  } finally {
    await deleteApp(app);
  }
});
