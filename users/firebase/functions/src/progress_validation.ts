import { fail, stableId, canonical, hash } from "./content_validation";

export const statuses = ["already_know", "learned", "didnt_know"] as const;
export type ProgressStatus = (typeof statuses)[number];
export interface ProgressOperation {
  operationId: string;
  deviceId: string;
  wordId: string;
  desiredStatus: ProgressStatus;
  baseRevision: number;
  sequence: number;
  supersedesOperationId?: string;
}
export interface ProgressCursor {
  version: 1;
  owner: string;
  revision: number;
  afterWordId: string;
}
export type ProgressRequest =
  | { action: "upload"; operations: ProgressOperation[] }
  | { action: "list"; limit: number; cursor?: string };

function object(value: unknown, allowed: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return fail();
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some((key) => !allowed.includes(key))) return fail();
  return data;
}
export function revision(value: unknown, minimum = 0): number {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < minimum ||
    (value as number) >= Number.MAX_SAFE_INTEGER
  )
    return fail();
  return value as number;
}
export function validateProgressRequest(body: unknown): ProgressRequest {
  const data = object(body, ["action", "operations", "limit", "cursor"]);
  if (Buffer.byteLength(canonical(data), "utf8") > 32768)
    return fail("payload-too-large", 413);
  if (data.action === "upload") {
    if (
      "limit" in data ||
      "cursor" in data ||
      !Array.isArray(data.operations) ||
      data.operations.length < 1 ||
      data.operations.length > 25
    )
      return fail();
    const seen = new Set<string>();
    const operations = data.operations.map((value) => {
      const op = object(value, [
        "operationId",
        "deviceId",
        "wordId",
        "desiredStatus",
        "baseRevision",
        "sequence",
        "supersedesOperationId",
      ]);
      const operationId = stableId(op.operationId);
      if (seen.has(operationId)) return fail("duplicate-operation-id");
      seen.add(operationId);
      if (!statuses.includes(op.desiredStatus as ProgressStatus)) return fail();
      const supersedesOperationId =
        op.supersedesOperationId === undefined
          ? undefined
          : stableId(op.supersedesOperationId);
      if (supersedesOperationId === operationId) return fail();
      return {
        operationId,
        deviceId: stableId(op.deviceId),
        wordId: stableId(op.wordId),
        desiredStatus: op.desiredStatus as ProgressStatus,
        baseRevision: revision(op.baseRevision),
        sequence: revision(op.sequence, 1),
        ...(supersedesOperationId === undefined
          ? {}
          : { supersedesOperationId }),
      };
    });
    return { action: "upload", operations };
  }
  if (data.action === "list") {
    if ("operations" in data) return fail();
    const limit = data.limit === undefined ? 50 : revision(data.limit, 1);
    if (limit > 100) return fail();
    if (
      data.cursor !== undefined &&
      (typeof data.cursor !== "string" || data.cursor.length > 1024)
    )
      return fail("invalid-cursor");
    return {
      action: "list",
      limit,
      ...(data.cursor === undefined ? {} : { cursor: data.cursor as string }),
    };
  }
  return fail();
}
export function encodeProgressCursor(
  uid: string,
  revision: number,
  afterWordId: string,
): string {
  return Buffer.from(
    JSON.stringify({ version: 1, owner: hash(uid), revision, afterWordId }),
  ).toString("base64url");
}
export function decodeProgressCursor(
  uid: string,
  cursor: string,
): ProgressCursor {
  try {
    if (!/^[A-Za-z0-9_-]{1,1024}$/.test(cursor)) throw new Error();
    const data = object(
      JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")),
      ["version", "owner", "revision", "afterWordId"],
    );
    if (data.version !== 1 || data.owner !== hash(uid)) throw new Error();
    return {
      version: 1,
      owner: hash(uid),
      revision: revision(data.revision),
      afterWordId: stableId(data.afterWordId),
    };
  } catch {
    return fail("invalid-cursor");
  }
}
