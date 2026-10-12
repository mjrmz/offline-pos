import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/server.js';
import { makePasswordHash } from '../src/routes/admin.js';
import { createHash } from 'node:crypto';

test('health, malformed activation, admin guard and login', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  const app=createApp({query:async()=>{throw Error('query should not run');}});
  const server=app.listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    assert.deepEqual(await (await fetch(`${base}/healthz`)).json(),{status:'ok'});
    assert.equal((await fetch(`${base}/v1/activate`,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,400);
    assert.equal((await fetch(`${base}/admin/customers`)).status,401);
    assert.equal((await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'wrong'})})).status,401);
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    assert.equal(login.status,200);
    const cookie=login.headers.get('set-cookie').split(';')[0];
    assert.equal((await fetch(`${base}/admin/me`,{headers:{Cookie:cookie}})).status,200);
    assert.equal((await fetch(`${base}/admin/logout`,{method:'POST',headers:{Cookie:cookie}})).status,403);
  } finally { server.close(); }
});

test('admin can upgrade an existing license without changing its device binding', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  const queries=[];
  const client={query:async (sql, params=[])=>{
    queries.push([sql,params]);
    if (sql.startsWith('UPDATE licenses SET plan_id=')) return {rowCount:1,rows:[{id:params[0],plan_id:params[1]}]};
    return {rowCount:1,rows:[]};
  },release(){}};
  const server=createApp({connect:async()=>client}).listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    const cookie=login.headers.get('set-cookie').split(';')[0];
    const id='00000000-0000-0000-0000-000000000001';
    const response=await fetch(`${base}/admin/licenses/${id}/edition`,{method:'POST',headers:{Cookie:cookie,Origin:'http://localhost:5173','Content-Type':'application/json'},body:JSON.stringify({edition:'bir_ready'})});
    assert.equal(response.status,200);
    assert.equal((await response.json()).plan_id,'bir_ready');
    assert(queries.some(([sql,params])=>sql.startsWith('UPDATE licenses SET plan_id=') && params[0]===id && params[1]==='bir_ready'));
    assert(!queries.some(([sql])=>sql.includes('UPDATE devices')));
  } finally { server.close(); }
});

test('issue shows a one-time activation key and rotation replaces only its hash', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  const id='00000000-0000-0000-0000-000000000001';
  const customerId='00000000-0000-0000-0000-000000000002';
  const queries=[];
  let canRotate=true;
  const client={query:async(sql,params=[])=>{
    queries.push([sql,params]);
    if(sql.includes('INSERT INTO licenses')) return {rowCount:1,rows:[{id,status:'unactivated'}]};
    if(sql.includes('UPDATE licenses SET activation_key_hash')) return canRotate
      ? {rowCount:1,rows:[{id}]} : {rowCount:0,rows:[]};
    return {rowCount:1,rows:[]};
  },release(){}};
  const server=createApp({connect:async()=>client}).listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    const cookie=login.headers.get('set-cookie').split(';')[0];
    const headers={Cookie:cookie,Origin:'http://localhost:5173','Content-Type':'application/json'};
    const issued=await fetch(`${base}/admin/licenses`,{method:'POST',headers,
      body:JSON.stringify({customerId,planId:'non_bir',maxDevices:1,maxReactivations:3})});
    assert.equal(issued.status,201);
    assert.equal(issued.headers.get('cache-control'),'no-store');
    const first=await issued.json();
    assert.equal(first.id,id);
    assert.match(first.activationKey,/^[A-F0-9]{5}(?:-[A-F0-9]{5}){3}$/);
    const issueHash=queries.find(([sql])=>sql.includes('INSERT INTO licenses'))[1][2];
    assert.equal(issueHash,createHash('sha256').update(first.activationKey).digest('hex'));
    assert(!queries.some(([,params])=>params.includes(first.activationKey)));

    const rotated=await fetch(`${base}/admin/licenses/${id}/activation-key/rotate`,
      {method:'POST',headers});
    assert.equal(rotated.status,200);
    assert.equal(rotated.headers.get('cache-control'),'no-store');
    const second=await rotated.json();
    assert.equal(second.id,id);
    assert.notEqual(second.activationKey,first.activationKey);
    const rotateHash=queries.find(([sql])=>sql.includes('UPDATE licenses SET activation_key_hash'))[1][1];
    assert.equal(rotateHash,createHash('sha256').update(second.activationKey).digest('hex'));
    assert.notEqual(rotateHash,issueHash);
    assert(queries.some(([sql,params])=>sql.includes('admin_events') &&
      params.includes('license.activation_key_rotate')));
    assert(!queries.some(([sql])=>sql.includes('UPDATE devices')));

    canRotate=false;
    const unavailable=await fetch(`${base}/admin/licenses/${id}/activation-key/rotate`,
      {method:'POST',headers});
    assert.equal(unavailable.status,404);
    assert.equal((await unavailable.json()).activationKey,undefined);
  } finally { server.close(); }
});

