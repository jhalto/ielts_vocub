const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateBody,authorizeAdmin}=require('../lib/account');
test('profile input rejects role injection, invalid names and unknown actions',()=>{
 for(const body of [null,[],{}, {action:'initializeProfile',role:'super_admin'}, {action:'initializeProfile',name:''}, {action:'initializeProfile',name:'x'.repeat(101)}, {action:'adminAccess',name:'x'}]) assert.throws(()=>validateBody(body));
 assert.deepEqual(validateBody({action:'initializeProfile',name:' Name '}),{action:'initializeProfile',name:'Name'});
});
test('privileged auth requires enabled verified user and current matching claims',()=>{
 for(const [token,current] of [
  [{role:'super_admin'},{disabled:true,emailVerified:true,customClaims:{role:'super_admin'}}],
  [{role:'super_admin'},{disabled:false,emailVerified:false,customClaims:{role:'super_admin'}}],
  [{role:'super_admin'},{disabled:false,emailVerified:true,customClaims:{role:'student'}}],
  [{role:'content_manager'},{disabled:false,emailVerified:true,customClaims:{role:'super_admin'}}],
 ]) assert.throws(()=>authorizeAdmin(token,current));
 assert.equal(authorizeAdmin({role:'content_manager'},{disabled:false,emailVerified:true,customClaims:{role:'content_manager'}}),'content_manager');
});
