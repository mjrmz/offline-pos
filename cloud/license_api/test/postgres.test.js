import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';
import nacl from 'tweetnacl';
import { createApp } from '../src/server.js';
import { canonicalPayload } from '../src/services/licenseSigningService.js';

test('PostgreSQL activation concurrency, retry, transfer, revocation and signed payload', {skip: !process.env.TEST_DATABASE_URL}, async () => {
  const schema=`license_test_${randomBytes(6).toString('hex')}`;
  const admin=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
  await admin.query(`CREATE SCHEMA ${schema}`);
  const pool=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL, options:`-c search_path=${schema}`});
  let server;
  try {
    await pool.query(readFileSync(new URL('../src/db/migrations/001_initial.sql',import.meta.url),'utf8'));
    const customer=(await pool.query("INSERT INTO customers(business_name) VALUES('Test shop') RETURNING id")).rows[0];
    const key='AAAAA-BBBBB-CCCCC-DDDDD';
    const hash=createHash('sha256').update(key).digest('hex');
    const license=(await pool.query('INSERT INTO licenses(customer_id,plan_id,activation_key_hash,max_devices) VALUES($1,$2,$3,1) RETURNING id',[customer.id,'non_bir',hash])).rows[0];
    const pair=nacl.sign.keyPair();
    process.env.LICENSE_SIGNING_PRIVATE_KEY=Buffer.from(pair.secretKey).toString('base64');
    process.env.ADMIN_USERNAME='test-admin';
    process.env.ADMIN_PASSWORD_HASH='unused:unused';
    process.env.ADMIN_AUTH_SECRET='test-only-secret-with-more-than-32-characters';
    process.env.ADMIN_ORIGIN='http://localhost:5173';
    server=createApp(pool).listen(0);
    const url=`http://127.0.0.1:${server.address().port}/v1/activate`;
    const activate=deviceFingerprint=>fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({activationKey:key,deviceFingerprint})});
    const a='a'.repeat(64),b='b'.repeat(64);
    const results=await Promise.all([activate(a),activate(b)]);
    assert.deepEqual(results.map(x=>x.status).sort(),[200,403]);
    const winner=results[0].status===200?a:b, loser=winner===a?b:a;
    const signed=await results[results[0].status===200?0:1].json();
    assert.equal(nacl.sign.detached.verify(Buffer.from(canonicalPayload(signed.payload)),Buffer.from(signed.signatureBase64,'base64'),pair.publicKey),true);
    assert.equal((await activate(winner)).status,200);
    assert.equal((await pool.query("SELECT count(*)::int AS n FROM devices WHERE license_id=$1 AND status='active'",[license.id])).rows[0].n,1);
    const device=(await pool.query('SELECT id FROM devices WHERE license_id=$1 AND device_fingerprint=$2',[license.id,winner])).rows[0];
    await pool.query("UPDATE devices SET status='deactivated',deactivated_at=now() WHERE id=$1",[device.id]);
    assert.equal((await activate(loser)).status,200);
    await pool.query("UPDATE licenses SET status='revoked' WHERE id=$1",[license.id]);
    const rejected=await activate(winner);
    assert.equal(rejected.status,403);
    assert.equal((await rejected.json()).code,'revoked');
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM activation_events WHERE license_id=$1',[license.id])).rows[0].n,5);
  } finally {
    if(server) await new Promise(resolve=>server.close(resolve));
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  }
});
