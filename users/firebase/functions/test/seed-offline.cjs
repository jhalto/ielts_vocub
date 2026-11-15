// Synthetic demo-only fixtures, never reviewed production vocabulary.
const {initializeApp}=require('firebase-admin/app');
const {getFirestore,FieldValue}=require('firebase-admin/firestore');
async function main(){
 const host=process.env.FIRESTORE_EMULATOR_HOST??'';
 if(!/^(127\.0\.0\.1|localhost):\d+$/.test(host))throw new Error('A loopback Firestore emulator is required.');
 initializeApp({projectId:'demo-vocabulary'});
 const db=getFirestore();
 const existing=await db.collection('words').get();
 if(existing.docs.some(doc=>!doc.id.startsWith('offline-fixture-')))throw new Error('Refusing to overwrite non-fixture emulator content.');
 const revision=Date.now();
 const counts={};
 for(const category of ['basic','intermediate','advanced'])for(const difficulty of ['easy','medium','advanced'])counts[`${category}/${difficulty}`]=0;
 const batch=db.batch();
 for(let i=0;i<4;i++){
  const id=`offline-fixture-${i}`;counts['basic/easy']++;
  batch.set(db.doc(`words/${id}`),{spelling:`Fixture ${i}`,pronunciation:'Test fixture',category:'basic',difficulty:'easy',ordering:i,isPublished:true,isRetired:false,revision,updatedAt:FieldValue.serverTimestamp(),senses:[{id:`sense-${i}`,partOfSpeech:'noun',englishMeaning:'Synthetic test fixture, not production content.',bengaliMeaning:'\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',ordering:0,examples:[{english:'Used only for offline acceptance testing.',bengali:'\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be'}]}]});
 }
 batch.set(db.doc('contentManifest/current'),{schemaVersion:1,currentRevision:revision,oldestRetainedRevision:revision,groupCounts:counts,updatedAt:FieldValue.serverTimestamp()});
 await batch.commit();console.log('Created four synthetic demo-only offline fixtures.');
}
main().catch(e=>{console.error(e.message);process.exitCode=1;});
