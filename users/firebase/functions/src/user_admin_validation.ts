import { canonical, fail, hash, stableId } from "./content_validation";

export const roles = ["student", "content_manager", "super_admin"] as const;
export type Role = (typeof roles)[number];
export interface Filters {
  role?: Role;
  disabled?: boolean;
  verified?: boolean;
  provider?: string;
}
export interface UserMutation {
  action: "setRole" | "setDisabled";
  operationId: string;
  targetUid: string;
  expectedRevision: number;
  expectedState: string;
  confirmed: true;
  reason: string;
  role?: Role;
  disabled?: boolean;
}
function object(value: unknown, allowed: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return fail();
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some((k) => !allowed.includes(k))) return fail();
  return data;
}
export function userId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !value.length ||
    value.length > 128 ||
    /[\u0000-\u001f\u007f/]/u.test(value) ||
    [".", ".."].includes(value)
  )
    return fail();
  return value;
}
export function validateUserRequest(
  value: unknown,
):
  | UserMutation
  | { action: "get"; uid?: string; email?: string }
  | { action: "list"; limit: number; filters: Filters; cursor?: string }
  | { action: "resume" | "operation"; operationKey: string } {
  const data = object(value, [
    "action",
    "uid",
    "email",
    "limit",
    "filters",
    "cursor",
    "operationKey",
    "operationId",
    "targetUid",
    "expectedRevision",
    "expectedState",
    "confirmed",
    "reason",
    "role",
    "disabled",
  ]);
  if (data.action === "get") {
    object(data, ["action", "uid", "email"]);
    if (Object.hasOwn(data, "uid") === Object.hasOwn(data, "email"))
      return fail();
    if (Object.hasOwn(data, "uid"))
      return { action: "get", uid: userId(data.uid) };
    if (
      typeof data.email !== "string" ||
      data.email.length > 254 ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(data.email)
    )
      return fail();
    return { action: "get", email: data.email };
  }
  if (data.action === "list") {
    object(data, ["action", "limit", "filters", "cursor"]);
    const limit = data.limit ?? 25;
    if (
      !Number.isSafeInteger(limit) ||
      (limit as number) < 1 ||
      (limit as number) > 100
    )
      return fail();
    const filters = object(data.filters ?? {}, [
      "role",
      "disabled",
      "verified",
      "provider",
    ]);
    if (
      (filters.role !== undefined && !roles.includes(filters.role as Role)) ||
      ["disabled", "verified"].some(
        (k) => filters[k] !== undefined && typeof filters[k] !== "boolean",
      ) ||
      (filters.provider !== undefined &&
        (typeof filters.provider !== "string" ||
          !/^[A-Za-z0-9._-]{1,64}$/.test(filters.provider)))
    )
      return fail();
    if (
      data.cursor !== undefined &&
      (typeof data.cursor !== "string" ||
        !/^[A-Za-z0-9_-]{1,4096}$/.test(data.cursor))
    )
      return fail("invalid-cursor");
    return {
      action: "list",
      limit: limit as number,
      filters: filters as Filters,
      ...(data.cursor === undefined ? {} : { cursor: data.cursor as string }),
    };
  }
  if (data.action === "resume" || data.action === "operation") {
    object(data, ["action", "operationKey"]);
    if (
      typeof data.operationKey !== "string" ||
      !/^[a-f0-9]{64}$/.test(data.operationKey)
    )
      return fail();
    return { action: data.action, operationKey: data.operationKey };
  }
  if (data.action !== "setRole" && data.action !== "setDisabled") return fail();
  object(data, [
    "action",
    "operationId",
    "targetUid",
    "expectedRevision",
    "expectedState",
    "confirmed",
    "reason",
    data.action === "setRole" ? "role" : "disabled",
  ]);
  if (
    !Number.isSafeInteger(data.expectedRevision) ||
    (data.expectedRevision as number) < 0 ||
    (data.expectedRevision as number) >= Number.MAX_SAFE_INTEGER - 1 ||
    typeof data.expectedState !== "string" ||
    !/^[a-f0-9]{64}$/.test(data.expectedState) ||
    data.confirmed !== true ||
    typeof data.reason !== "string" ||
    data.reason.trim().length < 5 ||
    data.reason.length > 500 ||
    /[\u0000-\u001f\u007f-\u009f\uD800-\uDFFF]/u.test(data.reason)
  )
    return fail();
  if (
    data.action === "setRole"
      ? !roles.includes(data.role as Role)
      : typeof data.disabled !== "boolean"
  )
    return fail();
  return {
    action: data.action,
    operationId: stableId(data.operationId),
    targetUid: userId(data.targetUid),
    expectedRevision: data.expectedRevision as number,
    expectedState: data.expectedState,
    confirmed: true,
    reason: data.reason.normalize("NFC").trim(),
    ...(data.action === "setRole"
      ? { role: data.role as Role }
      : { disabled: data.disabled as boolean }),
  };
}
export function encodeUserCursor(
  uid: string,
  limit: number,
  filters: Filters,
  token: string,
): string {
  return Buffer.from(
    JSON.stringify({ schemaVersion: 1, uid, limit, filters, token }),
  ).toString("base64url");
}
export function decodeUserCursor(
  uid: string,
  limit: number,
  filters: Filters,
  value: string,
): string {
  try {
    const data = object(
      JSON.parse(Buffer.from(value, "base64url").toString("utf8")),
      ["schemaVersion", "uid", "limit", "filters", "token"],
    );
    if (
      data.schemaVersion !== 1 ||
      data.uid !== uid ||
      data.limit !== limit ||
      canonical(data.filters) !== canonical(filters) ||
      typeof data.token !== "string" ||
      !data.token.length ||
      data.token.length > 2048
    )
      throw Error();
    return data.token;
  } catch {
    return fail("invalid-cursor");
  }
}
export function operationKey(uid: string, operationId: string): string {
  return hash(canonical([uid, operationId]));
}
