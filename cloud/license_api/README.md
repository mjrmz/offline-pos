# License API

Node/Express API with PostgreSQL. This service holds licensing data only.
See [licensing setup](../../docs/LICENSING.md#local-setup-and-manual-verification).

1. `npm install`
2. Create a dedicated PostgreSQL database; copy `.env.example` to an
   untracked `.env` and set its variables.
3. `npm run setup:keys` creates ignored `license-private.key` and
   `license-public.key`. Keep the private file server-only. Set
   `LICENSE_SIGNING_PRIVATE_KEY` to its base64 contents in the API secret
   environment, never in Flutter or the dashboard.
4. Pipe a strong admin password to `npm run setup:admin` and put the
   resulting salted scrypt hash into `ADMIN_PASSWORD_HASH`. Keep the
   plaintext password out of shell history and Git.
5. `npm run migrate`, then `npm start`.

`npm run check` checks syntax. `npm test` runs signing and route tests.
With `TEST_DATABASE_URL` set to a **disposable** PostgreSQL database, it
also runs a real database concurrency and transfer test in a temporary
schema. The test removes only that temporary schema afterward.

Activation endpoint: `POST /v1/activate`. Admin endpoints require a signed
HttpOnly cookie and an exact configured Origin on mutations. The API uses
one license row lock per activation to enforce device allowances. The rate
limiter is process-local; use a shared store for a scaled multi-instance
deployment. Serve production API only behind HTTPS.
