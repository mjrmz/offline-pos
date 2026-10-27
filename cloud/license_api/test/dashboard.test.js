import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { createApp } from '../src/server.js';
import { makePasswordHash } from '../src/routes/admin.js';

const builtIndex = new URL('../../admin_dashboard/dist/index.html', import.meta.url);

test('built dashboard shares the API origin without swallowing API routes',
  { skip: !existsSync(builtIndex) }, async () => {
    process.env.ADMIN_USERNAME = 'test-admin';
    process.env.ADMIN_PASSWORD_HASH = makePasswordHash('test-password-123');
    process.env.ADMIN_AUTH_SECRET = 'test-only-secret-with-more-than-32-characters';
    const server = createApp({ query: async () => { throw Error('Unexpected database query'); } }).listen(0);
    try {
      const base = `http://127.0.0.1:${server.address().port}`;
      process.env.ADMIN_ORIGIN = base;
      const dashboard = await fetch(base);
      assert.equal(dashboard.status, 200);
      assert.match(dashboard.headers.get('content-type'), /text\/html/);
      const html = await dashboard.text();
      const assetPath = html.match(/src="(\/assets\/[^\"]+\.js)"/)?.[1];
      assert.ok(assetPath, 'Vite script asset is referenced from the same origin');
      const asset = await fetch(`${base}${assetPath}`);
      assert.equal(asset.status, 200);
      const script = await asset.text();
      assert.doesNotMatch(script, /http:\/\/localhost:3000|offline-pos-wtl8\.onrender\.com/);
      assert.match(script, /\/admin\/me/);

      assert.deepEqual(await (await fetch(`${base}/healthz`)).json(), { status: 'ok' });
      assert.equal((await fetch(`${base}/admin/me`)).status, 401);
      const login = await fetch(`${base}/admin/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base },
        body: JSON.stringify({ username: 'test-admin', password: 'test-password-123' }),
      });
      assert.equal(login.status, 200);
      assert.match(login.headers.get('set-cookie'), /SameSite=Strict/i);
      const cookie = login.headers.get('set-cookie').split(';')[0];
      assert.equal((await fetch(`${base}/admin/me`, { headers: { Cookie: cookie } })).status, 200);
      assert.equal((await fetch(`${base}/admin/logout`, {
        method: 'POST', headers: { Cookie: cookie, Origin: 'https://wrong.example' },
      })).status, 403);
      assert.equal((await fetch(`${base}/admin/logout`, {
        method: 'POST', headers: { Cookie: cookie, Origin: base },
      })).status, 200);
      assert.equal((await fetch(`${base}/v1/activate`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
      })).status, 400);
      const unknown = await fetch(`${base}/v1/unknown`);
      assert.equal(unknown.status, 404);
      assert.deepEqual(await unknown.json(), { error: 'Route not found' });
    } finally {
      server.close();
    }
  });