test('activity includes administrative and activation events', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  let sql='';
  const row={id:'event-1',license_id:'license-1',device_id:null,event_type:'license.activation_key_rotate',reason:null,created_at:'2026-10-03T07:00:00Z'};
  const server=createApp({query:async query=>{sql=query;return {rows:[row]};}}).listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    const cookie=login.headers.get('set-cookie').split(';')[0];
    const response=await fetch(`${base}/admin/activity`,{headers:{Cookie:cookie}});
    assert.equal(response.status,200);
    assert.deepEqual(await response.json(),[row]);
    assert.match(sql,/FROM activation_events/);
    assert.match(sql,/FROM admin_events/);
    assert(!sql.includes('activation_key_hash'));
  } finally {server.close();}
});

test('admin read routes return JSON arrays with expected fields and require authentication', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  const id='00000000-0000-0000-0000-000000000001';
  const queries=[];
  const pool={query:async(sql)=>{
    queries.push(sql);
    if(sql.includes('FROM customers WHERE'))return {rows:[{id,business_name:'Existing shop'}]};
    if(sql.includes('FROM licenses l JOIN'))return {rows:[{id,customer_id:id,business_name:'Existing shop',status:'active',active_devices:1,max_devices:2}]};
    if(sql.includes('FROM devices d JOIN'))return {rows:[{id,license_id:id,business_name:'Existing shop',status:'active'}]};
    if(sql.includes('FROM devices WHERE'))return {rows:[{id,license_id:id,status:'active'}]};
    if(sql.includes('FROM activation_events'))return {rows:[{id,license_id:id,event_type:'activate'}]};
    if(sql.includes('FROM plans'))return {rows:[{id:'non_bir',display_name:'Non-BIR'}]};
    return {rows:[]};
  }};
  const server=createApp(pool).listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    assert.equal((await fetch(`${base}/admin/licenses`)).status,401);
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    const cookie=login.headers.get('set-cookie').split(';')[0];
    for(const [path,field] of [
      ['/admin/customers','business_name'],['/admin/licenses','active_devices'],
      ['/admin/devices','business_name'],[`/admin/licenses/${id}/devices`,'status'],
      ['/admin/activity','event_type'],['/admin/plans','display_name']
    ]){
      const response=await fetch(`${base}${path}`,{headers:{Cookie:cookie}});
      assert.equal(response.status,200,path);
      assert.match(response.headers.get('content-type'),/application\/json/,path);
      const data=await response.json();
      assert(Array.isArray(data),path);
      assert.equal(data.length,1,path);
      assert(field in data[0],path);
    }
    const missing=await fetch(`${base}/admin/missing`,{headers:{Cookie:cookie}});
    assert.equal(missing.status,404);
    assert.match(missing.headers.get('content-type'),/application\/json/);
    assert.equal((await missing.json()).error,'Route not found');
    assert(queries.some(sql=>sql.includes('FROM devices d JOIN')));
  } finally {server.close();}
});

test('customer creation and license/device mutation routes preserve JSON contracts', async () => {
  process.env.ADMIN_USERNAME='test-admin';
  process.env.ADMIN_PASSWORD_HASH=makePasswordHash('test-password-123');
  process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
  process.env.ADMIN_ORIGIN='http://localhost:5173';
  const id='00000000-0000-0000-0000-000000000001';
  const client={query:async(sql,params=[])=>{
    if(sql.includes('UPDATE licenses SET status'))return {rowCount:1,rows:[{id}]};
    if(sql.includes('UPDATE devices SET status'))return {rowCount:1,rows:[{id,license_id:id}]};
    return {rowCount:1,rows:[]};
  },release(){}};
  const pool={query:async(sql,params)=>{
    if(sql.includes('INSERT INTO customers'))return {rows:[{id,business_name:params[0],contact_phone:params[2],notes:params[3]}]};
    return {rows:[]};
  },connect:async()=>client};
  const server=createApp(pool).listen(0);
  try {
    const base=`http://127.0.0.1:${server.address().port}`;
    const login=await fetch(`${base}/admin/login`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'test-admin',password:'test-password-123'})});
    const cookie=login.headers.get('set-cookie').split(';')[0];
    const headers={Cookie:cookie,Origin:'http://localhost:5173','Content-Type':'application/json'};
    const created=await fetch(`${base}/admin/customers`,{method:'POST',headers,body:JSON.stringify({businessName:'New shop',contactPhone:'12345',notes:'Call before opening'})});
    assert.equal(created.status,201);
    assert.match(created.headers.get('content-type'),/application\/json/);
    assert.deepEqual(await created.json(),{id,business_name:'New shop',contact_phone:'12345',notes:'Call before opening'});
    for(const path of [`/admin/licenses/${id}/revoke`,`/admin/devices/${id}/deactivate`]){
      const result=await fetch(`${base}${path}`,{method:'POST',headers});
      assert.equal(result.status,200,path);
      assert.match(result.headers.get('content-type'),/application\/json/,path);
      assert.deepEqual(await result.json(),{ok:true},path);
    }
  } finally {server.close();}
});
