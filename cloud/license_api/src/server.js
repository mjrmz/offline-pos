// cloud/license_api/src/server.js
//
// Stateless entrypoint — safe to run behind a load balancer with multiple
// instances. All state lives in PostgreSQL. See docs/SCALE_ARCHITECTURE.md.

import express from 'express';
import helmet from 'helmet';
import pg from 'pg';
import dotenv from 'dotenv';
import { activationRouter } from './routes/activation.js';

dotenv.config();

const { Pool } = pg;

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  // Reasonable defaults for a low-traffic-per-request, high-concurrency
  // service. Tune based on observed load once you have real traffic.
  max: Number(process.env.DB_POOL_MAX ?? 20),
  idleTimeoutMillis: 30000,
});

const app = express();
app.use(helmet());
app.use(express.json({ limit: '16kb' })); // activation payloads are tiny

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.use(activationRouter(pool));

app.use((err, _req, res, _next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

const port = process.env.PORT ?? 3000;
app.listen(port, () => {
  console.log(`License API listening on port ${port}`);
});

process.on('SIGTERM', async () => {
  await pool.end();
  process.exit(0);
});
