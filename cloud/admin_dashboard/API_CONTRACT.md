# Admin dashboard API contract

All routes below are mounted directly by `createApp()` in the License API.
Admin routes require the admin session cookie. Mutations also require the
configured Origin. Successful responses use JSON.

| Frontend request | Backend route | Expected response |
| --- | --- | --- |
| GET `/admin/me` | `/admin/me` | `{user}` |
| POST `/admin/login` | `/admin/login` | `{user}` |
| POST `/admin/logout` | `/admin/logout` | `{ok:true}` |
| GET `/admin/customers` | `/admin/customers` | Customer array (currently latest 100) |
| POST `/admin/customers` | `/admin/customers` | Created customer including `id`, `business_name`, optional phone and notes |
| GET `/admin/plans` | `/admin/plans` | Plan array |
| GET `/admin/licenses` | `/admin/licenses` | License array with customer name and active device count (currently latest 100) |
| POST `/admin/licenses` | `/admin/licenses` | `{id,status,activationKey}`; key is shown once |
| GET `/admin/licenses/:id/devices` | `/admin/licenses/:id/devices` | Device array for license detail |
| GET `/admin/devices` | `/admin/devices` | Device array with customer name (currently latest 500) |
| GET `/admin/activity` | `/admin/activity` | Unified activation/admin event array (currently latest 200) |
| POST `/admin/licenses/:id/activation-key/rotate` | same | `{id,activationKey}`; key is shown once |
| POST `/admin/licenses/:id/edition` | same | `{id,plan_id}` |
| POST `/admin/licenses/:id/revoke` | same | `{ok:true}` |
| POST `/admin/devices/:id/deactivate` | same | `{ok:true}` |

No route or HTTP method mismatch remains in the source. The reported HTML
404 came from a running API instance that did not have the dashboard's newer
`/admin/activity` route, combined with the previous frontend's unconditional
`response.json()`. Restart the API after deploying route changes. The
frontend now treats an unavailable Activity route as an Activity-only error.

The current list limits remain. Search/filter on the dashboard operates on
loaded rows; server pagination and server search are future work. The Devices
view uses the aggregate endpoint and is no longer derived from loaded licenses.
Migration `003_customer_notes.sql` adds the optional customer notes column
without modifying existing customer or license records.
