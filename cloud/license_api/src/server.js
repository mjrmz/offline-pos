import express from 'express';
import helmet from 'helmet';
import pg from 'pg';
import 'dotenv/config';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { activationRouter } from './routes/activation.js';
import { adminRouter } from './routes/admin.js';
import { signingKeyFromEnvironment } from './services/licenseSigningService.js';
import { databaseConfig } from './db/config.js';

const dashboardDist = fileURLToPath(new URL('../../admin_dashboard/dist/', import.meta.url));

export function createApp(pool) {
  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use((req,res,next) => {
    if (req.headers.origin && req.headers.origin === process.env.ADMIN_ORIGIN) {
      res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
      res.setHeader('Access-Control-Allow-Credentials','true');
      res.setHeader('Access-Control-Allow-Headers','Content-Type');
      res.setHeader('Access-Control-Allow-Methods','GET,POST,OPTIONS');
      res.setHeader('Vary','Origin');
    }
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  });
  app.use(express.json({limit:'16kb'}));
  app.get('/healthz', (_req,res) => res.json({status:'ok'}));
  app.use(activationRouter(pool));
  app.use(adminRouter(pool));
  const dashboardIndex = join(dashboardDist, 'index.html');
  if (existsSync(dashboardIndex)) {
    app.use('/assets', express.static(join(dashboardDist, 'assets'), {
      immutable: true, maxAge: '1y',
    }));
    app.get(['/', '/index.html'], (_req, res) => res.sendFile(dashboardIndex));
  }
  app.use((_req,res) => res.status(404).json({error:'Route not found'}));
  app.use((_err,_req,res,_next) => res.status(500).json({error:'Internal server error'}));
  return app;
}

if (process.argv[1]?.endsWith('server.js')) {
  signingKeyFromEnvironment();
  const pool = new pg.Pool({...databaseConfig(),max:Number(process.env.DB_POOL_MAX ?? 5)});
  const server = createApp(pool).listen(Number(process.env.PORT ?? 3000), '0.0.0.0', () => console.log('License API ready'));
  process.on('SIGTERM', async () => { server.close(); await pool.end(); });
}
