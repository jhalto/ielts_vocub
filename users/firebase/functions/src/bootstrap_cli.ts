import { initializeApp } from 'firebase-admin/app';
import { bootstrapFirstAdmin } from './bootstrap';

async function main():Promise<void> {
  const [projectId,uid,confirmation]=process.argv.slice(2);
  if(!projectId || !uid || confirmation!==`CONFIRM:${projectId}:${uid}`) {
    throw new Error('Usage: node lib/bootstrap_cli.js PROJECT_ID UID CONFIRM:PROJECT_ID:UID');
  }
  const emulator=Boolean(process.env.FIREBASE_AUTH_EMULATOR_HOST || process.env.FIRESTORE_EMULATOR_HOST);
  if(emulator && (!projectId.startsWith('demo-') || !process.env.FIREBASE_AUTH_EMULATOR_HOST || !process.env.FIRESTORE_EMULATOR_HOST)) {
    throw new Error('Emulator bootstrap requires a demo project and both Auth/Firestore emulators.');
  }
  initializeApp({projectId}); // Application Default Credentials outside emulators.
  await bootstrapFirstAdmin(uid);
  console.log('Bootstrap completed. Refresh the target user session.');
}
main().catch(()=>{console.error('Bootstrap failed. Verify arguments, IAM credentials, target verification and existing bootstrap reservation.');process.exitCode=1;});
