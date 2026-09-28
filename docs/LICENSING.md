# Licensing & Activation

## Goal

Sell installable licenses at scale while keeping the app fully offline after
a one-time activation — and make sure a cloud outage never locks a paying
customer out of their own till.

## Cloud-side components

- **License API** — thin REST service, no business data, just licensing.
- **PostgreSQL** — Customers, Licenses, Devices, Activations, Revocations,
  Products/Plans, Audit Logs.
- **Admin Dashboard** — web UI for managing customers, licenses, devices,
  activations, reactivations, and revocations.

## Cryptographic design

- Ed25519 keypair. The **private key** lives only on the License API server
  and never ships with the app. The **public key** is embedded in the app
  and used to verify signatures locally.
- A license payload contains: License ID, Customer ID, Edition, Device ID,
  Features, Issue Date, Expiration, Signature.
- The app verifies the signature locally on every check — no network call
  required after the license has been issued.

## Activation flow

1. App generates a Device ID on first launch (per-platform fingerprint —
   see `licensing/device_id.dart`).
2. Customer enters their Activation Key (issued at time of purchase).
3. App sends `{deviceId, activationKey}` to the License API over HTTPS.
4. License API validates the key, checks activation allowance, binds the
   device, generates and signs a license, and returns it.
5. App stores the signed license locally and verifies it against the
   embedded public key.
6. Internet can now be disconnected permanently — all future checks are
   local.

## Device replacement / transfer

Simply copying the app + database + license file to another device does
**not** transfer the license — the app recalculates the device ID on that
new hardware, finds a mismatch against the license's bound Device ID, and
requires reactivation.

Legitimate transfer flow:

1. Deactivate on the old device (via app or admin dashboard).
2. License becomes transferable.
3. Activate on the new device.

Set a reasonable reactivation allowance per plan so that routine hardware
replacement (e.g. a broken SSD) doesn't become painful for the customer —
suggested tiers:

| Plan | Devices | Notes |
|---|---|---|
| Basic | 1 | |
| Standard | 1 | reasonable reactivation allowance |
| Business | 3 | |

## Cloud outage protection

If the License API is unreachable:

- Already-activated devices are unaffected — they verify against their
  locally stored signed license and continue operating normally.
- Only *new* activations or explicit reactivations require the API to be up.
- Do not design any recurring "phone home" check into daily operation.

## Offline grace period

Design an explicit grace period for edge cases (e.g. a license nearing
expiration and the device genuinely cannot reach the server) rather than
hard-locking the till the moment a check fails to reach the API. Decide the
grace period length as a deliberate business/product decision, not a
default.

## Security notes

- Never ship the private signing key with the client app.
- Rate-limit the activation endpoint.
- Log every activation, deactivation, and revocation to Audit Logs.
- Serve the License API over HTTPS only.
