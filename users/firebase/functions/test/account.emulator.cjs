const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {initializeApp,deleteApp}=require('firebase-admin/app');
const {getAuth}=require('firebase-admin/auth');
const {getFirestore}=require('firebase-admin/firestore');
const {bootstrapFirstAdmin}=require('../lib/bootstrap');
let app;
const project='demo-vocabulary';
const base=`http://127.0.0.1:15001/${project}/us-central1/accountApi`;
before(()=>{
 if(!process.env.FIREBASE_AUTH_EMULATOR_HOST || !process.env.FIRESTORE_EMULATOR_HOST)throw new Error('Emulators required');
 app=initializeApp({projectId:project});
});
after(async()=>{await deleteApp(app);});
async function create(email,verified=false){
 const auth=getAuth();
 const user=await auth.createUser({email,password:'Test-password-123!',emailVerified:verified,displayName:'Test Learner'});
 return {user,token:await login(email)};
}
async function login(email){
 const response=await fetch(`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password:'Test-password-123!',returnSecureToken:true})});
 const data=await response.json();assert.ok(data.idToken,JSON.stringify(data));return data.idToken;
}
async function call(token,body){
 const response=await fetch(base,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
 return {status:response.status,body:await response.json()};
}
test('authenticated profile API is idempotent and derives trusted identity',async()=>{
 const {user,token}=await create('profile@example.test');
 assert.equal((await call(null,{action:'initializeProfile'})).status,401);
 assert.equal((await call(token,{action:'initializeProfile',uid:'victim',role:'super_admin'})).status,400);
 const first=await call(token,{action:'initializeProfile'});assert.equal(first.status,200);assert.equal(first.body.uid,user.uid);
 const ref=getFirestore().doc(`users/${user.uid}`);const initial=(await ref.get()).data();
 const second=await call(token,{action:'initializeProfile',name:'Updated Name'});assert.equal(second.status,200);
 const updated=(await ref.get()).data();assert.equal(updated.name,'Updated Name');assert.ok(initial.createdAt.isEqual(updated.createdAt));assert.equal(updated.role,undefined);
 assert.equal((await call(token,{action:'adminAccess'})).status,403);
 await getAuth().updateUser(user.uid,{disabled:true});assert.equal((await call(token,{action:'initializeProfile'})).status,401);
});
test('bootstrap is resumable, unique and requires verified enabled target; admin API checks fresh claims',async()=>{
 const {user,token}=await create('admin@example.test',true);
 const other=await create('other@example.test',true);
 const unverified=await create('unverified@example.test');
 await assert.rejects(bootstrapFirstAdmin(unverified.user.uid));
 await bootstrapFirstAdmin(user.uid);await bootstrapFirstAdmin(user.uid);
 await assert.rejects(bootstrapFirstAdmin(other.user.uid));
 assert.equal((await call(token,{action:'adminAccess'})).body.code,'claims-stale');
 const fresh=await login(user.email);const allowed=await call(fresh,{action:'adminAccess'});
 assert.equal(allowed.status,200);assert.equal(allowed.body.role,'super_admin');
 const logs=await getFirestore().collection('adminAudit').where('action','==','bootstrap_super_admin').get();assert.equal(logs.size,1);
 await getAuth().setCustomUserClaims(user.uid,{role:'student'});
 assert.equal((await call(fresh,{action:'adminAccess'})).status,403);
});
