import express from 'express';
import helmet from 'helmet';
import pg from 'pg';
import 'dotenv/config';
import { activationRouter } from './routes/activation.js';
import { adminRouter } from './routes/admin.js';
import { signingKeyFromEnvironment } from './services/licenseSigningService.js';

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
  app.use((_err,_req,res,_next) => res.status(500).json({error:'Internal server error'}));
  return app;
}

if (process.argv[1]?.endsWith('server.js')) {
  signingKeyFromEnvironment();
  const pool = new pg.Pool({connectionString:process.env.DATABASE_URL,max:Number(process.env.DB_POOL_MAX ?? 20)});
  const server = createApp(pool).listen(Number(process.env.PORT ?? 3000), () => console.log('License API ready'));
  process.on('SIGTERM', async () => { server.close(); await pool.end(); });
}
