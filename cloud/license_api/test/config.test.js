import { test } from 'node:test';
import assert from 'node:assert/strict';
import { databaseConfig } from '../src/db/config.js';

test('local database configuration keeps existing connection behavior', () => {
  assert.deepEqual(databaseConfig({DATABASE_URL:'postgres://localhost/license', NODE_ENV:'development'}),
    {connectionString:'postgres://localhost/license'});
});

test('production database requires a CA and verifies the server', () => {
  const env = {DATABASE_URL:'postgresql://db.example/license?sslmode=require', NODE_ENV:'production'};
  assert.throws(() => databaseConfig(env), /DB_SSL_CA_CERT/);
  const config = databaseConfig({...env, DB_SSL_CA_CERT:'certificate\\nline'});
  assert.equal(new URL(config.connectionString).searchParams.has('sslmode'), false);
  assert.deepEqual(config.ssl, {ca:'certificate\nline', rejectUnauthorized:true});
});

test('missing database URL fails without printing credentials', () => {
  assert.throws(() => databaseConfig({NODE_ENV:'production'}), /DATABASE_URL is required/);
});
