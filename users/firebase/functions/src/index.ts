import { initializeApp } from 'firebase-admin/app';
import { setGlobalOptions } from 'firebase-functions/v2';
initializeApp();
setGlobalOptions({ region: 'us-central1', maxInstances: 5 });
export { accountApi } from './account';
export { contentApi } from './content';
export { progressApi } from './progress';
export { importApi } from './imports';
export { userAdminApi } from './user_admin';
