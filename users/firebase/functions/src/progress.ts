import { getAuth } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";
import {
  getFirestore,
  FieldValue,
  FieldPath,
  Timestamp,
  DocumentData,
  Transaction,
  DocumentReference,
} from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { AccountError } from "./account";
import { assertManagedAccess } from "./managed_access";
import { canonical, hash, fail } from "./content_validation";
import {
  ProgressOperation,
  ProgressStatus,
  statuses,
  validateProgressRequest,
  encodeProgressCursor,
  decodeProgressCursor,
} from "./progress_validation";

interface Progress {
  wordId: string;
  status: ProgressStatus;
  revision: number;
  lastOperationId: string;
}
interface Result {
  operationId: string;
  wordId: string;
  code: string;
  progress: Progress | null;
}
function stateRevision(data: DocumentData | undefined): number {
  if (!data) return 0;
  if (
    data.schemaVersion !== 1 ||
    !Number.isSafeInteger(data.revision) ||
    data.revision < 1 ||
    data.revision >= Number.MAX_SAFE_INTEGER
  ) {
    return fail("progress-state-invalid", 503);
  }
  return data.revision;
}
function readProgress(
  wordId: string,
  data: DocumentData,
  maximum: number,
): Progress {
  if (
    data.schemaVersion !== 1 ||
    data.wordId !== wordId ||
    !statuses.includes(data.status) ||
    !Number.isSafeInteger(data.revision) ||
    data.revision < 1 ||
    data.revision > maximum ||
    typeof data.lastOperationId !== "string" ||
    !(data.createdAt instanceof Timestamp) ||
    !(data.updatedAt instanceof Timestamp)
  ) {
    return fail("progress-state-invalid", 503);
  }
  return {
    wordId,
    status: data.status,
    revision: data.revision,
    lastOperationId: data.lastOperationId,
  };
}
async function checkUnmanaged(
  tx: Transaction,
  owner: DocumentReference,
  stateExists: boolean,
): Promise<void> {
  if (
    !stateExists &&
    !(await tx.get(owner.collection("progress").limit(1))).empty
  ) {
    return fail("progress-initialization-required", 503);
  }
}

/** Trusted server entry point only; HTTPS authorization precedes every call. */
export async function applyProgressOperation(
  uid: string,
  input: ProgressOperation,
): Promise<Result & { replayed: boolean }> {
  const db = getFirestore();
  const owner = db.collection("users").doc(uid);
  const receiptRef = owner.collection("syncOps").doc(hash(input.operationId));
  const currentRef = owner.collection("progress").doc(input.wordId);
  const stateRef = owner.collection("syncState").doc("progress");
  const fingerprint = hash(canonical(input));
  return db.runTransaction(async (tx) => {
    const [receipt, current, state] = await tx.getAll(
      receiptRef,
      currentRef,
      stateRef,
    );
    if (receipt.exists) {
      const saved = receipt.data()!;
      if (saved.fingerprint !== fingerprint) {
        return {
          operationId: input.operationId,
          wordId: input.wordId,
          code: "operation-id-reused",
          progress: null,
          replayed: false,
        };
      }
      if (
        saved.schemaVersion !== 1 ||
        !saved.result ||
        saved.result.operationId !== input.operationId ||
        saved.result.wordId !== input.wordId ||
        ![
          "applied",
          "revision-conflict",
          "word-unavailable",
          "invalid-rebase",
        ].includes(saved.result.code) ||
        (saved.result.code === "applied" &&
          (!saved.result.progress ||
            saved.result.progress.lastOperationId !== input.operationId))
      ) {
        return fail("progress-state-invalid", 503);
      }
      return { ...(saved.result as Result), replayed: true };
    }
    const maximum = stateRevision(state.data());
    await checkUnmanaged(tx, owner, state.exists);
    const authoritative = current.exists
      ? readProgress(input.wordId, current.data()!, maximum)
      : null;
    const word = await tx.get(db.collection("words").doc(input.wordId));
    let code = "applied";
    if (input.supersedesOperationId) {
      const prior = await tx.get(
        owner.collection("syncOps").doc(hash(input.supersedesOperationId)),
      );
      if (
        !prior.exists ||
        prior.data()?.result?.wordId !== input.wordId ||
        prior.data()?.result?.code !== "revision-conflict"
      ) {
        code = "invalid-rebase";
      }
    }
    if (code === "applied") {
      if (
        word.data()?.isPublished !== true ||
        word.data()?.isRetired !== false ||
        !Number.isSafeInteger(word.data()?.revision) ||
        word.data()!.revision < 1
      )
        code = "word-unavailable";
      else if ((authoritative?.revision ?? 0) !== input.baseRevision)
        code = "revision-conflict";
    }
    let progress = authoritative;
    if (code === "applied") {
      if (maximum >= Number.MAX_SAFE_INTEGER - 1)
        return fail("revision-exhausted", 503);
      progress = {
        wordId: input.wordId,
        status: input.desiredStatus,
        revision: maximum + 1,
        lastOperationId: input.operationId,
      };
      const time = FieldValue.serverTimestamp();
      tx.set(currentRef, {
        schemaVersion: 1,
        ...progress,
        createdAt: current.data()?.createdAt ?? time,
        updatedAt: time,
        lastDeviceId: input.deviceId,
        lastSequence: input.sequence,
      });
      tx.set(stateRef, {
        schemaVersion: 1,
        revision: progress.revision,
        updatedAt: time,
      });
    }
    const result: Result = {
      operationId: input.operationId,
      wordId: input.wordId,
      code,
      progress,
    };
    tx.create(receiptRef, {
      schemaVersion: 1,
      fingerprint,
      operation: input,
      result,
      createdAt: FieldValue.serverTimestamp(),
    });
    return { ...result, replayed: false };
  });
}

