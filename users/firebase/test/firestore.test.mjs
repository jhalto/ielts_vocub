import {readFileSync} from 'node:fs';
import {before, after, beforeEach, test} from 'node:test';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {doc, setDoc, getDoc, getDocs, collection, query, where} from 'firebase/firestore';
let env;
before(async () => {
 env = await initializeTestEnvironment({projectId:'demo-vocabulary',firestore:{rules:readFileSync(new URL('../firestore.rules',import.meta.url),'utf8')},storage:{rules:readFileSync(new URL('../storage.rules',import.meta.url),'utf8')}});
});
after(async()=>{await env?.cleanup();});
beforeEach(async()=>{
 await env.clearFirestore();
 await env.withSecurityRulesDisabled(async context=>{
  const db=context.firestore();
  for (const [id,isPublished,isRetired] of [['published',true,false],['draft',false,false],['retired',true,true]]) {
   await setDoc(doc(db,'words',id),{isPublished,isRetired});
  }
  for (const path of ['users/alice','users/alice/progress/word','users/alice/settings/preferences','users/alice/syncOps/op','adminAudit/event','importJobs/job','contentManifest/current','contentChanges/1']) {
   await setDoc(doc(db,path),{test:true});
  }
 });
});
test('guest reads only published non-retired content and constrained lists',async()=>{
 const db=env.unauthenticatedContext().firestore();
 await assertSucceeds(getDoc(doc(db,'words/published')));
 for (const id of ['draft','retired']) await assertFails(getDoc(doc(db,`words/${id}`)));
 await assertFails(getDocs(collection(db,'words')));
 await assertSucceeds(getDocs(query(collection(db,'words'),where('isPublished','==',true),where('isRetired','==',false))));
 for(const path of ['contentManifest/current','contentChanges/1']) await assertSucceeds(getDoc(doc(db,path)));
});
test('owner reads private profile and progress; cross-user and ledger denied',async()=>{
 const db=env.authenticatedContext('alice').firestore();
 for(const path of ['users/alice','users/alice/progress/word','users/alice/settings/preferences']) await assertSucceeds(getDoc(doc(db,path)));
 for(const path of ['users/bob','users/bob/progress/word','users/alice/syncOps/op','adminAudit/event','importJobs/job']) await assertFails(getDoc(doc(db,path)));
 await assertFails(getDocs(collection(db,'users')));
});
test('claims authorize editor reads, never privileged writes',async()=>{
 for(const role of ['student','content_manager','super_admin']) {
  const db=env.authenticatedContext('admin',{role}).firestore();
  const check=role==='student'?assertFails:assertSucceeds;
  await check(getDoc(doc(db,'words/draft')));
  await check(getDoc(doc(db,'importJobs/job')));
  await (role==='super_admin'?assertSucceeds:assertFails)(getDoc(doc(db,'adminAudit/event')));
  for(const path of ['words/published','users/admin','users/admin/progress/word','contentChanges/2','contentManifest/current','adminAudit/new','importJobs/new','unknown/path']) {
   await assertFails(setDoc(doc(db,path),{role:'super_admin'}));
  }
 }
});
