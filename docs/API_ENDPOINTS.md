# API Endpoints — License API

The client app calls exactly one of these routes in normal operation
(`/v1/activate`). Everything else is either operational (`/healthz`) or
belongs to the authenticated admin dashboard, not the customer's device.

## Public / device-facing

### `POST /v1/activate`

Called once during initial setup, and again if a device needs to
reactivate (e.g. after being deactivated for a transfer).

**Request**
```json
{
  "activationKey": "AAAA-BBBB-CCCC-DDDD",
  "deviceFingerprint": "8A92F72C91XX..."
}
```

**Response — 200**
```json
{
  "payload": {
    "licenseId": "uuid",
    "customerId": "uuid",
    "edition": "non_bir",
    "deviceId": "8A92F72C91XX...",
    "features": [],
    "issuedAt": "2026-08-25T00:00:00.000Z",
    "expiresAt": null,
    "nonce": "uuid"
  },
  "signatureBase64": "..."
}
```

**Error responses**
- `400` — malformed request body
- `404` — activation key not found
- `403` — license revoked, or device limit reached for this license's plan
- `429` — rate limited (too many attempts from this IP)
- `500` — server error (client should retry with backoff; the customer's
  device is unaffected either way since it isn't activated yet)

Rate limited at 20 requests / 15 minutes per IP by default — see
`cloud/license_api/src/routes/activation.js`.

### `GET /healthz`

Load balancer / uptime monitoring only. Returns `{ "status": "ok" }`.

## Admin-only (not called by the client app)

These live behind authenticated admin dashboard routes — deliberately not
detailed here since they require an auth/session layer not yet built. At
minimum, expect:

- `GET /admin/customers` — list/search customers
- `POST /admin/licenses` — issue a new license (generates the activation key)
- `POST /admin/licenses/:id/revoke`
- `POST /admin/devices/:id/deactivate` — supports the device transfer flow
- `GET /admin/activation-events` — audit trail, filterable by license/device

## What's intentionally NOT an endpoint

- No endpoint for syncing sales, inventory, or any business data — that
  data never leaves the device by design (see docs/ARCHITECTURE.md).
- No recurring "phone home" / heartbeat endpoint required for the client
  to keep functioning — the whole point of local signature verification
  is that the client never needs to ask the server "am I still licensed?"
  after activation.
