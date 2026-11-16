import { getAuth, DecodedIdToken } from 'firebase-admin/auth';
import { getAppCheck } from 'firebase-admin/app-check';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { onRequest } from 'firebase-functions/v2/https';

import { AccountError } from './errors';
import { assertManagedAccess } from './managed_access';
export { AccountError } from './errors';
export function validateBody(body: unknown): { action: string; name?: string } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new AccountError(400, 'invalid-input');
  const input = body as Record<string, unknown>;
  if (Object.keys(input).some(key => !['action','name'].includes(key))) throw new AccountError(400, 'invalid-input');
  if (!['initializeProfile','adminAccess'].includes(input.action as string)) throw new AccountError(400, 'invalid-input');
  if (input.name !== undefined && (input.action !== 'initializeProfile' || typeof input.name !== 'string' || !input.name.trim() || input.name.trim().length > 100)) {
    throw new AccountError(400, 'invalid-input');
  }
  return { action: input.action as string, ...(typeof input.name === 'string' ? {name:input.name.trim()} : {}) };
}
export function authorizeAdmin(token: DecodedIdToken, current: { disabled: boolean; emailVerified: boolean; customClaims?: Record<string,unknown> }): string {
  if(current.disabled) throw new AccountError(401,'user-disabled');
  if(!current.emailVerified) throw new AccountError(403,'email-unverified');
  const role = current.customClaims?.role;
  if(!['super_admin','content_manager'].includes(role as string)) throw new AccountError(403,'permission-denied');
  if(token.role !== role) throw new AccountError(403,'claims-stale');
  return role as string;
}
export async function accountAction(uid:string, token:DecodedIdToken, body:unknown):Promise<Record<string,unknown>> {
  const input=validateBody(body);
  const auth=getAuth();
  let user=await auth.getUser(uid);
  await assertManagedAccess(token);
  if(user.disabled) throw new AccountError(401,'user-disabled');
  const db=getFirestore();
  // Per-UID bounded request rate; retry does not bypass the limit.
  const rate=db.doc(`accountRateLimits/${uid}`);
  await db.runTransaction(async tx=>{
    const snapshot=await tx.get(rate);
    const data=snapshot.data();
    const window=Math.floor(Date.now()/60000);
    const count=data?.window===window ? Number(data.count) : 0;
    if(count>=60) throw new AccountError(429,'rate-limited');
    tx.set(rate,{window,count:count+1});
  });
  if(input.action==='adminAccess') return {role:authorizeAdmin(token,user)};
  if(input.name !== undefined) user=await auth.updateUser(uid,{displayName:input.name});
  const ref=db.doc(`users/${uid}`);
  return db.runTransaction(async tx=>{
    const snapshot=await tx.get(ref);
    const existing=snapshot.data();
    const profile={uid:user.uid,name:user.displayName ?? '',email:user.email ?? '',
      photoUrl:user.photoURL ?? null,preferredLanguage:existing?.preferredLanguage ?? 'en'};
    tx.set(ref,{...profile,createdAt:existing?.createdAt ?? FieldValue.serverTimestamp(),updatedAt:FieldValue.serverTimestamp()});
    return profile;
  });
}
export const accountApi=onRequest({cors:true,timeoutSeconds:30,maxInstances:5},async(req,res)=>{
  res.set('Cache-Control','no-store');
  if(req.method!=='POST') {res.status(405).json({code:'method-not-allowed'});return;}
  if(req.rawBody.length>8192) {res.status(413).json({code:'payload-too-large'});return;}
  try {
    const header=req.headers.authorization;
    if(!header?.startsWith('Bearer ')) throw new AccountError(401,'unauthenticated');
    let token:DecodedIdToken;
    try { token=await getAuth().verifyIdToken(header.slice(7),true); }
    catch(e) {
      const code=(e as {code?:string}).code;
      throw new AccountError(401,code==='auth/id-token-revoked'?'session-revoked':code==='auth/user-disabled'?'user-disabled':'unauthenticated');
    }
    // Explicit opt-in until each shipped platform has a configured attestation provider.
    // Auth and role checks always apply; App Check is additional defense only.
    if(process.env.REQUIRE_ACCOUNT_APP_CHECK==='true') {
      const attestation=req.header('X-Firebase-AppCheck');
      if(!attestation) throw new AccountError(403,'app-check-required');
      try {await getAppCheck().verifyToken(attestation);} catch {throw new AccountError(403,'app-check-invalid');}
    }
    res.json(await accountAction(token.uid,token,req.body));
  } catch(e) {
    if(e instanceof AccountError) {res.status(e.status).json({code:e.code});return;}
    // No raw auth errors, tokens or private payloads in responses or logs.
    res.status(503).json({code:'service-unavailable'});
  }
});
