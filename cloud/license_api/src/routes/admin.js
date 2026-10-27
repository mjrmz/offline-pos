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
function token(identity, secret, lifetime = ttl) {
  const body = Buffer.from(JSON.stringify({ ...identity, expires: Date.now() + lifetime })).toString('base64url');
  return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
}
function checkToken(value, secret) {
  try {
    const [body, mac] = value.split('.');
    const expected = createHmac('sha256', secret).update(body).digest();
    if (!timingSafeEqual(Buffer.from(mac, 'base64url'), expected)) return null;
    const parsed = JSON.parse(Buffer.from(body, 'base64url').toString());
    return parsed.expires > Date.now() ? parsed : null;
  } catch (_) { return null; }
}
function checkPassword(password, stored) {
  try {
    const [salt, hash] = stored.split(':');
    return timingSafeEqual(scryptSync(password, Buffer.from(salt, 'base64'), 64), Buffer.from(hash, 'base64'));
  } catch (_) { return false; }
}
function newActivationKey() {
  const raw = randomBytes(10).toString('hex').toUpperCase();
  return `${raw.slice(0,5)}-${raw.slice(5,10)}-${raw.slice(10,15)}-${raw.slice(15,20)}`;
}
function activationKeyHash(value) {
  return createHash('sha256').update(value).digest('hex');
}
export function makePasswordHash(password) {
  const salt = randomBytes(16);
  return `${salt.toString('base64')}:${scryptSync(password, salt, 64).toString('base64')}`;
}

