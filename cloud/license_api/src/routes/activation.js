// cloud/license_api/src/routes/activation.js
//
// The only endpoints a customer's device ever calls. Everything else
// (customer/license management) lives behind the admin dashboard's
// authenticated routes, not here.

import express from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { signLicense } from '../services/licenseSigningService.js';

export function activationRouter(pool) {
  const router = express.Router();

  // Generous enough for legitimate retries, tight enough to blunt abuse.
  // Keyed by IP; consider also keying by activationKey for stricter control.
  const activationLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 20,
    standardHeaders: true,
    legacyHeaders: false,
  });

  const activateSchema = z.object({
    activationKey: z.string().min(10),
    deviceFingerprint: z.string().min(8),
  });

  // POST /v1/activate
  // Body: { activationKey, deviceFingerprint }
  // Returns: { payload, signatureBase64 } — the signed license the client
  // stores locally and verifies offline from then on.
  router.post('/v1/activate', activationLimiter, async (req, res) => {
    const parseResult = activateSchema.safeParse(req.body);
    if (!parseResult.success) {
      return res.status(400).json({ error: 'Invalid request body' });
    }
    const { activationKey, deviceFingerprint } = parseResult.data;

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      const licenseResult = await client.query(
        `SELECT l.id, l.customer_id, l.plan_id, l.status, l.max_devices,
                l.expires_at, p.id AS edition
         FROM licenses l
         JOIN plans p ON p.id = l.plan_id
         WHERE l.activation_key = $1
         FOR UPDATE`,
        [activationKey]
      );

      if (licenseResult.rowCount === 0) {
        await logEvent(client, {
          eventType: 'reject',
          reason: 'unknown_activation_key',
          ip: req.ip,
        });
        await client.query('COMMIT');
        return res.status(404).json({ error: 'Invalid activation key' });
      }

      const license = licenseResult.rows[0];

      if (license.status === 'revoked') {
        await logEvent(client, {
          licenseId: license.id,
          eventType: 'reject',
          reason: 'license_revoked',
          ip: req.ip,
        });
        await client.query('COMMIT');
        return res.status(403).json({ error: 'License has been revoked' });
      }

      // Is this device already bound to this license? (idempotent re-activation)
      const existingDevice = await client.query(
        `SELECT id, status FROM devices
         WHERE license_id = $1 AND device_fingerprint = $2`,
        [license.id, deviceFingerprint]
      );

      let deviceId;

      if (existingDevice.rowCount > 0) {
        deviceId = existingDevice.rows[0].id;
        if (existingDevice.rows[0].status === 'deactivated') {
          await client.query(
            `UPDATE devices SET status = 'active', deactivated_at = NULL
             WHERE id = $1`,
            [deviceId]
          );
        }
      } else {
        // Enforce device allowance for this license's plan.
        const activeDeviceCount = await client.query(
          `SELECT COUNT(*) FROM devices
           WHERE license_id = $1 AND status = 'active'`,
          [license.id]
        );

        if (Number(activeDeviceCount.rows[0].count) >= license.max_devices) {
          await logEvent(client, {
            licenseId: license.id,
            eventType: 'reject',
            reason: 'device_limit_reached',
            ip: req.ip,
          });
          await client.query('COMMIT');
          return res.status(403).json({
            error:
              'Device limit reached for this license. Deactivate another device first.',
          });
        }

        const insertDevice = await client.query(
          `INSERT INTO devices (license_id, device_fingerprint)
           VALUES ($1, $2) RETURNING id`,
          [license.id, deviceFingerprint]
        );
        deviceId = insertDevice.rows[0].id;
      }

      await client.query(
        `UPDATE licenses SET status = 'active' WHERE id = $1`,
        [license.id]
      );

      const { payload, signatureBase64 } = signLicense({
        licenseId: license.id,
        customerId: license.customer_id,
        edition: license.edition,
        deviceId: deviceFingerprint,
        features: license.edition === 'bir_ready' ? ['bir_compliance'] : [],
        expiresAt: license.expires_at,
      });

      await logEvent(client, {
        licenseId: license.id,
        deviceId,
        eventType: 'activate',
        ip: req.ip,
      });

      await client.query('COMMIT');
      return res.json({ payload, signatureBase64 });
    } catch (err) {
      await client.query('ROLLBACK');
      console.error('Activation error:', err);
      return res.status(500).json({ error: 'Internal server error' });
    } finally {
      client.release();
    }
  });

  return router;
}

async function logEvent(client, { licenseId, deviceId, eventType, reason, ip }) {
  await client.query(
    `INSERT INTO activation_events (license_id, device_id, event_type, reason, ip_address)
     VALUES ($1, $2, $3, $4, $5)`,
    [licenseId ?? null, deviceId ?? null, eventType, reason ?? null, ip ?? null]
  );
}
