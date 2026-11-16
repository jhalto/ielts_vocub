const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { resolve } = require("node:path");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
test("real Admin Flutter import client uses only demo jobs and safely resumes immutable work", async () => {
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
  if (!process.env.VOCAB_FLUTTER_TOOLS_SNAPSHOT)
    throw Error(
      "Set VOCAB_FLUTTER_TOOLS_SNAPSHOT to the installed Flutter tools snapshot; see setup.md",
    );
  const projectId = "demo-vocabulary",
    app = initializeApp({ projectId });
  try {
    const cleared = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: "DELETE" },
    );
    assert.ok(cleared.ok);
    async function user(email, role) {
      const record = await getAuth().createUser({
        email,
        emailVerified: true,
        password: "Fixture-password-123!",
      });
      await getAuth().setCustomUserClaims(record.uid, { role });
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
    const manager = await user(
      "admin-import-client@example.test",
      "content_manager",
    );
    const student = await user("admin-import-denied@example.test", "student");
    const publicationEndpoint = `http://127.0.0.1:15001/${projectId}/us-central1/contentApi`;
    let revision = 0;
    for (const action of ["create", "publish"]) {
      const response = await fetch(publicationEndpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${manager.token}`,
        },
        body: JSON.stringify({
          operationId: `admin-import-seed-${action}`,
          wordId: "admin-import-existing",
          action,
          expectedRevision: revision,
          ...(action === "create"
            ? {
                content: {
                  spelling: "Existing demo publication",
                  pronunciation: "test",
                  category: "basic",
                  difficulty: "easy",
                  ordering: 0,
                  senses: [
                    {
                      id: "sense",
                      partOfSpeech: "noun",
                      englishMeaning: "Test only",
                      bengaliMeaning: "\u09aa",
                      ordering: 0,
                      examples: [{ english: "Test", bengali: "\u09aa" }],
                    },
                  ],
                },
              }
            : { reviewed: true }),
        }),
      });
      const result = await response.json();
      assert.equal(response.status, 200);
      revision = result.revision;
    }
    const result = spawnSync(
      process.env.VOCAB_DART_BIN ?? "dart",
      [
        process.env.VOCAB_FLUTTER_TOOLS_SNAPSHOT,
        "test",
        "test/import_emulator_probe.dart",
        "--reporter",
        "expanded",
      ],
      {
        cwd: resolve(__dirname, "../../../../admin/admin_panel"),
        encoding: "utf8",
        timeout: 240000,
        env: {
          ...process.env,
          VOCAB_IMPORT_DEMO_CONFIG: JSON.stringify({
            projectId,
            endpoint: `http://127.0.0.1:15001/${projectId}/us-central1/importApi`,
            publicationEndpoint,
            seedRevision: revision,
            uid: manager.uid,
            token: manager.token,
            studentUid: student.uid,
            studentToken: student.token,
          }),
        },
      },
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    process.stdout.write(result.stdout);
    const db = getFirestore(),
      manifest = (await db.doc("contentManifest/current").get()).data();
    assert.equal(manifest.totalPublished, 1);
    assert.equal(
      (await db.doc("words/admin-import-existing").get()).data().spelling,
      "Newer demo editor intent",
    );
    for (const id of ["word-admin-new", "word-paged-a", "word-paged-b"])
      assert.equal(
        (await db.doc(`words/${id}`).get()).data().isPublished,
        false,
      );
    const changes = (
      await db.collection("contentChanges").orderBy("revision").get()
    ).docs.map((s) => s.data());
    assert.deepEqual(
      changes.map((s) => s.revision),
      Array.from({ length: manifest.currentRevision }, (_, i) => i + 1),
    );
    assert.ok(
      changes.filter((s) => s.action === "noop").every((s) => !("wordId" in s)),
    );
  } finally {
    await deleteApp(app);
  }
});
