import { makePasswordHash } from './routes/admin.js';
import { readFileSync } from 'node:fs';
const password = readFileSync(0,'utf8').trimEnd();
if (password.length < 12) throw new Error('Admin password must be at least 12 characters');
console.log(makePasswordHash(password));
