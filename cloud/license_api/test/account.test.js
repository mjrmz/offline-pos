import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createApp} from '../src/server.js';
import {makePasswordHash} from '../src/routes/admin.js';

const id='00000000-0000-0000-0000-000000000011';
const sid='00000000-0000-0000-0000-000000000022';
const origin='http://localhost:5173';
function fixture(){
  process.env.ADMIN_USERNAME='render-admin';process.env.ADMIN_PASSWORD_HASH=makePasswordHash('render-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';process.env.ADMIN_ORIGIN=origin;
  let account=null, revoked=false;const events=[];
  const query=async(sql,p=[])=>{
    if(sql.startsWith('SELECT * FROM admin_accounts'))return {rows:account?.enabled&&account.username.toLowerCase()===p[0].toLowerCase()?[account]:[],rowCount:account?1:0};
    if(sql.includes("SELECT id FROM admin_accounts WHERE role='owner'"))return {rows:account?[{id}]:[],rowCount:account?1:0};
    if(sql.startsWith('INSERT INTO admin_accounts')){if(account){const e=Error('duplicate');e.code='23505';throw e;}account={id,username:p[0],display_name:p[1],password_hash:p[2],role:'owner',enabled:true,last_login_at:null,password_changed_at:new Date().toISOString()};return {rows:[account],rowCount:1};}
    if(sql.startsWith('INSERT INTO admin_sessions')){revoked=false;return {rows:[{id:sid}],rowCount:1};}
    if(sql.startsWith('SELECT a.*,s.id AS session_id'))return {rows:account&&!revoked?[{...account,session_id:sid}]:[],rowCount:account&&!revoked?1:0};
    if(sql.startsWith('UPDATE admin_accounts SET last_login_at')){account.last_login_at=new Date().toISOString();return {rows:[],rowCount:1};}
    if(sql.startsWith('UPDATE admin_accounts SET username')){if(p[0]==='taken'){const e=Error('duplicate');e.code='23505';throw e;}Object.assign(account,{username:p[0],display_name:p[1]});return {rows:[account],rowCount:1};}
    if(sql.startsWith('UPDATE admin_accounts SET password_hash')){if(p.length===3&&p[2]!==account.password_hash)return {rows:[],rowCount:0};account.password_hash=p[0];return {rows:[account],rowCount:1};}
    if(sql.startsWith('UPDATE admin_sessions SET revoked_at')){if(p.length===1)revoked=true;return {rows:[],rowCount:1};}
    if(sql.startsWith('INSERT INTO admin_events')){events.push(p);return {rows:[],rowCount:1};}
    if(['BEGIN','COMMIT','ROLLBACK'].includes(sql))return {rows:[],rowCount:0};
    throw Error(`Unexpected query: ${sql}`);
  };
  return {pool:{query,connect:async()=>({query,release(){}})},events,get account(){return account;}};
}
const post=(base,path,body,cookie)=>fetch(base+path,{method:'POST',headers:{Origin:origin,'Content-Type':'application/json',...(cookie?{Cookie:cookie}:{})},body:JSON.stringify(body)});
test('bootstrap, account edits, password and recovery enforce auth and record safe audit events',async()=>{
  const db=fixture();const server=createApp(db.pool).listen(0);
  try{
    const base=`http://127.0.0.1:${server.address().port}`;
    assert.equal((await fetch(base+'/admin/account')).status,401);
    const boot=await post(base,'/admin/login',{username:'render-admin',password:'render-password-123'});
    assert.equal(boot.status,200);assert.equal((await boot.json()).bootstrap,true);
    const bootCookie=boot.headers.get('set-cookie').split(';')[0];
    const created=await post(base,'/admin/account/bootstrap',{username:'owner',displayName:'Owner',password:'initial-password-123'},bootCookie);
    assert.equal(created.status,201);
    assert.equal((await post(base,'/admin/account/recover',{newPassword:'unauthorized-reset-123'},bootCookie)).status,401);
    const recovery=await post(base,'/admin/login',{username:'render-admin',password:'render-password-123'});
    assert.equal((await recovery.json()).recovery,true);
    const recoveryCookie=recovery.headers.get('set-cookie').split(';')[0];
    assert.equal((await fetch(base+'/admin/plans',{headers:{Cookie:recoveryCookie}})).status,403);
    const login=await post(base,'/admin/login',{username:'owner',password:'initial-password-123'});
    assert.equal(login.status,200);const cookie=login.headers.get('set-cookie').split(';')[0];
    const headers={Origin:origin,Cookie:cookie,'Content-Type':'application/json'};
    assert.equal((await fetch(base+'/admin/account',{method:'PATCH',headers:{...headers,Origin:'https://wrong.example'},body:JSON.stringify({username:'owner2',displayName:'New Owner'})})).status,403);
    const changed=await fetch(base+'/admin/account',{method:'PATCH',headers,body:JSON.stringify({username:'owner2',displayName:'New Owner'})});
    assert.equal(changed.status,200);assert.equal((await changed.json()).account.username,'owner2');
    assert.equal((await fetch(base+'/admin/account',{method:'PATCH',headers,body:JSON.stringify({username:'taken',displayName:'Owner'})})).status,409);
    assert.equal((await post(base,'/admin/account/password',{currentPassword:'wrong',newPassword:'new-password-123'},cookie)).status,403);
    assert.equal((await post(base,'/admin/account/password',{currentPassword:'initial-password-123',newPassword:'new-password-123'},cookie)).status,200);
    assert.equal((await post(base,'/admin/login',{username:'owner2',password:'initial-password-123'})).status,401);
    assert.equal((await post(base,'/admin/login',{username:'owner2',password:'new-password-123'})).status,200);
    assert.equal((await post(base,'/admin/account/recover',{newPassword:'recovered-password-123'},recoveryCookie)).status,200);
    assert.equal((await fetch(base+'/admin/me',{headers:{Cookie:cookie}})).status,401);
    assert.equal((await post(base,'/admin/login',{username:'owner2',password:'recovered-password-123'})).status,200);
    const actions=db.events.map(x=>x[1]);
    for(const action of ['admin.account_bootstrap','admin.username_changed','admin.password_changed','admin.password_recovered','admin.login'])assert(actions.includes(action));
    assert(!JSON.stringify(db.events).includes('new-password-123'));
  }finally{server.close();}
});
