import { initializeApp } from "firebase-admin/app";
import {
  initializeUserAdministration,
  unlockUserOperation,
} from "./user_admin";
import { userId } from "./user_admin_validation";

async function main(): Promise<void> {
  const [projectId, action, target, confirmation] = process.argv.slice(2);
  if (!projectId || !target || !["initialize", "unlock"].includes(action))
    throw Error("Invalid arguments");
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST,
    firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;
  if (authHost || firestoreHost) {
    if (!projectId.startsWith("demo-") || !authHost || !firestoreHost)
      throw Error("Demo emulators required");
    for (const host of [authHost, firestoreHost]) {
      const uri = new URL(`http://${host}`);
      if (
        !["127.0.0.1", "localhost"].includes(uri.hostname) ||
        !uri.port ||
        uri.username ||
        uri.password ||
        uri.pathname !== "/"
      )
        throw Error("Loopback required");
    }
  }
  initializeApp({ projectId }); // IAM/Application Default Credentials outside demo emulators.
  if (action === "initialize") {
    if (confirmation !== `CONFIRM:${projectId}:${target}`)
      throw Error("Confirmation required");
    await initializeUserAdministration(userId(target));
  } else {
    if (
      confirmation !==
      `CONFIRM:${projectId}:TERMINATED_AND_AUTH_SETTLED:${target}`
    )
      throw Error("Recovery confirmation required");
    await unlockUserOperation(
      target,
      `CONFIRM:TERMINATED_AND_AUTH_SETTLED:${target}`,
    );
  }
  console.log(
    "Trusted administration step completed. Inspect status before further changes.",
  );
}
main().catch(() => {
  console.error(
    "Trusted administration step refused or incomplete. Inspect prerequisites, IAM, pending workers and settled Auth outcomes; never reset the registry or guess a worker has stopped.",
  );
  process.exitCode = 1;
});
