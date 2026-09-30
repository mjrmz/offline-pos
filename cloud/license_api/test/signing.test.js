import { test } from 'node:test';
import assert from 'node:assert/strict';
import nacl from 'tweetnacl';
import { canonicalPayload, signLicense } from '../src/services/licenseSigningService.js';

test('canonical signed license validates and tampering fails', () => {
  const pair = nacl.sign.keyPair();
  const signed = signLicense({licenseId:'license',customerId:'customer',edition:'non_bir',deviceId:'device'},pair.secretKey);
  const bytes = Buffer.from(canonicalPayload(signed.payload));
  const signature = Buffer.from(signed.signatureBase64,'base64');
  assert.equal(nacl.sign.detached.verify(bytes,signature,pair.publicKey),true);
  assert.equal(nacl.sign.detached.verify(Buffer.from(canonicalPayload({...signed.payload,deviceId:'other'})),signature,pair.publicKey),false);
  assert.throws(()=>canonicalPayload({...signed.payload,extra:'field'}));
});