export function adminRouter(pool) {
  const router = express.Router();
  const config = authConfig();
  const cookieOptions = { httpOnly: true, secure: process.env.NODE_ENV === 'production', sameSite: 'strict', path: '/admin', maxAge: ttl };
  const accountFields = 'id,username,display_name,role,enabled,created_at,updated_at,last_login_at,password_changed_at';
  const accountView = row => ({ id: row.id, username: row.username, displayName: row.display_name, role: row.role, lastLoginAt: row.last_login_at, passwordChangedAt: row.password_changed_at });
  const recordEvent = (db, actor, action, targetId = null) => db.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)', [actor, action, targetId]);
  const passwordRule = z.string().min(12).max(128);
  const usernameRule = z.string().trim().min(3).max(64).regex(/^[A-Za-z0-9._-]+$/);
  const originValid = req => req.headers.origin && process.env.ADMIN_ORIGIN && req.headers.origin === process.env.ADMIN_ORIGIN;
  const setSession = (res, identity) => {
    const lifetime = identity.recovery ? 10 * 60 * 1000 : ttl;
    res.cookie('admin_session', token(identity, config.secret, lifetime), { ...cookieOptions, maxAge: lifetime });
  };
  router.post('/admin/login', rateLimit({windowMs:15*60*1000,limit:10,standardHeaders:'draft-7',legacyHeaders:false}), async (req, res, next) => {
    const { username, password } = req.body ?? {};
    if (typeof username !== 'string' || typeof password !== 'string') return res.status(401).json({ error: 'Invalid credentials' });
    try {
      const result = await pool.query('SELECT * FROM admin_accounts WHERE lower(username)=lower($1) AND enabled=true', [username]);
      const account = result.rows.find(row => row.password_hash && row.id);
      if (account && checkPassword(password, account.password_hash)) {
        const session = await pool.query('INSERT INTO admin_sessions(account_id,expires_at) VALUES($1,now()+interval \'8 hours\') RETURNING id', [account.id]);
        await pool.query('UPDATE admin_accounts SET last_login_at=now() WHERE id=$1', [account.id]);
        await recordEvent(pool, account.username, 'admin.login', account.id);
        setSession(res, { id: account.id, sid: session.rows[0].id });
        return res.set('Cache-Control', 'no-store').json({ user: account.username, account: accountView(account) });
      }
      if (username === config.user && checkPassword(password, config.hash)) {
        const existing = await pool.query("SELECT id FROM admin_accounts WHERE role='owner' LIMIT 1");
        const recovery = Boolean(existing.rowCount);
        await recordEvent(pool, config.user, recovery ? 'admin.recovery_login' : 'admin.bootstrap_login');
        setSession(res, { recovery: true, bootstrap: !recovery, nonce: randomBytes(16).toString('hex') });
        return res.set('Cache-Control', 'no-store').json({ user: config.user, recovery: true, bootstrap: !recovery });
      }
      return res.status(401).json({ error: 'Invalid credentials' });
    } catch (e) { next(e); }
  });
  router.use('/admin', async (req, res, next) => {
    const cookie = req.headers.cookie?.split(';').map(x => x.trim()).find(x => x.startsWith('admin_session='))?.slice(14);
    const identity = cookie && checkToken(cookie, config.secret);
    if (!identity) return res.status(401).json({ error: 'Admin login required' });
    if (!['GET', 'HEAD'].includes(req.method)) {
      if (!originValid(req)) return res.status(403).json({ error: 'Invalid origin' });
    }
    try {
      if (identity.recovery) {
        const existing = await pool.query("SELECT id FROM admin_accounts WHERE role='owner' LIMIT 1");
        req.recovery = true;
        req.bootstrap = identity.bootstrap && !existing.rowCount;
        req.adminUser = config.user;
        if (identity.bootstrap && existing.rowCount) return res.status(401).json({ error: 'Bootstrap session expired. Sign in again' });
        if (!req.bootstrap && !['/admin/me','/admin/logout','/admin/account/recover'].includes(req.originalUrl.split('?')[0])) return res.status(403).json({ error: 'Recovery access is limited to account recovery' });
      } else if (identity.id && identity.sid) {
        const result = await pool.query(`SELECT a.*,s.id AS session_id FROM admin_accounts a JOIN admin_sessions s ON s.account_id=a.id WHERE a.id=$1 AND s.id=$2 AND a.enabled=true AND s.revoked_at IS NULL AND s.expires_at>now()`, [identity.id, identity.sid]);
        if (!result.rows[0]?.password_hash) return res.status(401).json({ error: 'Admin login required' });
        req.account = result.rows[0]; req.sessionId = identity.sid; req.adminUser = req.account.username;
      } else return res.status(401).json({ error: 'Admin login required' });
      next();
    } catch (e) { next(e); }
  });
  router.post('/admin/logout', async (req, res, next) => { try { if (req.sessionId) await pool.query('UPDATE admin_sessions SET revoked_at=now() WHERE id=$1', [req.sessionId]); res.clearCookie('admin_session', { path: '/admin' }); res.json({ ok: true }); } catch(e) { next(e); } });
  router.get('/admin/me', (req, res) => res.set('Cache-Control','no-store').json({ user: req.adminUser, recovery: Boolean(req.recovery), bootstrap: Boolean(req.bootstrap), account: req.account ? accountView(req.account) : null }));
  router.post('/admin/account/bootstrap', async (req, res, next) => {
    if (!req.recovery || !req.bootstrap) return res.status(403).json({ error: 'Bootstrap access required' });
    const parsed = z.object({ username: usernameRule, displayName: z.string().trim().min(1).max(100), password: passwordRule }).strict().safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Enter a valid username, display name and password of at least 12 characters' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const created = await client.query(`INSERT INTO admin_accounts(username,display_name,password_hash,role) VALUES($1,$2,$3,'owner') RETURNING ${accountFields}`, [parsed.data.username, parsed.data.displayName, makePasswordHash(parsed.data.password)]);
      await recordEvent(client, config.user, 'admin.account_bootstrap', created.rows[0].id);
      await client.query('COMMIT');
      res.clearCookie('admin_session', { path: '/admin' });
      res.status(201).json({ account: accountView(created.rows[0]), signInRequired: true });
    } catch(e) { await client.query('ROLLBACK'); if(e.code==='23505') return res.status(409).json({error:'Owner account or username already exists'}); next(e); } finally { client.release(); }
  });
  router.post('/admin/account/recover', rateLimit({windowMs:15*60*1000,limit:5,standardHeaders:'draft-7',legacyHeaders:false}), async (req, res, next) => {
    if (!req.recovery || req.bootstrap) return res.status(403).json({ error: 'Recovery access required' });
    const parsed = z.object({ newPassword: passwordRule }).strict().safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Password must have at least 12 characters' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const owner = await client.query(`UPDATE admin_accounts SET password_hash=$1,password_changed_at=now(),updated_at=now(),enabled=true WHERE role='owner' RETURNING ${accountFields}`, [makePasswordHash(parsed.data.newPassword)]);
      if (!owner.rowCount) { await client.query('ROLLBACK'); return res.status(404).json({ error: 'Owner account not found' }); }
      await client.query('UPDATE admin_sessions SET revoked_at=now() WHERE account_id=$1 AND revoked_at IS NULL', [owner.rows[0].id]);
      await recordEvent(client, config.user, 'admin.password_recovered', owner.rows[0].id);
      await client.query('COMMIT');
      res.clearCookie('admin_session', { path: '/admin' }); res.json({ ok: true, signInRequired: true });
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  });
  router.patch('/admin/account', async (req, res, next) => {
    if (!req.account) return res.status(403).json({ error: 'Account access required' });
    const parsed = z.object({ username: usernameRule, displayName: z.string().trim().min(1).max(100) }).strict().safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Enter a valid username and display name' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const updated = await client.query(`UPDATE admin_accounts SET username=$1,display_name=$2,updated_at=now() WHERE id=$3 RETURNING ${accountFields}`, [parsed.data.username, parsed.data.displayName, req.account.id]);
      if (parsed.data.username !== req.account.username) await recordEvent(client, req.account.username, 'admin.username_changed', req.account.id);
      await client.query('COMMIT'); res.json({ account: accountView(updated.rows[0]) });
    } catch(e) { await client.query('ROLLBACK'); if(e.code==='23505') return res.status(409).json({error:'Username is already in use'}); next(e); } finally { client.release(); }
  });
  router.post('/admin/account/password', rateLimit({windowMs:15*60*1000,limit:10,standardHeaders:'draft-7',legacyHeaders:false}), async (req, res, next) => {
    if (!req.account) return res.status(403).json({ error: 'Account access required' });
    const parsed = z.object({ currentPassword: z.string(), newPassword: passwordRule }).strict().safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Password must have at least 12 characters' });
    if (!checkPassword(parsed.data.currentPassword, req.account.password_hash)) return res.status(403).json({ error: 'Current password is incorrect' });
    if (checkPassword(parsed.data.newPassword, req.account.password_hash)) return res.status(400).json({ error: 'Choose a different password' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const changed = await client.query('UPDATE admin_accounts SET password_hash=$1,password_changed_at=now(),updated_at=now() WHERE id=$2 AND password_hash=$3 RETURNING id', [makePasswordHash(parsed.data.newPassword),req.account.id,req.account.password_hash]);
      if (!changed.rowCount) { await client.query('ROLLBACK'); return res.status(409).json({ error: 'Account changed. Please sign in again' }); }
      await client.query('UPDATE admin_sessions SET revoked_at=now() WHERE account_id=$1 AND id<>$2 AND revoked_at IS NULL', [req.account.id, req.sessionId]);
      await recordEvent(client, req.account.username, 'admin.password_changed', req.account.id);
      await client.query('COMMIT'); res.json({ ok: true, otherSessionsSignedOut: true });
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  });
  router.post('/admin/account/sessions/revoke-others', async (req, res, next) => {
    if (!req.account) return res.status(403).json({ error: 'Account access required' });
    try { await pool.query('UPDATE admin_sessions SET revoked_at=now() WHERE account_id=$1 AND id<>$2 AND revoked_at IS NULL', [req.account.id,req.sessionId]); res.json({ ok: true }); } catch(e) { next(e); }
  });
  router.get('/admin/plans', async (_req, res, next) => { try { res.json((await pool.query('SELECT * FROM plans ORDER BY id')).rows); } catch (e) { next(e); } });
  router.get('/admin/customers', async (req, res, next) => {
    try { res.json((await pool.query('SELECT * FROM customers WHERE business_name ILIKE $1 ORDER BY created_at DESC LIMIT 100', [`%${req.query.q ?? ''}%`])).rows); } catch (e) { next(e); }
  });
  router.post('/admin/customers', async (req, res, next) => {
    const p = z.object({ businessName: z.string().trim().min(1).max(200), contactEmail: z.string().email().nullable().optional(), contactPhone: z.string().max(100).nullable().optional(), notes: z.string().max(2000).nullable().optional() }).strict().safeParse(req.body);
    if (!p.success) return res.status(400).json({ error: 'Invalid customer' });
    try { res.status(201).json((await pool.query('INSERT INTO customers(business_name,contact_email,contact_phone,notes) VALUES($1,$2,$3,$4) RETURNING *', [p.data.businessName, p.data.contactEmail ?? null, p.data.contactPhone ?? null, p.data.notes ?? null])).rows[0]); } catch (e) { next(e); }
  });
  router.get('/admin/licenses', async (_req, res, next) => {
    try { res.json((await pool.query(`SELECT l.id,l.customer_id,l.plan_id,l.status,l.max_devices,l.max_reactivations,l.reactivations_used,l.issued_at,l.expires_at,
      c.business_name,(SELECT count(*)::int FROM devices d WHERE d.license_id=l.id AND d.status='active') AS active_devices
      FROM licenses l JOIN customers c ON c.id=l.customer_id ORDER BY l.issued_at DESC LIMIT 100`)).rows); } catch(e) { next(e); }
  });
  router.post('/admin/licenses', async (req, res, next) => {
    const p = z.object({ customerId: z.string().uuid(), planId: z.string().min(1), maxDevices: z.number().int().min(1).max(100), maxReactivations: z.number().int().min(0).max(100).default(3), expiresAt: z.string().datetime().nullable().optional() }).strict().safeParse(req.body);
    if (!p.success) return res.status(400).json({ error: 'Invalid license' });
    const activationKey = newActivationKey();
    // Five-character groups provide 80 bits of randomness.
    const hash = activationKeyHash(activationKey);
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const inserted = await client.query(`INSERT INTO licenses(customer_id,plan_id,activation_key_hash,max_devices,max_reactivations,expires_at)
        VALUES($1,$2,$3,$4,$5,$6) RETURNING id,status`, [p.data.customerId,p.data.planId,hash,p.data.maxDevices,p.data.maxReactivations,p.data.expiresAt ?? null]);
      await client.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)', [req.adminUser,'license.issue',inserted.rows[0].id]);
      await client.query('COMMIT');
      res.set('Cache-Control', 'no-store').status(201).json({ ...inserted.rows[0], activationKey });
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  });
  router.post('/admin/licenses/:id/activation-key/rotate', async (req, res, next) => {
    if (!z.string().uuid().safeParse(req.params.id).success) {
      return res.status(400).json({ error: 'Invalid License ID' });
    }
    const activationKey = newActivationKey();
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const updated = await client.query(`UPDATE licenses SET activation_key_hash=$2
        WHERE id=$1 AND status<>'revoked' RETURNING id`,
        [req.params.id, activationKeyHash(activationKey)]);
      if (!updated.rowCount) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Active license not found' });
      }
      await client.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)',
        [req.adminUser, 'license.activation_key_rotate', req.params.id]);
      await client.query('COMMIT');
      return res.set('Cache-Control', 'no-store').json({ id: req.params.id, activationKey });
    } catch (e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
  });
  router.get('/admin/licenses/:id/devices', async (req,res,next) => {
    try { res.json((await pool.query('SELECT id,license_id,device_fingerprint,status,activated_at,deactivated_at FROM devices WHERE license_id=$1 ORDER BY activated_at DESC',[req.params.id])).rows); } catch(e) { next(e); }
  });
  router.get('/admin/devices', async (_req, res, next) => {
    try {
      res.json((await pool.query(`SELECT d.id,d.license_id,d.device_fingerprint,d.status,d.activated_at,d.deactivated_at,
        l.customer_id,c.business_name
        FROM devices d JOIN licenses l ON l.id=d.license_id
        JOIN customers c ON c.id=l.customer_id
        ORDER BY d.activated_at DESC LIMIT 500`)).rows);
    } catch (e) { next(e); }
  });
  router.post('/admin/licenses/:id/edition', async (req,res,next) => {
    const parsed = z.object({ edition: z.enum(['non_bir','bir_ready']) }).strict().safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Invalid edition' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const result = await client.query(`UPDATE licenses SET plan_id=$2 WHERE id=$1 AND status<>'revoked' RETURNING id,plan_id`, [req.params.id, parsed.data.edition]);
      if (!result.rowCount) { await client.query('ROLLBACK'); return res.status(404).json({error:'Active license not found'}); }
      await client.query('INSERT INTO admin_events(actor,action,target_id) VALUES($1,$2,$3)', [req.adminUser,'license.edition_change',req.params.id]);
      await client.query('COMMIT');
      res.json(result.rows[0]);
    } catch(e) { await client.query('ROLLBACK'); next(e); } finally { client.release(); }
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
  router.get('/admin/activity', async (_req, res, next) => {
    try {
      res.json((await pool.query(`SELECT id, license_id, device_id, event_type, reason, created_at
        FROM activation_events
        UNION ALL
        SELECT id, target_id AS license_id, NULL::uuid AS device_id, action AS event_type,
          NULL::text AS reason, created_at
        FROM admin_events
        WHERE action IN ('license.issue', 'license.activation_key_rotate', 'license.edition_change')
        ORDER BY created_at DESC LIMIT 200`)).rows);
    } catch (e) { next(e); }
  });
  return router;
}
