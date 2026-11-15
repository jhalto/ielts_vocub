import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {initializeTestEnvironment, assertFails} from '@firebase/rules-unit-testing';
import {ref, uploadBytes, getBytes} from 'firebase/storage';
test('storage denies guest and owner access until media feature exists',async()=>{
 const env=await initializeTestEnvironment({projectId:'demo-vocabulary',storage:{rules:readFileSync(new URL('../storage.rules',import.meta.url),'utf8')}});
 try {
  for(const context of [env.unauthenticatedContext(),env.authenticatedContext('alice')]) {
   const file=ref(context.storage(),'users/alice/photo.png');
   await assertFails(uploadBytes(file,new Uint8Array([1,2,3])));
   await assertFails(getBytes(file));
  }
 } finally { await env.cleanup(); }
});
