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

## Phase 6 implementation

Windows binds to the OS MachineGuid; Android binds to ANDROID_ID. The client
hashes the platform and identifier with SHA-256 before sending a fingerprint.
OS reinstall, factory reset, or hardware replacement can change it. Binding
is practical, not spoof-proof. Admin release supports legitimate replacement.

The signed license is `signed-license.json` in app support storage, separate
from SQLite and its backups. A same-device database restore leaves licensing
intact. Copying a backup and license to another device fails binding.

The signed bytes are UTF-8 compact JSON with exactly these fields in order:
`licenseId,customerId,edition,deviceId,features,issuedAt,expiresAt,nonce`.
The server-only private Ed25519 key signs them; Flutter embeds the matching
public key through `LICENSE_PUBLIC_KEY_BASE64` at build time.

Startup checks database health first. Unsafe databases open recovery. Healthy
ones verify the local license without HTTP. Missing, malformed, invalid,
mismatched, or expired licenses show activation before Owner setup/login.
Null `expiresAt` means perpetual. Otherwise local time enforces expiration.
No commercial grace-period length has been decided, and none is silently
applied. There is no recurring phone-home call.

Admin deactivation releases a device slot; an already-issued offline license
still works until expiry. Cloud revocation prevents new activation but cannot
disable a permanently offline device. Same-device active retries consume no
additional slot; reactivation allowance is configurable per license.

## Local setup and manual verification

1. Create a disposable PostgreSQL database. In `cloud/license_api`, run
   `npm install`, set `DATABASE_URL` in an untracked `.env` based on
   `.env.example`, then run `npm run migrate`.
2. Run `npm run setup:keys` and keep the generated private key server-side.
   Set `LICENSE_SIGNING_PRIVATE_KEY` from that file, `ADMIN_USERNAME`, a
   scrypt `ADMIN_PASSWORD_HASH` from `npm run setup:admin`, a random
   `ADMIN_AUTH_SECRET` of at least 32 characters, and
   `ADMIN_ORIGIN=http://localhost:5173`. Start with `npm start`.
3. In `cloud/admin_dashboard`, run `npm install`, set
   `VITE_LICENSE_API_URL=http://localhost:3000`, then run `npm run dev`.
   Deploy both over HTTPS. Build/run Flutter with
   `--dart-define=LICENSE_PUBLIC_KEY_BASE64=<generated public key>` and
   `--dart-define=LICENSE_API_URL=<API origin>`.
4. In the dashboard, create a customer and issue a one-device Non-BIR
   license. Copy the activation key shown once. On a fresh Windows test
   install, activate, then complete Owner setup/login.
5. Close POS, stop API and dashboard, disconnect internet, and restart POS.
   Log in, sell an item, open inventory, history, reports, cash sessions,
   and create a local backup. Every action must work offline.
6. Restore API; try the key on device B (rejected), deactivate device A in
   dashboard, then retry B (accepted). A's issued local license continues
   offline under the documented revocation tradeoff.
7. On a disposable install, copy and edit one byte of the local signed
   payload; restart and confirm rejection. Restore the original file. Try
   initial activation while API is stopped: show an unavailable message,
   stay unactivated, and preserve SQLite business data.

Existing development databases without a license retain their data and
enter activation before local login. No production bypass or universal key
is present; tests inject only test keypairs and verifiers.
