import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

/** Server-only IAM-protected operation. No callable or HTTP endpoint exports this. */
export async function bootstrapFirstAdmin(uid: string): Promise<void> {
  const auth = getAuth();
  const user = await auth.getUser(uid);
  if (user.disabled || !user.emailVerified)
    throw new Error("Target must be enabled with verified email.");
  // Refuse unmanaged pre-existing admins. Paginate instead of assuming one page.
  let pageToken: string | undefined;
  do {
    const page = await auth.listUsers(1000, pageToken);
    if (
      page.users.some(
        (u) => u.uid !== uid && u.customClaims?.role === "super_admin",
      )
    )
      throw new Error("A super admin already exists.");
    pageToken = page.pageToken;
  } while (pageToken);
  const db = getFirestore();
  const lock = db.doc("serverControl/adminBootstrap");
  const complete = await db.runTransaction(async (tx) => {
    const [snapshot, managed] = await tx.getAll(
      lock,
      db.doc("serverControl/userAdministration"),
    );
    if (managed.exists)
      throw new Error(
        "Bootstrap is sealed after managed administration initialization.",
      );
    if (snapshot.exists && snapshot.data()?.uid !== uid)
      throw new Error("Bootstrap is reserved for another UID.");
    if (snapshot.data()?.state === "complete") {
      if (user.customClaims?.role !== "super_admin")
        throw new Error("Completed bootstrap cannot regrant a changed role.");
      return true;
    }
    if (!snapshot.exists)
      tx.create(lock, {
        uid,
        state: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });
    return false;
  });
  if (complete) return;
  // Auth and Firestore cannot share a transaction. The immutable UID reservation
  // makes a crash recoverable by rerunning exactly the same UID, never another.
  await auth.setCustomUserClaims(uid, {
    ...user.customClaims,
    role: "super_admin",
  });
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(lock);
    if (snapshot.data()?.uid !== uid)
      throw new Error("Bootstrap reservation changed.");
    if (snapshot.data()?.state === "complete") return;
    tx.update(lock, {
      state: "complete",
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.create(db.collection("adminAudit").doc(), {
      actor: "trusted-cli",
      targetId: uid,
      action: "bootstrap_super_admin",
      createdAt: FieldValue.serverTimestamp(),
    });
  });
}
