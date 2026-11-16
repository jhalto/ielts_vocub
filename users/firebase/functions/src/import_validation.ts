import { AccountError } from "./account";
import {
  Mutation,
  canonical,
  fail,
  hash,
  normalizeSpelling,
  requirePublishable,
  stableId,
  validateMutation,
} from "./content_validation";

export const IMPORT_BYTES = 524288;
export const IMPORT_ITEMS = 50;
export interface ImportRow {
  index: number;
  itemId?: string;
  decision?: "create" | "update" | "skip";
  mutation?: Mutation;
  normalizedSpelling?: string;
  publishable?: boolean;
  errors: string[];
}
export function record(
  value: unknown,
  keys: string[],
): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return fail();
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some((key) => !keys.includes(key))) return fail();
  return data;
}
export function importRows(value: unknown): ImportRow[] {
  if (Buffer.byteLength(JSON.stringify(value) ?? "") > IMPORT_BYTES)
    return fail("payload-too-large", 413);
  const data = record(value, ["schemaVersion", "items"]);
  if (data.schemaVersion !== 1) return fail("import-schema-unsupported");
  if (
    !Array.isArray(data.items) ||
    !data.items.length ||
    data.items.length > IMPORT_ITEMS
  )
    return fail("import-item-limit");
  const rows = data.items.map((value, index): ImportRow => {
    const row: ImportRow = { index, errors: [] };
    try {
      const item = record(value, [
        "itemId",
        "decision",
        "wordId",
        "expectedRevision",
        "content",
        "reviewed",
      ]);
      row.itemId = stableId(item.itemId);
      if (!["skip", "create", "update"].includes(item.decision as string))
        return fail();
      row.decision = item.decision as ImportRow["decision"];
      if (row.decision === "skip") {
        if (Object.keys(item).length !== 2)
          return fail("skip-must-omit-content");
      } else {
        if (row.decision === "create" && Object.hasOwn(item, "reviewed"))
          return fail("import-create-must-be-draft");
        row.mutation = validateMutation({
          // Match the eventual fixed-width operation ID when enforcing the
          // publication service's per-item byte limit during preview.
          operationId: `import_${"0".repeat(64)}`,
          wordId: item.wordId,
          action: row.decision === "create" ? "create" : "edit",
          expectedRevision: item.expectedRevision,
          content: item.content,
          ...(Object.hasOwn(item, "reviewed")
            ? { reviewed: item.reviewed }
            : {}),
        });
        if (row.decision === "update" && row.mutation.expectedRevision === 0)
          return fail("update-revision-required");
        row.normalizedSpelling = normalizeSpelling(
          row.mutation.content!.spelling,
        );
        try {
          requirePublishable(row.mutation.content!, true);
          row.publishable = true;
        } catch (e) {
          if (!(e instanceof AccountError)) throw e;
          row.publishable = false;
        }
      }
    } catch (e) {
      if (!(e instanceof AccountError)) throw e;
      row.errors.push(e.code);
    }
    return row;
  });
  for (const [field, code] of [
    ["itemId", "duplicate-item-id"],
    ["normalizedSpelling", "duplicate-import-spelling"],
  ] as const) {
    const seen = new Map<string, ImportRow[]>();
    for (const row of rows) {
      const key = row[field];
      if (key) seen.set(key, [...(seen.get(key) ?? []), row]);
    }
    for (const duplicates of seen.values())
      if (duplicates.length > 1)
        for (const row of duplicates) row.errors.push(code);
  }
  const targets = new Map<string, ImportRow[]>();
  for (const row of rows)
    if (row.mutation) {
      const key = row.mutation.wordId;
      targets.set(key, [...(targets.get(key) ?? []), row]);
    }
  for (const duplicates of targets.values())
    if (duplicates.length > 1)
      for (const row of duplicates) row.errors.push("duplicate-import-word-id");
  return rows;
}
export function planFingerprint(rows: ImportRow[]): string {
  return hash(
    canonical(
      rows.map((row) => ({
        itemId: row.itemId,
        decision: row.decision,
        ...(row.mutation ? { mutation: row.mutation } : {}),
      })),
    ),
  );
}
export function importOperationId(
  uid: string,
  jobId: string,
  itemId: string,
): string {
  return `import_${hash(canonical([uid, jobId, itemId]))}`;
}
export function boundedIds(value: unknown): string[] {
  if (!Array.isArray(value) || !value.length || value.length > 5)
    return fail("import-batch-limit");
  const ids = value.map(stableId);
  if (new Set(ids).size !== ids.length) return fail("duplicate-item-id");
  return ids;
}
