import { readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import 'dotenv/config';
import nacl from 'tweetnacl';
import { canonicalPayload } from '../src/services/licenseSigningService.js';

const [apiOrigin, adminOrigin, usernameOverride] = process.argv.slice(2);
const adminUsername = usernameOverride ?? process.env.ADMIN_USERNAME;
if (!apiOrigin?.startsWith('https://') || !adminOrigin || !adminUsername) {
  throw new Error('Usage: node scripts/hosted-smoke.mjs <https-api-origin> <admin-origin> [admin-username]');
}
const publicKey = Buffer.from(readFileSync('license-public.key', 'utf8').trim(), 'base64');
if (publicKey.length !== 32) throw new Error('Existing public key is invalid');
const password = readFileSync(0, 'utf8').trimEnd();
if (!password) throw new Error('Admin password is required on stdin');

async function request(path, body, cookie) {
  const response = await fetch(new URL(path, apiOrigin), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: adminOrigin,
      ...(cookie ? { Cookie: cookie } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60000),
  });
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
  return { response, data: await response.json() };
}

async function read(path, cookie) {
  const response = await fetch(new URL(path, apiOrigin), {
    headers: { Cookie: cookie },
    signal: AbortSignal.timeout(60000),
  });
  if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
  return response.json();
}

const login = await request('/admin/login', { username: adminUsername, password });
const cookie = login.response.headers.get('set-cookie')?.split(';', 1)[0];
if (!cookie?.startsWith('admin_session=')) throw new Error('Admin login returned no session cookie');
const plans = await read('/admin/plans', cookie);
if (!Array.isArray(plans) || !['non_bir', 'bir_ready'].every(id => plans.some(p => p.id === id))) {
  throw new Error('Expected migrated licensing plans were not found');
}

const customer = await request('/admin/customers', {
  businessName: `RC hosted signing test ${new Date().toISOString()}`,
}, cookie);
const issued = await request('/admin/licenses', {
  customerId: customer.data.id,
  planId: 'non_bir',
  maxDevices: 3,
  maxReactivations: 3,
  expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
}, cookie);
const activationKey = issued.data.activationKey;
if (typeof activationKey !== 'string') throw new Error('License issuance returned no activation key');

const fingerprint = randomBytes(32).toString('hex');
const activated = await request('/v1/activate', {
  activationKey,
  deviceFingerprint: fingerprint,
});
const devices = await read(`/admin/licenses/${issued.data.id}/devices`, cookie);
if (!Array.isArray(devices) || devices.length !== 1 || devices[0].device_fingerprint !== fingerprint) {
  throw new Error('Activated device record was not found');
}
const { payload, signatureBase64 } = activated.data;
const signature = Buffer.from(signatureBase64, 'base64');
if (payload.deviceId !== fingerprint || signature.length !== 64 ||
    !nacl.sign.detached.verify(Buffer.from(canonicalPayload(payload)), signature, publicKey)) {
  throw new Error('Hosted signature did not match the existing POS public key');
}
console.log('HOSTED_SIGNING=PASS');
console.log('HOSTED_SCHEMA_API_CHECK=PASS');
console.log('TEST_LICENSE_EXPIRES_IN=24 hours');
console.log(`TEST_ACTIVATION_KEY=${activationKey}`);
