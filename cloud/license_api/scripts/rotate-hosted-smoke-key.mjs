import { readFileSync } from 'node:fs';
import 'dotenv/config';

const [apiOrigin, adminOrigin, usernameOverride] = process.argv.slice(2);
const username = usernameOverride ?? process.env.ADMIN_USERNAME;
if (!apiOrigin?.startsWith('https://') || !adminOrigin || !username) {
  throw new Error('Usage: node scripts/rotate-hosted-smoke-key.mjs <https-api-origin> <admin-origin> [admin-username]');
}
const password = readFileSync(0, 'utf8').trimEnd();
if (!password) throw new Error('Admin password is required on stdin');

async function call(path, method, body, cookie) {
  const response = await fetch(new URL(path, apiOrigin), {
    method,
    headers: {
      Origin: adminOrigin,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(cookie ? { Cookie: cookie } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(60000),
  });
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
  return { response, data: await response.json() };
}

const login = await call('/admin/login', 'POST', { username, password });
const cookie = login.response.headers.get('set-cookie')?.split(';', 1)[0];
if (!cookie?.startsWith('admin_session=')) throw new Error('Admin login returned no session cookie');

const licenses = (await call('/admin/licenses', 'GET', null, cookie)).data;
if (!Array.isArray(licenses)) throw new Error('Admin license listing was invalid');
const candidates = licenses.filter(license =>
  license.business_name?.startsWith('RC hosted signing test ') &&
  license.max_devices === 3 && license.active_devices === 2 &&
  license.status !== 'revoked' && Date.parse(license.expires_at) > Date.now());
if (candidates.length !== 1) {
  throw new Error(`Expected exactly one active two-device RC test license; found ${candidates.length}. No key was rotated.`);
}
const rotated = (await call(`/admin/licenses/${candidates[0].id}/activation-key/rotate`, 'POST', {}, cookie)).data;
if (typeof rotated.activationKey !== 'string') throw new Error('Rotation returned no activation key');
console.log('TEST_KEY_ROTATION=PASS');
console.log(`TEST_ACTIVATION_KEY=${rotated.activationKey}`);
