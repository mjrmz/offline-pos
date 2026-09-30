# Licensing admin dashboard

Separate React/Vite deployable for MASD licensing administration. It never
contains the signing private key or POS business data.

Run `npm install`, copy `.env.example` to an untracked `.env` and set
`VITE_LICENSE_API_URL`, then `npm run dev`. Configure the API's `ADMIN_ORIGIN`
to match this dashboard's exact origin. Use HTTPS for both in deployment.

`npm run check` typechecks, and `npm run build` creates `dist/`. Login is
handled by the License API with an HttpOnly signed cookie. The dashboard
lists and creates customers, issues licenses and displays the generated key
once, lists licenses and devices, deactivates devices, revokes licenses,
and displays activation events.
