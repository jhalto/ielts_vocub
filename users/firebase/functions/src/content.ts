import { getAuth, DecodedIdToken } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import {
  getFirestore,
  FieldValue,
  DocumentData,
  Transaction,
} from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { AccountError, authorizeAdmin } from "./account";
import { assertManagedAccess } from "./managed_access";
import {
  Content,
  Mutation,
  validateMutation,
  validateContent,
  requirePublishable,
  normalizeSpelling,
  hash,
  canonical,
  emptyCounts,
  fail,
} from "./content_validation";

interface Word extends Content {
  isPublished: boolean;
  isRetired: boolean;
  revision: number;
  normalizedSpelling: string;
}
interface Manifest {
  schemaVersion: number;
  publisherVersion: number;
  currentRevision: number;
  oldestRetainedRevision: number;
  groupCounts: Record<string, number>;
  totalPublished: number;
}
function readManifest(data: DocumentData | undefined): Manifest {
  if (!data || data.publisherVersion !== 1)
    return fail("initialization-required", 409);
  if (
    data.schemaVersion !== 1 ||
    !Number.isSafeInteger(data.currentRevision) ||
    data.currentRevision < 0 ||
    data.currentRevision >= Number.MAX_SAFE_INTEGER ||
    !Number.isSafeInteger(data.oldestRetainedRevision) ||
    data.oldestRetainedRevision < 0 ||
    data.oldestRetainedRevision > data.currentRevision ||
    !data.groupCounts ||
    typeof data.groupCounts !== "object"
  )
    return fail("content-state-invalid", 409);
  const keys = Object.keys(emptyCounts());
  if (
    Object.keys(data.groupCounts).length !== 9 ||
    keys.some(
      (key) =>
        !Number.isSafeInteger(data.groupCounts[key]) ||
        data.groupCounts[key] < 0,
    ) ||
    data.totalPublished !==
      keys.reduce((sum, key) => sum + data.groupCounts[key], 0)
  )
    return fail("content-state-invalid", 409);
  return {
    schemaVersion: 1,
    publisherVersion: 1,
    currentRevision: data.currentRevision,
    oldestRetainedRevision: data.oldestRetainedRevision,
    groupCounts: { ...data.groupCounts },
    totalPublished: data.totalPublished,
  };
}
function metadata(word?: Word): Record<string, unknown> | null {
  return word
    ? {
        revision: word.revision,
        category: word.category,
        difficulty: word.difficulty,
        isPublished: word.isPublished,
        isRetired: word.isRetired,
      }
    : null;
}
/** All callers of this service must be authenticated trusted server code. */
export async function applyContentMutation(
  uid: string,
  input: Mutation,
  participate?: (
    tx: Transaction,
  ) => Promise<(result: Record<string, unknown>) => void>,
): Promise<Record<string, unknown>> {
  const db = getFirestore();
  const wordRef = db.doc(`words/${input.wordId}`);
  const manifestRef = db.doc("contentManifest/current");
  const operationRef = db.doc(
    `contentOperations/${hash(`${uid}:${input.operationId}`)}`,
  );
  const rateRef = db.doc(`contentRateLimits/${uid}`);
  const fingerprint = hash(canonical(input));
  return db.runTransaction(async (tx) => {
    const [operation, current, manifestSnapshot, rate] = await tx.getAll(
      operationRef,
      wordRef,
      manifestRef,
      rateRef,
    );
    // Trusted services may read their own receipt before writes, then commit it
    // in this same publication transaction. HTTP clients cannot supply a hook.
    const complete = participate ? await participate(tx) : undefined;
    const window = Math.floor(Date.now() / 60000);
    const count =
      rate.data()?.window === window ? Number(rate.data()?.count) : 0;
    if (count >= 60) return fail("rate-limited", 429);
    if (operation.exists) {
      if (operation.data()?.fingerprint !== fingerprint)
        return fail("operation-id-reused", 409);
      tx.set(rateRef, { window, count: count + 1 });
      const replay = { ...operation.data()!.result, replayed: true };
      complete?.(replay);
      return replay;
    }
    let manifest: Manifest;
    if (!manifestSnapshot.exists) {
      // Never fabricate zero totals for an existing/unmanaged dataset.
      const existing = await tx.get(db.collection("words").limit(1));
      const oldChanges = await tx.get(db.collection("contentChanges").limit(1));
      const oldSpellings = await tx.get(
        db.collection("wordSpellings").limit(1),
      );
      if (!existing.empty || !oldChanges.empty || !oldSpellings.empty)
        return fail("initialization-required", 409);
      manifest = {
        schemaVersion: 1,
        publisherVersion: 1,
        currentRevision: 0,
        oldestRetainedRevision: 0,
        groupCounts: emptyCounts(),
        totalPublished: 0,
      };
    } else {
      manifest = readManifest(manifestSnapshot.data());
    }
    const old = current.exists ? (current.data() as Word) : undefined;
    if (input.action === "create" ? Boolean(old) : !old)
      return fail(
        input.action === "create" ? "word-exists" : "word-not-found",
        input.action === "create" ? 409 : 404,
      );
    if ((old?.revision ?? 0) !== input.expectedRevision)
      return fail("revision-conflict", 409);
    if (
      old &&
      (!Number.isSafeInteger(old.revision) ||
        old.revision > manifest.currentRevision ||
        typeof old.isPublished !== "boolean" ||
        typeof old.isRetired !== "boolean" ||
        (old.isRetired && old.isPublished) ||
        old.normalizedSpelling !== normalizeSpelling(old.spelling))
    )
      return fail("content-state-invalid", 409);
    const content =
      input.content ??
      validateContent({
        spelling: old!.spelling,
        pronunciation: old!.pronunciation,
        category: old!.category,
        difficulty: old!.difficulty,
        ordering: old!.ordering,
        senses: old!.senses,
      });
    const next: Word = {
      ...content,
      normalizedSpelling: normalizeSpelling(content.spelling),
      revision: manifest.currentRevision + 1,
      isPublished: old?.isPublished ?? false,
      isRetired: old?.isRetired ?? false,
    };
    switch (input.action) {
      case "edit":
        if (next.isRetired) return fail("word-retired", 409);
        break;
      case "publish":
        if (next.isRetired) return fail("word-retired", 409);
        next.isPublished = true;
        break;
      case "unpublish":
        next.isPublished = false;
        break;
      case "retire":
        next.isPublished = false;
        next.isRetired = true;
        break;
      case "restore":
        if (!next.isRetired) return fail("word-not-retired", 409);
        next.isPublished = false;
        next.isRetired = false;
        break;
    }
    if (next.isPublished) requirePublishable(next, input.reviewed);
    const newSpellingRef = db.doc(
      `wordSpellings/${hash(next.normalizedSpelling)}`,
    );
    const oldSpellingRef = old
      ? db.doc(`wordSpellings/${hash(old.normalizedSpelling)}`)
      : newSpellingRef;
    const occupied = await tx.get(newSpellingRef);
    const previous =
      oldSpellingRef.path === newSpellingRef.path
        ? occupied
        : await tx.get(oldSpellingRef);
    if (old && previous.data()?.wordId !== input.wordId)
      return fail("content-state-invalid", 409);
    if (occupied.exists && occupied.data()?.wordId !== input.wordId)
      return fail("duplicate-spelling", 409);
    if (old?.isPublished)
      manifest.groupCounts[`${old.category}/${old.difficulty}`]--;
    if (next.isPublished)
      manifest.groupCounts[`${next.category}/${next.difficulty}`]++;
    if (
      Object.values(manifest.groupCounts).some(
        (value) => !Number.isSafeInteger(value) || value < 0,
      )
    )
      return fail("content-state-invalid", 409);
    manifest.currentRevision = next.revision;
    manifest.totalPublished = Object.values(manifest.groupCounts).reduce(
      (sum, value) => sum + value,
      0,
    );
    const changeId = String(next.revision).padStart(16, "0");
    const action = next.isPublished
      ? "upsert"
      : old?.isPublished
        ? "remove"
        : "noop";
    const change = {
      schemaVersion: 1,
      revision: next.revision,
      action,
      ...(action === "noop" ? {} : { wordId: input.wordId }),
      updatedAt: FieldValue.serverTimestamp(),
    };
    const result = {
      wordId: input.wordId,
      revision: next.revision,
      contentRevision: next.revision,
      isPublished: next.isPublished,
      isRetired: next.isRetired,
      replayed: false,
    };
    tx.set(wordRef, { ...next, updatedAt: FieldValue.serverTimestamp() });
    if (oldSpellingRef.path !== newSpellingRef.path) tx.delete(oldSpellingRef);
    tx.set(newSpellingRef, { wordId: input.wordId });
    tx.set(manifestRef, {
      ...manifest,
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.create(db.doc(`contentChanges/${changeId}`), change);
    tx.create(db.collection("adminAudit").doc(), {
      actorUid: uid,
      targetId: input.wordId,
      action: `word_${input.action}`,
      operationId: input.operationId,
      revision: next.revision,
      before: metadata(old),
      after: metadata(next),
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.create(operationRef, {
      uid,
      fingerprint,
      result,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(rateRef, { window, count: count + 1 });
    complete?.(result);
    return result;
  });
}
export const contentApi = onRequest(
  { cors: true, timeoutSeconds: 30, maxInstances: 5 },
  async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (req.method !== "POST") {
      res.status(405).json({ code: "method-not-allowed" });
      return;
    }
    if (req.rawBody.length > 262144) {
      res.status(413).json({ code: "payload-too-large" });
      return;
    }
    try {
      const header = req.headers.authorization;
      if (!header?.startsWith("Bearer ")) return fail("unauthenticated", 401);
      let token: DecodedIdToken;
      try {
        token = await getAuth().verifyIdToken(header.slice(7), true);
      } catch (e) {
        const code = (e as { code?: string }).code;
        return fail(
          code === "auth/id-token-revoked"
            ? "session-revoked"
            : code === "auth/user-disabled"
              ? "user-disabled"
              : "unauthenticated",
          401,
        );
      }
      await assertManagedAccess(token);
      authorizeAdmin(token, await getAuth().getUser(token.uid));
      if (process.env.REQUIRE_CONTENT_APP_CHECK === "true") {
        const attestation = req.header("X-Firebase-AppCheck");
        if (!attestation) return fail("app-check-required", 403);
        try {
          await getAppCheck().verifyToken(attestation);
        } catch {
          return fail("app-check-invalid", 403);
        }
      }
      res.json(
        await applyContentMutation(token.uid, validateMutation(req.body)),
      );
    } catch (e) {
      if (e instanceof AccountError) {
        res.status(e.status).json({ code: e.code });
        return;
      }
      if (
        [10, "aborted"].includes((e as { code?: number | string }).code ?? "")
      ) {
        res.status(409).json({ code: "transaction-contention" });
        return;
      }
      if (
        [6, "already-exists"].includes(
          (e as { code?: number | string }).code ?? "",
        )
      ) {
        res.status(409).json({ code: "content-state-invalid" });
        return;
      }
      res.status(503).json({ code: "service-unavailable" });
    }
  },
);
