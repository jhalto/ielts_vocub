const {spawnSync}=require('node:child_process');
const {resolve}=require('node:path');
// Resolve paths from this script so moving the apps does not depend on shell cwd.
const studentRoot=resolve(__dirname,'../../..');
for(const args of [
 ['firebase/functions/test/seed-offline.cjs'],
 ['--test','firebase/test/firestore.test.mjs','firebase/test/storage.test.mjs'],
 ['--test','firebase/functions/test/account.emulator.cjs'],
 ['--test','firebase/functions/test/content.emulator.cjs'],
]) {
 const result=spawnSync(process.execPath,args,{stdio:'inherit',env:process.env,cwd:studentRoot});
 if(result.status!==0) process.exit(result.status??1);
}
