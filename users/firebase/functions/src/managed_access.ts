import { DecodedIdToken } from "firebase-admin/auth";
import { DocumentData, getFirestore } from "firebase-admin/firestore";
import { AccountError } from "./errors";

export function managedTokenMatches(
  token: Pick<DecodedIdToken, "uid"> & Record<string, unknown>,
  data: DocumentData,
): boolean {
  return (
    data.schemaVersion === 1 &&
    data.uid === token.uid &&
    data.disabled === false &&
    data.pendingOperation === null &&
    Number.isSafeInteger(data.revision) &&
    data.revision >= 0 &&
    Number.isSafeInteger(data.minAuthTime ?? 0) &&
    (data.minAuthTime ?? 0) >= 0 &&
    ((data.minAuthTime ?? 0) === 0 ||
      (Number.isSafeInteger(token.auth_time) &&
        (token.auth_time as number) >= data.minAuthTime)) &&
    (token.adminRevision ?? 0) === data.revision &&
    (token.role ?? "student") === data.role
  );
}
/** Missing records retain legacy behavior; only trusted workflow writes these. */
export async function assertManagedAccess(
  token: DecodedIdToken,
): Promise<void> {
  const saved = await getFirestore().doc(`managedAccounts/${token.uid}`).get();
  if (!saved.exists) return;
  const data = saved.data()!;
  if (data.pendingOperation !== null)
    throw new AccountError(401, "account-change-pending");
  if (data.disabled === true) throw new AccountError(401, "user-disabled");
  if (!managedTokenMatches(token, data))
    throw new AccountError(401, "session-stale");
}
