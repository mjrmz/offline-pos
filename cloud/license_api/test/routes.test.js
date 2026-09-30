import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/server.js';
import { makePasswordHash } from '../src/routes/admin.js';

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
