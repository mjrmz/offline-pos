import nacl from 'tweetnacl';
import { randomUUID } from 'node:crypto';

export function canonicalPayload(p) {
  const keys = ['licenseId', 'customerId', 'edition', 'deviceId', 'features', 'issuedAt', 'expiresAt', 'nonce'];
  if (Object.keys(p).length !== keys.length || keys.some(k => !Object.hasOwn(p, k))) throw new Error('Invalid payload fields');
  return JSON.stringify(Object.fromEntries(keys.map(k => [k, p[k]])));
}

export function signingKeyFromEnvironment() {
  const raw = process.env.LICENSE_SIGNING_PRIVATE_KEY;
  if (!raw) throw new Error('LICENSE_SIGNING_PRIVATE_KEY is required');
  const bytes = Buffer.from(raw, 'base64');
  if (bytes.length !== 64) throw new Error('LICENSE_SIGNING_PRIVATE_KEY must be a 64-byte Ed25519 secret key');
  return bytes;
}

export function signLicense({ licenseId, customerId, edition, deviceId, features = [], expiresAt }, secretKey = signingKeyFromEnvironment()) {
  const payload = {
    licenseId, customerId, edition, deviceId, features,
    issuedAt: new Date().toISOString(),
    expiresAt: expiresAt ? new Date(expiresAt).toISOString() : null,
    nonce: randomUUID(),
  };
  const signatureBase64 = Buffer.from(nacl.sign.detached(Buffer.from(canonicalPayload(payload)), secretKey)).toString('base64');
  return { payload, signatureBase64 };
}
