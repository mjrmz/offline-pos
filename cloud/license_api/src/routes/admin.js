import express from 'express';
import { createHash, createHmac, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';

const ttl = 8 * 60 * 60 * 1000;
function authConfig() {
  const { ADMIN_USERNAME, ADMIN_PASSWORD_HASH, ADMIN_AUTH_SECRET } = process.env;
  if (!ADMIN_USERNAME || !ADMIN_PASSWORD_HASH || !ADMIN_AUTH_SECRET || ADMIN_AUTH_SECRET.length < 32) {
    throw new Error('Admin auth environment is incomplete');
  }
  return { user: ADMIN_USERNAME, hash: ADMIN_PASSWORD_HASH, secret: ADMIN_AUTH_SECRET };
}
function token(user, secret) {
  const body = Buffer.from(JSON.stringify({ user, expires: Date.now() + ttl })).toString('base64url');
  return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
}
function checkToken(value, secret) {
  try {
    const [body, mac] = value.split('.');
    const expected = createHmac('sha256', secret).update(body).digest();
    if (!timingSafeEqual(Buffer.from(mac, 'base64url'), expected)) return null;
    const parsed = JSON.parse(Buffer.from(body, 'base64url').toString());
    return parsed.expires > Date.now() ? parsed.user : null;
  } catch (_) { return null; }
}
function checkPassword(password, stored) {
  try {
    const [salt, hash] = stored.split(':');
    return timingSafeEqual(scryptSync(password, Buffer.from(salt, 'base64'), 64), Buffer.from(hash, 'base64'));
  } catch (_) { return false; }
}
export function makePasswordHash(password) {
  const salt = randomBytes(16);
  return `${salt.toString('base64')}:${scryptSync(password, salt, 64).toString('base64')}`;
}

export function adminRouter(pool) {
  const router = express.Router();
  const config = authConfig();
  router.post('/admin/login', rateLimit({windowMs:15*60*1000,limit:10,standardHeaders:'draft-7',legacyHeaders:false}), (req, res) => {
    if (req.body?.username !== config.user || typeof req.body?.password !== 'string' ||
        !checkPassword(req.body.password, config.hash)) return res.status(401).json({ error: 'Invalid credentials' });
    res.cookie('admin_session', token(config.user, config.secret), { httpOnly: true, secure: process.env.NODE_ENV === 'production', sameSite: 'strict', path: '/admin', maxAge: ttl });
    return res.json({ user: config.user });
  });
  router.use('/admin', (req, res, next) => {
    const cookie = req.headers.cookie?.split(';').map(x => x.trim()).find(x => x.startsWith('admin_session='))?.slice(14);
    const user = cookie && checkToken(cookie, config.secret);
    if (!user) return res.status(401).json({ error: 'Admin login required' });
    if (!['GET', 'HEAD'].includes(req.method)) {
      const origin = req.headers.origin;
      const expected = process.env.ADMIN_ORIGIN;
      if (!origin || !expected || origin !== expected) return res.status(403).json({ error: 'Invalid origin' });
    }
    req.adminUser = user;
    next();
  });
  router.post('/admin/logout', (_req, res) => { res.clearCookie('admin_session', { path: '/admin' }); res.json({ ok: true }); });
  router.get('/admin/me', (req, res) => res.json({ user: req.adminUser }));
  router.get('/admin/plans', async (_req, res, next) => { try { res.json((await pool.query('SELECT * FROM plans ORDER BY id')).rows); } catch (e) { next(e); } });
  router.get('/admin/customers', async (req, res, next) => {
    try { res.json((await pool.query('SELECT * FROM customers WHERE business_name ILIKE $1 ORDER BY created_at DESC LIMIT 100', [`%${req.query.q ?? ''}%`])).rows); } catch (e) { next(e); }
  });
  router.post('/admin/customers', async (req, res, next) => {
    const p = z.object({ businessName: z.string().trim().min(1).max(200), contactEmail: z.string().email().nullable().optional(), contactPhone: z.string().max(100).nullable().optional() }).strict().safeParse(req.body);
    if (!p.success) return res.status(400).json({ error: 'Invalid customer' });
    try { res.status(201).json((await pool.query('INSERT INTO customers(business_name,contact_email,contact_phone) VALUES($1,$2,$3) RETURNING *', [p.data.businessName, p.data.contactEmail ?? null, p.data.contactPhone ?? null])).rows[0]); } catch (e) { next(e); }
  });
  router.get('/admin/licenses', async (_req, res, next) => {
    try { res.json((await pool.query(`SELECT l.id,l.customer_id,l.plan_id,l.status,l.max_devices,l.max_reactivations,l.reactivations_used,l.issued_at,l.expires_at,
      c.business_name,(SELECT count(*)::int FROM devices d WHERE d.license_id=l.id AND d.status='active') AS active_devices
      FROM licenses l JOIN customers c ON c.id=l.customer_id ORDER BY l.issued_at DESC LIMIT 100`)).rows); } catch(e) { next(e); }
  });
  router.post('/admin/licenses', async (req, res, next) => {
    const p = z.object({ customerId: z.string().uuid(), planId: z.string().min(1), maxDevices: z.number().int().min(1).max(100), maxReactivations: z.number().int().min(0).max(100).default(3), expiresAt: z.string().datetime().nullable().optional() }).strict().safeParse(req.body);
    if (!p.success) return res.status(400).json({ error: 'Invalid license' });
    const raw = randomBytes(10).toString('hex').toUpperCase();
    const activationKey = `${raw.slice(0,5)}-${raw.slice(5,10)}-${raw.slice(10,15)}-${raw.slice(15,20)}`;
    // Five-character groups provide 80 bits of randomness.
    const hash = createHash('sha256').update(activationKey).digest('hex');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const inserted = await client.query(`INSERT INTO licenses(customer_id,plan_id,activation_key_hash,max_devices,max_reactivations,expires_at)
        VALUES($1,$2,$3,$4,$5,$6) RETURNING id,status`, [p.data.customerId,p.data.planId,hash,p.data.maxDevices,p.data.maxReactivations,p.data.expiresAt ?? null]);
      await client.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)', [req.adminUser,'license.issue',inserted.rows[0].id]);
      await client.query('COMMIT');
      res.status(201).json({ ...inserted.rows[0], activationKey });
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  });
  router.get('/admin/licenses/:id/devices', async (req,res,next) => {
    try { res.json((await pool.query('SELECT id,license_id,device_fingerprint,status,activated_at,deactivated_at FROM devices WHERE license_id=$1 ORDER BY activated_at DESC',[req.params.id])).rows); } catch(e) { next(e); }
  });
  async function change(req,res,next,kind) {
    const client=await pool.connect();
    try {
      await client.query('BEGIN');
      const q=kind==='revoke' ? `UPDATE licenses SET status='revoked',revoked_at=now() WHERE id=$1 AND status<>'revoked' RETURNING id` :
        `UPDATE devices SET status='deactivated',deactivated_at=now() WHERE id=$1 AND status='active' RETURNING id,license_id`;
      const result=await client.query(q,[req.params.id]);
      if (!result.rowCount) { await client.query('ROLLBACK'); return res.status(404).json({error:'Not found or already changed'}); }
      const id=kind==='revoke' ? result.rows[0].id : result.rows[0].license_id;
      await client.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)',[req.adminUser,kind,id]);
      await client.query(`INSERT INTO activation_events(license_id,device_id,event_type) VALUES($1,$2,$3)`,[id,kind==='revoke'?null:req.params.id,kind]);
      await client.query('COMMIT'); res.json({ok:true});
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  }
  router.post('/admin/licenses/:id/revoke',(req,res,next)=>change(req,res,next,'revoke'));
  router.post('/admin/devices/:id/deactivate',(req,res,next)=>change(req,res,next,'deactivate'));
  router.get('/admin/activation-events',async(req,res,next)=>{
    try { res.json((await pool.query('SELECT * FROM activation_events ORDER BY created_at DESC LIMIT 200')).rows); } catch(e) { next(e); }
  });
  return router;
}
