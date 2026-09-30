import express from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { signLicense } from '../services/licenseSigningService.js';

const requestSchema = z.object({
  activationKey: z.string().regex(/^[A-F0-9]{5}(?:-[A-F0-9]{5}){3}$/),
  deviceFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
}).strict();

export function activationRouter(pool) {
  const router = express.Router();
  router.post('/v1/activate', rateLimit({ windowMs: 15 * 60 * 1000, limit: 20,
    standardHeaders: 'draft-7', legacyHeaders: false }), async (req, res) => {
    const parsed = requestSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Invalid request', code: 'malformed' });
    const keyHash = (await import('node:crypto')).createHash('sha256').update(parsed.data.activationKey).digest('hex');
    let client;
    try {
      client = await pool.connect();
      await client.query('BEGIN');
      const result = await client.query(`SELECT l.*, p.edition FROM licenses l JOIN plans p ON p.id=l.plan_id
        WHERE l.activation_key_hash=$1 FOR UPDATE OF l`, [keyHash]);
      if (!result.rowCount) {
        await client.query(`INSERT INTO activation_events(event_type,reason) VALUES('reject','unknown_key')`);
        await client.query('COMMIT');
        return res.status(404).json({ error: 'Activation key not found', code: 'not_found' });
      }
      const license = result.rows[0];
      let rejection;
      if (license.status === 'revoked') rejection = ['revoked', 'License revoked'];
      else if (license.expires_at && new Date(license.expires_at) <= new Date()) rejection = ['expired', 'License expired'];
      const fingerprint = parsed.data.deviceFingerprint;
      const existing = await client.query('SELECT * FROM devices WHERE license_id=$1 AND device_fingerprint=$2', [license.id, fingerprint]);
      const activeCount = await client.query(`SELECT count(*)::int AS count FROM devices WHERE license_id=$1 AND status='active'`, [license.id]);
      const alreadyActive = existing.rowCount && existing.rows[0].status === 'active';
      if (!rejection && !alreadyActive && activeCount.rows[0].count >= license.max_devices) rejection = ['device_limit', 'Device limit reached'];
      if (!rejection && existing.rowCount && !alreadyActive && license.reactivations_used >= license.max_reactivations) rejection = ['reactivation_limit', 'Reactivation allowance reached'];
      if (rejection) {
        await client.query(`INSERT INTO activation_events(license_id,device_id,event_type,reason)
          VALUES($1,$2,'reject',$3)`, [license.id, existing.rows[0]?.id ?? null, rejection[0]]);
        await client.query('COMMIT');
        return res.status(403).json({ error: rejection[1], code: rejection[0] });
      }
      let deviceId;
      let eventType;
      if (alreadyActive) { deviceId = existing.rows[0].id; eventType = 'retry'; }
      else if (existing.rowCount) {
        deviceId = existing.rows[0].id; eventType = 'reactivate';
        await client.query(`UPDATE devices SET status='active', activated_at=now(), deactivated_at=NULL WHERE id=$1`, [deviceId]);
        await client.query(`UPDATE licenses SET reactivations_used=reactivations_used+1 WHERE id=$1`, [license.id]);
      } else {
        const inserted = await client.query('INSERT INTO devices(license_id,device_fingerprint) VALUES($1,$2) RETURNING id', [license.id, fingerprint]);
        deviceId = inserted.rows[0].id; eventType = 'activate';
      }
      const signed = signLicense({ licenseId: license.id, customerId: license.customer_id,
        edition: license.edition, deviceId: fingerprint, expiresAt: license.expires_at });
      await client.query(`UPDATE licenses SET status='active' WHERE id=$1`, [license.id]);
      await client.query(`INSERT INTO activation_events(license_id,device_id,event_type) VALUES($1,$2,$3)`, [license.id, deviceId, eventType]);
      await client.query('COMMIT');
      return res.json(signed);
    } catch (_) {
      if (client) await client.query('ROLLBACK').catch(() => {});
      return res.status(500).json({ error: 'Activation service unavailable', code: 'server_error' });
    } finally { client?.release(); }
  });
  return router;
}
