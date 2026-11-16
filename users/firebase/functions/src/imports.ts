import { getAuth, DecodedIdToken } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import {
  DocumentData,
  FieldValue,
  FieldPath,
  getFirestore,
  Transaction,
} from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { AccountError, authorizeAdmin } from "./account";
import { assertManagedAccess } from "./managed_access";
import { applyContentMutation } from "./content";
import {
  canonical,
  fail,
  hash,
  Mutation,
  requirePublishable,
  stableId,
} from "./content_validation";
import {
  boundedIds,
  IMPORT_BYTES,
  ImportRow,
  importOperationId,
  importRows,
  planFingerprint,
  record,
} from "./import_validation";

function jobRef(uid: string, jobId: string) {
  return getFirestore().doc(`importJobs/${hash(canonical([uid, jobId]))}`);
}
function summary(data: DocumentData) {
  return {
    schemaVersion: 1,
    jobId: data.jobId,
    status: data.status,
    counts: data.counts,
  };
}
function owned(
  data: DocumentData | undefined,
  uid: string,
  jobId: string,
): DocumentData {
  if (!data || data.uid !== uid || data.jobId !== jobId)
    return fail("import-job-not-found", 404);
  return data;
}
function audit(
  tx: Transaction,
  uid: string,
  jobId: string,
  itemId: string | null,
  action: string,
  extra: Record<string, unknown> = {},
) {
  const key = hash(canonical([uid, jobId, itemId, action]));
  tx.create(getFirestore().doc(`adminAudit/import_${key}`), {
    actorUid: uid,
    targetId: jobId,
    jobId,
    itemId,
    action,
    ...extra,
    createdAt: FieldValue.serverTimestamp(),
  });
}
function transition(job: DocumentData, state: "applied" | "failed") {
  const counts = { ...job.counts };
  if (!Number.isSafeInteger(counts.pending) || counts.pending < 1)
    return fail("import-state-invalid", 409);
  counts.pending--;
  counts[state]++;
  return {
    counts,
    status: counts.pending
      ? "ready"
      : counts.failed
        ? "completed_with_errors"
        : "completed",
    updatedAt: FieldValue.serverTimestamp(),
  };
}
function publicItem(id: string, data: DocumentData) {
  return {
    itemId: id,
    index: data.index,
    decision: data.decision,
    state: data.state,
    wordId: data.mutation?.wordId ?? null,
    attempts: data.attempts,
    result: data.result ?? null,
    lastError: data.lastError ?? null,
  };
}
async function inspect(rows: ImportRow[]) {
  const db = getFirestore();
  const valid = rows.filter((r) => r.mutation && !r.errors.length);
  const refs = valid.flatMap((row) => [
    db.doc(`words/${row.mutation!.wordId}`),
    db.doc(`wordSpellings/${hash(row.normalizedSpelling!)}`),
  ]);
  const snapshots = refs.length ? await db.getAll(...refs) : [];
  const found = new Map(snapshots.map((s) => [s.ref.path, s.data()]));
  return rows.map((row) => {
    const errors = [...row.errors];
    const input = row.errors.length ? undefined : row.mutation;
    const word = input ? found.get(`words/${input.wordId}`) : undefined;
    const spelling = input
      ? found.get(`wordSpellings/${hash(row.normalizedSpelling!)}`)
      : undefined;
    if (input && !errors.length) {
      if (row.decision === "create" && word) errors.push("word-exists");
      if (row.decision === "update") {
        if (!word) errors.push("word-not-found");
        else {
          if (word.revision !== input.expectedRevision)
            errors.push("revision-conflict");
          if (word.isRetired) errors.push("word-retired");
          if (word.isPublished) {
            try {
              requirePublishable(input.content!, input.reviewed);
            } catch (e) {
              if (!(e instanceof AccountError)) throw e;
              errors.push(e.code);
            }
          }
        }
      }
      if (spelling && spelling.wordId !== input.wordId)
        errors.push("duplicate-spelling");
    }
    return {
      index: row.index,
      itemId: row.itemId ?? null,
      decision: row.decision ?? null,
      errors,
      normalizedSpelling: row.normalizedSpelling ?? null,
      content: input?.content ?? null,
      publishable: row.publishable ?? null,
      existing: word
        ? {
            wordId: input!.wordId,
            revision: word.revision,
            isPublished: word.isPublished,
            isRetired: word.isRetired,
          }
        : null,
      duplicateWordId:
        spelling && spelling.wordId !== input?.wordId ? spelling.wordId : null,
    };
  });
}
async function preview(rows: ImportRow[]) {
  const items = await inspect(rows);
  return {
    schemaVersion: 1,
    valid: items.every((r) => !r.errors.length),
    items,
  };
}
async function createJob(uid: string, jobId: string, rows: ImportRow[]) {
  if (rows.some((r) => r.errors.length))
    return { ...(await preview(rows)), code: "import-invalid" };
  const fingerprint = planFingerprint(rows);
  const ref = jobRef(uid, jobId);
  // An immutable-job retry must not be rejected because its own earlier work
  // changed the database. Current database checks are advisory for new jobs.
  const saved = await ref.get();
  if (saved.exists) {
    const job = owned(saved.data(), uid, jobId);
    if (job.fingerprint !== fingerprint)
      return fail("import-job-id-reused", 409);
    return { ...summary(job), replayed: true };
  }
  const checked = await preview(rows);
  return getFirestore().runTransaction(async (tx) => {
    const existing = await tx.get(ref);
    if (existing.exists) {
      const job = owned(existing.data(), uid, jobId);
      if (job.fingerprint !== fingerprint)
        return fail("import-job-id-reused", 409);
      return { ...summary(job), replayed: true };
    }
    if (!checked.valid) return { ...checked, code: "import-invalid" };
    const skipped = rows.filter((r) => r.decision === "skip").length;
    const job = {
      schemaVersion: 1,
      uid,
      jobId,
      fingerprint,
      status: skipped === rows.length ? "completed" : "ready",
      counts: {
        total: rows.length,
        pending: rows.length - skipped,
        applied: 0,
        skipped,
        failed: 0,
      },
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    };
    tx.create(ref, job);
    for (const row of rows) {
      const mutation = row.mutation
        ? {
            ...row.mutation,
            operationId: importOperationId(uid, jobId, row.itemId!),
          }
        : null;
      tx.create(ref.collection("items").doc(row.itemId!), {
        index: row.index,
        decision: row.decision,
        mutation,
        mutationHash: mutation ? hash(canonical(mutation)) : null,
        state: mutation ? "pending" : "skipped",
        attempts: 0,
        result: mutation ? null : { code: "skipped" },
        lastError: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      if (!mutation) audit(tx, uid, jobId, row.itemId!, "import_item_skipped");
    }
    audit(tx, uid, jobId, null, "import_job_created", { counts: job.counts });
    return { ...summary(job), replayed: false };
  });
}
async function recordFailure(
  uid: string,
  jobId: string,
  itemId: string,
  code: string,
  retryable: boolean,
) {
  const ref = jobRef(uid, jobId),
    itemRef = ref.collection("items").doc(itemId);
  await getFirestore().runTransaction(async (tx) => {
    const [j, i] = await tx.getAll(ref, itemRef);
    const job = owned(j.data(), uid, jobId),
      item = i.data();
    if (!item) return fail("import-item-not-found", 404);
    if (item.state !== "pending") return;
    tx.update(itemRef, {
      state: retryable ? "pending" : "failed",
      attempts: item.attempts + 1,
      lastError: { code, retryable },
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (!retryable) {
      tx.update(ref, transition(job, "failed"));
      audit(tx, uid, jobId, itemId, "import_item_failed", {
        code,
        wordId: item.mutation.wordId,
      });
    }
  });
}
async function processItem(uid: string, jobId: string, itemId: string) {
  const ref = jobRef(uid, jobId),
    itemRef = ref.collection("items").doc(itemId);
  const item = (await itemRef.get()).data();
  if (!item) return fail("import-item-not-found", 404);
  if (item.state !== "pending") return publicItem(itemId, item);
  const input = item.mutation as Mutation;
  try {
    await applyContentMutation(uid, input, async (tx) => {
      const [j, i] = await tx.getAll(ref, itemRef);
      const job = owned(j.data(), uid, jobId),
        current = i.data();
      if (
        !current ||
        current.mutationHash !== hash(canonical(input)) ||
        hash(canonical(current.mutation)) !== current.mutationHash
      )
        return fail("import-state-invalid", 409);
      if (current.state === "applied") return () => {};
      if (current.state !== "pending") return fail("import-item-terminal", 409);
      return (result) => {
        tx.update(itemRef, {
          state: "applied",
          result,
          lastError: null,
          attempts: current.attempts + 1,
          updatedAt: FieldValue.serverTimestamp(),
        });
        tx.update(ref, transition(job, "applied"));
        audit(tx, uid, jobId, itemId, "import_item_applied", {
          wordId: input.wordId,
          revision: result.revision,
        });
      };
    });
  } catch (e) {
    const failure =
      e instanceof AccountError
        ? e
        : new AccountError(
            503,
            [10, "aborted"].includes(
              (e as { code?: number | string }).code ?? "",
            )
              ? "transaction-contention"
              : "service-unavailable",
          );
    await recordFailure(
      uid,
      jobId,
      itemId,
      failure.code,
      failure.status === 429 ||
        failure.status >= 500 ||
        failure.code === "transaction-contention",
    );
  }
  return publicItem(itemId, (await itemRef.get()).data()!);
}
/** Called only after the HTTP adapter verifies a current editor identity. */
export async function importAction(uid: string, body: unknown) {
  const header = record(body, [
    "action",
    "jobId",
    "import",
    "itemIds",
    "afterItemId",
    "limit",
  ]);
  const action = header.action;
  const allowed: Record<string, string[]> = {
    preview: ["action", "import"],
    create: ["action", "jobId", "import"],
    process: ["action", "jobId", "itemIds"],
    get: ["action", "jobId", "afterItemId", "limit"],
  };
  if (typeof action !== "string" || !Object.hasOwn(allowed, action))
    return fail();
  record(body, allowed[action]);
  // Includes dry runs, reads and retries: no unauthenticated quota documents.
  const rate = getFirestore().doc(`importRateLimits/${uid}`);
  await getFirestore().runTransaction(async (tx) => {
    const data = (await tx.get(rate)).data(),
      window = Math.floor(Date.now() / 60000);
    const count = data?.window === window ? Number(data.count) : 0;
    if (count >= 60) return fail("rate-limited", 429);
    tx.set(rate, { window, count: count + 1 });
  });
  if (action === "preview") return preview(importRows(header.import));
  const jobId = stableId(header.jobId);
  if (action === "create")
    return createJob(uid, jobId, importRows(header.import));
  const ref = jobRef(uid, jobId);
  owned((await ref.get()).data(), uid, jobId);
  if (action === "process") {
    const ids = boundedIds(header.itemIds);
    // Reject unknown IDs before applying any of this request's items.
    const existing = await getFirestore().getAll(
      ...ids.map((id) => ref.collection("items").doc(id)),
    );
    if (existing.some((s) => !s.exists))
      return fail("import-item-not-found", 404);
    const items = [];
    for (const id of ids) {
      const item = await processItem(uid, jobId, id);
      items.push(item);
      if (item.state === "pending") break; // transient failure: no busy retry loop
    }
    return { ...summary(owned((await ref.get()).data(), uid, jobId)), items };
  }
  const limit = header.limit ?? 25;
  if (
    !Number.isInteger(limit) ||
    (limit as number) < 1 ||
    (limit as number) > 25
  )
    return fail();
  let query = ref
    .collection("items")
    .orderBy(FieldPath.documentId())
    .limit((limit as number) + 1);
  if (header.afterItemId !== undefined)
    query = query.startAfter(stableId(header.afterItemId));
  const page = await query.get(),
    selected = page.docs.slice(0, limit as number);
  return {
    ...summary(owned((await ref.get()).data(), uid, jobId)),
    items: selected.map((s) => publicItem(s.id, s.data())),
    nextAfterItemId: page.size > (limit as number) ? selected.at(-1)!.id : null,
  };
}

export const importApi = onRequest(
  { cors: true, timeoutSeconds: 60, maxInstances: 5 },
  async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (req.method !== "POST") {
      res.status(405).json({ code: "method-not-allowed" });
      return;
    }
    if (req.rawBody.length > IMPORT_BYTES) {
      res.status(413).json({ code: "payload-too-large" });
      return;
    }
    if (!req.is("application/json")) {
      res.status(415).json({ code: "json-required" });
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
      const result = await importAction(token.uid, req.body);
      res
        .status(
          "code" in result && result.code === "import-invalid" ? 422 : 200,
        )
        .json(result);
    } catch (e) {
      if (e instanceof AccountError) {
        res.status(e.status).json({ code: e.code });
        return;
      }
      const code = (e as { code?: number | string }).code;
      res.status(code === 10 || code === "aborted" ? 409 : 503).json({
        code:
          code === 10 || code === "aborted"
            ? "transaction-contention"
            : "service-unavailable",
      });
    }
  },
);
