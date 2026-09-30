import nacl from 'tweetnacl';
import { writeFileSync } from 'node:fs';
const keys = nacl.sign.keyPair();
writeFileSync('license-private.key', Buffer.from(keys.secretKey).toString('base64'), { flag: 'wx', mode: 0o600 });
writeFileSync('license-public.key', Buffer.from(keys.publicKey).toString('base64'), { flag: 'wx' });
console.log('Wrote license-private.key and license-public.key. Keep the private file server-only.');