export async function listProgress(
  uid: string,
  limit: number,
  cursor?: string,
): Promise<Record<string, unknown>> {
  const decoded =
    cursor === undefined ? undefined : decodeProgressCursor(uid, cursor);
  const db = getFirestore();
  const owner = db.collection("users").doc(uid);
  return db.runTransaction(async (tx) => {
    const state = await tx.get(owner.collection("syncState").doc("progress"));
    const revision = stateRevision(state.data());
    if (decoded && decoded.revision !== revision)
      return fail("progress-snapshot-changed", 409);
    if (!state.exists && decoded) await checkUnmanaged(tx, owner, false);
    let query = owner
      .collection("progress")
      .orderBy(FieldPath.documentId())
      .limit(limit + 1);
    if (decoded) query = query.startAfter(decoded.afterWordId);
    const page = await tx.get(query);
    if (!state.exists && !page.empty)
      return fail("progress-initialization-required", 503);
    const displayed = page.docs.slice(0, limit);
    const progress = displayed.map((doc) => {
      const data = doc.data();
      return {
        ...readProgress(doc.id, data, revision),
        createdAt: (data.createdAt as Timestamp).toDate().toISOString(),
        updatedAt: (data.updatedAt as Timestamp).toDate().toISOString(),
      };
    });
    return {
      schemaVersion: 1,
      revision,
      progress,
      nextCursor:
        page.size > limit
          ? encodeProgressCursor(uid, revision, displayed.at(-1)!.id)
          : null,
    };
  });
}

async function consumeRate(uid: string, cost: number): Promise<void> {
  const db = getFirestore();
  const ref = db.collection("progressRateLimits").doc(hash(uid));
  await db.runTransaction(async (tx) => {
    const previous = await tx.get(ref);
    const window = Math.floor(Date.now() / 60000);
    const data = previous.data();
    const count = data?.window === window ? data.count : 0;
    if (!Number.isSafeInteger(count) || count < 0)
      return fail("progress-state-invalid", 503);
    if (count + cost > 200) return fail("rate-limited", 429);
    tx.set(ref, { window, count: count + cost });
  });
}

export const progressApi = onRequest(
  { cors: true, timeoutSeconds: 60, maxInstances: 5 },
  async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (req.method !== "POST") {
      res.status(405).json({ code: "method-not-allowed" });
      return;
    }
    if (req.rawBody.length > 65536) {
      res.status(413).json({ code: "payload-too-large" });
      return;
    }
    try {
      if (!req.is("application/json"))
        return fail("unsupported-media-type", 415);
      const header = req.headers.authorization;
      if (!header?.startsWith("Bearer ")) return fail("unauthenticated", 401);
      let token;
      try {
        token = await getAuth().verifyIdToken(header.slice(7), true);
      } catch (error) {
        const code = (error as { code?: string }).code;
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
      const user = await getAuth().getUser(token.uid);
      if (user.disabled) return fail("user-disabled", 401);
      if (
        !user.emailVerified ||
        token.email_verified !== true ||
        token.firebase?.sign_in_provider === "anonymous"
      )
        return fail("email-unverified", 403);
      if (process.env.REQUIRE_PROGRESS_APP_CHECK === "true") {
        const attestation = req.header("X-Firebase-AppCheck");
        if (!attestation) return fail("app-check-required", 403);
        try {
          await getAppCheck().verifyToken(attestation);
        } catch {
          return fail("app-check-invalid", 403);
        }
      }
      const input = validateProgressRequest(req.body);
      await consumeRate(
        token.uid,
        input.action === "upload" ? input.operations.length : 1,
      );
      if (input.action === "list") {
        res.json(await listProgress(token.uid, input.limit, input.cursor));
        return;
      }
      const results = [];
      // Per-operation transactions permit bounded mixed outcomes. If a transport or
      // server failure interrupts this loop, retry every immutable operation ID.
      for (const operation of input.operations)
        results.push(await applyProgressOperation(token.uid, operation));
      res.json({ schemaVersion: 1, results });
    } catch (error) {
      if (error instanceof AccountError) {
        if (error.status === 429) res.set("Retry-After", "60");
        res.status(error.status).json({ code: error.code });
        return;
      }
      const contention = [10, "aborted"].includes(
        (error as { code?: string | number }).code ?? "",
      );
      res.status(503).json({
        code: contention ? "transaction-contention" : "service-unavailable",
      });
    }
  },
);
