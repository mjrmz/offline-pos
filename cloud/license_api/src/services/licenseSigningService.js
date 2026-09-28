// cloud/license_api/src/services/licenseSigningService.js
//
// Issues Ed25519-signed license payloads. The private key lives ONLY here,
// on the server — it never ships to the client app. See docs/LICENSING.md.

import nacl from 'tweetnacl';
import { randomUUID } from 'crypto';

// In production, load this from a secrets manager (AWS Secrets Manager,
// GCP Secret Manager, etc.) — never commit it, never log it.
const PRIVATE_KEY_BASE64 = process.env.LICENSE_SIGNING_PRIVATE_KEY;

if (!PRIVATE_KEY_BASE64) {
  throw new Error(
    'LICENSE_SIGNING_PRIVATE_KEY is not set. Generate a keypair with ' +
    'tweetnacl.sign.keyPair() once, store the private key securely, and ' +
    'embed the public key in the client app (see signature_verifier.dart).'
  );
}

const privateKey = Uint8Array.from(
  Buffer.from(PRIVATE_KEY_BASE64, 'base64')
);

/**
 * Builds and signs a license payload for a given license + device.
 * @param {object} params
 * @param {string} params.licenseId
 * @param {string} params.customerId
 * @param {string} params.edition - 'non_bir' | 'bir_ready'
 * @param {string} params.deviceId - device fingerprint sent by the client
 * @param {string[]} params.features
 * @param {Date|null} params.expiresAt
 * @returns {{ payload: object, signatureBase64: string }}
 */
export function signLicense({
  licenseId,
  customerId,
  edition,
  deviceId,
  features,
  expiresAt,
}) {
  const payload = {
    licenseId,
    customerId,
    edition,
    deviceId,
    features,
    issuedAt: new Date().toISOString(),
    expiresAt: expiresAt ? expiresAt.toISOString() : null,
    nonce: randomUUID(), // prevents replay of an identical-looking payload
  };

  const payloadBytes = Buffer.from(JSON.stringify(payload), 'utf-8');
  const signature = nacl.sign.detached(payloadBytes, privateKey);

  return {
    payload,
    signatureBase64: Buffer.from(signature).toString('base64'),
  };
}

/**
 * Generates a new Ed25519 keypair. Run this ONCE during initial setup,
 * store the private key in your secrets manager, and embed the public
 * key in the Flutter app's SignatureVerifier.
 */
export function generateSigningKeypair() {
  const keyPair = nacl.sign.keyPair();
  return {
    publicKeyBase64: Buffer.from(keyPair.publicKey).toString('base64'),
    privateKeyBase64: Buffer.from(keyPair.secretKey).toString('base64'),
  };
}
