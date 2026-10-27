# Internal RC License API: Supabase + Render

This deploys only `cloud/license_api` and its licensing/admin tables. The POS keeps its local SQLite business database and offline signed-license validation. Keep the existing Ed25519 keypair; never run `setup:keys` for this deployment.

Current internal RC API origin: `https://offline-pos-wtl8.onrender.com`.

## Hosted RC validation (2026-10-28)

- `/healthz` returned HTTP 200 with `{"status":"ok"}`. A synthetic unknown-key activation returned database-backed `404 not_found`.
- `scripts/hosted-smoke.mjs` authenticated through the protected admin API, checked both migrated plans, created a disposable customer/license, activated one synthetic device, checked its device record, and verified the hosted Ed25519 signature with the existing local public key. The test license expires after 24 hours. This validates the live licensing schema through the API; the `schema_migrations` ledger was not queried directly.
- An isolated Windows Release build activated with the hosted API and unchanged public key, completed Owner setup/login, and displayed Home and POS. A separate launcher confirmed the Render HTTPS endpoint was unreachable before the same isolated profile restarted; login, Home, and POS worked offline.
- A freshly installed Android emulator APK activated, reached Home and POS, then reopened after Wi-Fi and mobile data were disabled. While Render was unreachable from the emulator, local login, Home, and POS worked. Network access was restored afterward.
- The test activation key was rotated once after its one-time terminal output was lost. Rotation did not change the already signed Windows license. No private key, database password, admin password, or activation key was committed.

## Supabase PostgreSQL

1. Create a Supabase Free project dedicated to licensing. In the project, open **Connect** and copy the PostgreSQL **Session pooler** connection string (port 5432). This is suitable when direct IPv6 connectivity is unavailable. Replace the password placeholder locally; percent-encode reserved password characters. Do not paste the resulting URL into chat, Git, or logs.
2. In **Project Settings → Database → SSL Configuration**, enable SSL enforcement and download the project CA certificate. The certificate is public; its exact PEM text belongs in Render's `DB_SSL_CA_CERT` environment variable. The API verifies both CA and hostname. It accepts either real PEM newlines or literal `\n` separators.
3. Set `DATABASE_URL` to the session pooler connection string in Render. The existing SQL migrations are `001_initial.sql`, `002_bir_plan.sql`, and `003_customer_notes.sql`. Render's start command runs `npm run migrate` before `npm start`. Migrations are transactional and recorded in `schema_migrations`.
4. Before connecting any existing database, verify it is dedicated to licensing. These migrations create/update only `schema_migrations`, `customers`, `plans`, `licenses`, `devices`, `activation_events`, and `admin_events`; they do not contain POS sales, inventory, customer business SQLite, or BIR records. After deploy, use the Supabase Table Editor to confirm those tables and two plan rows exist. Do not upload the POS SQLite database.

## Render Web Service

For the existing `offline-pos-wtl8` service, apply the settings in steps 2–4
after reviewing and pushing the same-origin dashboard change. In **Settings →
Build & Deploy**, change the old `cloud/license_api` Root Directory to `cloud`, then set
the Build and Start commands below. Keep the current server secrets in Render;
do not recreate or expose them. In **Environment**, keep `ADMIN_ORIGIN` set to
`https://offline-pos-wtl8.onrender.com` and remove any `VITE_LICENSE_API_URL`
entry if present. A separate Render Static Site is not needed.

1. Create a Render account. Choose **New → Web Service**, connect the GitHub repository containing this working tree, and select the correct branch after these changes have been pushed by the repository owner.
2. Set **Root Directory** to `cloud`, so Render can access both `license_api` and `admin_dashboard` without the Flutter tree. Set **Runtime** to Node and **Instance Type** to Free if offered. Set `NODE_VERSION` to a Node 20 release supported by Vite 7 (20.19 or newer) or a newer supported major release.
3. Set **Build Command** to `cd license_api && npm ci && npm run build` and **Start Command** to `cd license_api && npm run migrate && npm start`. Set **Health Check Path** to `/healthz`. The API's build script installs and builds the dashboard; the API serves its compiled files at `/`.
4. Add these environment variables in Render (never commit actual values):

   | Variable | Value/source |
   | --- | --- |
   | `DATABASE_URL` | Supabase PostgreSQL session pooler URL, including password |
   | `DB_SSL_CA_CERT` | Supabase downloaded CA PEM |
   | `LICENSE_SIGNING_PRIVATE_KEY` | Base64 contents of the **existing** ignored `cloud/license_api/license-private.key` (64-byte secret); enter directly in Render |
   | `ADMIN_USERNAME` | Existing admin username |
   | `ADMIN_PASSWORD_HASH` | Existing salted scrypt hash; `npm run setup:admin` can produce one from a password on stdin |
   | `ADMIN_AUTH_SECRET` | Existing secret of at least 32 characters, or a newly generated admin session secret |
   | `ADMIN_ORIGIN` | `https://offline-pos-wtl8.onrender.com` for the same-origin dashboard and API |
   | `NODE_ENV` | `production` |
   | `DB_POOL_MAX` | `5` to keep free database connection use modest |

   Render sets `PORT` automatically; the API binds that port on `0.0.0.0`. Do not add signing material to Flutter or the dashboard. A private key value already in the ignored local `.env` can be reused if it matches the existing public key; no re-encoding is needed.
   The hosted dashboard needs no `VITE_LICENSE_API_URL`: its production bundle calls the API through relative same-origin paths. Leave any existing Render `VITE_LICENSE_API_URL` unset or remove it; never add backend secrets to a `VITE_` variable.
5. Deploy and copy the **actual** Render HTTPS service URL. Check `https://<actual-host>/healthz` returns `{"status":"ok"}`. The endpoint reports process health only; the migration must succeed before the server starts.

## Validation and release configuration

Use a clean test license and test account only. Confirm admin login, customer creation, license issuance, and activation using the current API contract; the full activation key is returned once. Admin requests require the signed cookie and exact `Origin` on mutations. Confirm the returned signed envelope verifies with the existing public key before building a POS release. Do not print keys, passwords, full database URLs, cookies, or activation keys in logs or chat.

The hosted dashboard and API share one origin. The admin cookie remains `SameSite=Strict`, and admin mutations still require an exact `ADMIN_ORIGIN` match. The dashboard uses in-page navigation only, so the server serves `/` and Vite assets without a catch-all that could swallow API routes. For local Vite development, `VITE_LICENSE_API_URL` may still point to the local API.

For release builds, pass the actual Render origin to `scripts/build-release.ps1 -LicenseApiUrl https://<actual-host>`. The script reads the existing ignored public key file and supplies `LICENSE_PUBLIC_KEY_BASE64`; it never packages the private key. Use `-IsolatedSmoke` for a Windows internal smoke build. On a clean isolated Windows profile, activate, close, disconnect, and reopen offline. Repeat on an Android emulator if available. The 15-second activation request stages may need adjustment only if measured cold starts consistently exceed them. Render Free services can sleep when idle, so the first activation may be slower; retry is already available in the activation UI.

Free hosting is suitable for internal RC testing, not a production availability commitment. The existing per-process rate limit remains in place; a shared limiter is needed before scaling to multiple instances. Android application ID, production signing, and physical-device testing remain separate release work.

Provider references: [Supabase connection and SSL guidance](https://supabase.com/docs/guides/database/connecting-to-postgres), [Render web service setup](https://render.com/docs/web-services), [Render Free limitations](https://render.com/docs/free).
