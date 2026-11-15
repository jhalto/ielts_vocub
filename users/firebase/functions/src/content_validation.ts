import { createHash } from "node:crypto";
import { AccountError } from "./account";

export const categories = ["basic", "intermediate", "advanced"] as const;
export const difficulties = ["easy", "medium", "advanced"] as const;
const partsOfSpeech = [
  "noun",
  "verb",
  "adjective",
  "adverb",
  "pronoun",
  "preposition",
  "conjunction",
  "interjection",
  "determiner",
];
export const actions = [
  "create",
  "edit",
  "publish",
  "unpublish",
  "retire",
  "restore",
] as const;
export type Action = (typeof actions)[number];
export interface ExamplePair {
  english: string;
  bengali: string;
}
export interface Sense {
  id: string;
  partOfSpeech: string;
  englishMeaning: string;
  bengaliMeaning: string;
  ordering: number;
  examples: ExamplePair[];
}
export interface Content {
  spelling: string;
  pronunciation: string;
  category: string;
  difficulty: string;
  ordering: number;
  senses: Sense[];
}
export interface Mutation {
  operationId: string;
  wordId: string;
  action: Action;
  expectedRevision: number;
  reviewed: boolean;
  content?: Content;
}
export function fail(code = "invalid-input", status = 400): never {
  throw new AccountError(status, code);
}
function object(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return fail();
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((key) => !keys.includes(key))) return fail();
  return record;
}
function text(value: unknown, maximum: number, required = false): string {
  if (
    typeof value !== "string" ||
    value.length > maximum ||
    /[\uD800-\uDFFF]/u.test(value) ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u.test(value)
  )
    return fail();
  const result = value.normalize("NFC").trim();
  if (required && !result) return fail();
  return result;
}
export function stableId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(value)
  )
    return fail();
  return value;
}
function integer(value: unknown, maximum: number): number {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < 0 ||
    (value as number) > maximum
  )
    return fail();
  return value as number;
}
function enumValue(value: unknown, allowed: readonly string[]): string {
  if (typeof value !== "string" || !allowed.includes(value)) return fail();
  return value;
}
function list(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) return fail();
  return value;
}
export function validateContent(value: unknown): Content {
  const data = object(value, [
    "spelling",
    "pronunciation",
    "category",
    "difficulty",
    "ordering",
    "senses",
  ]);
  const senses = list(data.senses, 100).map((item, index): Sense => {
    const sense = object(item, [
      "id",
      "partOfSpeech",
      "englishMeaning",
      "bengaliMeaning",
      "ordering",
      "examples",
    ]);
    if (sense.ordering !== index) return fail("invalid-sense-order");
    return {
      id: stableId(sense.id),
      partOfSpeech: enumValue(sense.partOfSpeech, partsOfSpeech),
      englishMeaning: text(sense.englishMeaning, 4000),
      bengaliMeaning: text(sense.bengaliMeaning, 4000),
      ordering: index,
      examples: list(sense.examples, 100).map((pair): ExamplePair => {
        const example = object(pair, ["english", "bengali"]);
        return {
          english: text(example.english, 4000),
          bengali: text(example.bengali, 4000),
        };
      }),
    };
  });
  if (new Set(senses.map((sense) => sense.id)).size !== senses.length)
    return fail("duplicate-sense-id");
  return {
    spelling: text(data.spelling, 128, true),
    pronunciation: text(data.pronunciation, 256),
    category: enumValue(data.category, categories),
    difficulty: enumValue(data.difficulty, difficulties),
    ordering: integer(data.ordering, 2147483647),
    senses,
  };
}
export function requirePublishable(content: Content, reviewed: boolean): void {
  if (!reviewed) return fail("review-required", 422);
  if (
    !content.pronunciation ||
    !content.senses.length ||
    content.senses.some(
      (sense) =>
        !sense.englishMeaning ||
        !sense.bengaliMeaning ||
        !sense.examples.length ||
        sense.examples.some((pair) => !pair.english || !pair.bengali),
    )
  ) {
    return fail("publication-incomplete", 422);
  }
}
export function validateMutation(value: unknown): Mutation {
  if (Buffer.byteLength(JSON.stringify(value) ?? "") > 196608)
    return fail("payload-too-large", 413);
  const data = object(value, [
    "operationId",
    "wordId",
    "action",
    "expectedRevision",
    "content",
    "reviewed",
  ]);
  const action = enumValue(data.action, actions) as Action;
  const hasContent = action === "create" || action === "edit";
  if (hasContent !== Object.hasOwn(data, "content")) return fail();
  if (data.reviewed !== undefined && typeof data.reviewed !== "boolean")
    return fail();
  const expectedRevision = integer(
    data.expectedRevision,
    Number.MAX_SAFE_INTEGER - 1,
  );
  if (action === "create" && expectedRevision !== 0)
    return fail("create-revision-must-be-zero");
  return {
    operationId: stableId(data.operationId),
    wordId: stableId(data.wordId),
    action,
    expectedRevision,
    reviewed: data.reviewed === true,
    ...(hasContent ? { content: validateContent(data.content) } : {}),
  };
}
/** Compatibility/case/spacing normalization is for uniqueness, not displayed text. */
export function normalizeSpelling(spelling: string): string {
  return spelling.normalize("NFKC").trim().replace(/\s+/gu, " ").toLowerCase();
}
export function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}
export function emptyCounts(): Record<string, number> {
  return Object.fromEntries(
    categories.flatMap((category) =>
      difficulties.map((difficulty) => [`${category}/${difficulty}`, 0]),
    ),
  );
}
