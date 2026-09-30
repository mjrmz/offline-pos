# MASD POS — Architecture

## 1. System overview

```
                    MASD CLOUD
        ┌─────────────────────────────┐
        │  License API                │
        │  PostgreSQL                 │
        │   (Customers, Licenses,     │
        │    Devices, Activations,    │
        │    Revocations)             │
        │  Admin Dashboard (web)      │
        └──────────────┬──────────────┘
                        │ HTTPS
                  ONLY FOR ACTIVATION
                        │
        ┌───────────────▼───────────────┐
        │   MASD POS (Flutter app)      │
        │   Runs on: Android / iOS /    │
        │   Windows / macOS / Linux     │
        │                                │
        │   Local SQLite (drift)        │
        │   Local signed license        │
        │   Local backups                │
        │                                │
        │   OFFLINE OPERATION            │
        │   POS ✓  Inventory ✓  Sales ✓  │
        │   Reports ✓  Printing ✓        │
        └────────────────────────────────┘
```

Each installed device is a standalone island: its own local database, its own
signed license, its own backups. There is no cross-device sync unless it is
deliberately added later as an opt-in feature.

## 2. Technology stack

| Layer | Choice | Why |
|---|---|---|
| App (all platforms) | Flutter / Dart | One codebase for phone, tablet, laptop, desktop; mature offline-first story; developer already has Flutter experience |
| Local database | SQLite via `drift` | Reactive queries, migrations, works identically across all target platforms |
| Licensing crypto | Ed25519 signatures | Small, fast, well-supported signing scheme for offline-verifiable licenses |
| License API | ASP.NET Core (or Node/Express) | Thin, low-traffic REST service — framework choice here matters less than on the client |
| License database | PostgreSQL | Relational, handles customers/licenses/devices/audit logs cleanly at scale |
| Admin dashboard | React / Next.js | Reuses existing frontend skillset from other projects; separate deployable from the POS app |

## 3. Client-side layering

```
features/   →  UI screens, per-platform responsive layout
   │
   ▼
core/       →  business logic (pure Dart, no Flutter imports)
   │
   ▼
data/       →  SQLite access via drift (transactions, migrations)
```

Rule: if a file in `core/` or `data/` needs to import anything from
`package:flutter/material.dart`, that logic belongs in `features/` instead.
This boundary is what keeps business logic unit-testable without a UI, and
keeps the same logic reusable if a second front-end (e.g. a lightweight
owner-only companion app) is ever built.

`hardware/` sits beside `core/` as the one layer that is genuinely
platform-specific: printers, barcode scanners, and cash drawers behave
differently per platform. It is isolated behind interfaces so the rest of the
app never needs to know which platform it's running on.

## 4. Data integrity rules

- Every multi-step write (sale + inventory deduction + payment + audit log)
  happens inside a single database transaction. If any step fails, the whole
  transaction rolls back — never a sale without inventory deducted, or
  inventory deducted without a recorded sale.
- Nothing is hard-deleted if it affects historical accuracy. Products are
  deactivated (`isActive = false`), not deleted. Sales are voided or refunded,
  never deleted.
- A sale is only considered complete once the database transaction commits.
  Printing happens *after* commit — if the printer fails, the sale still
  stands and the receipt can be reprinted.

## 5. Licensing architecture

See `docs/LICENSING.md` for full detail. Summary:

The Phase 6 licensed client targets Windows and Android. The signed-license
file is outside local SQLite and its backups. Database health takes priority
over activation during startup. Valid local verification makes no HTTP call.

1. App generates a device ID on first launch.
2. Customer enters an activation key (issued after purchase).
3. App sends device ID + activation key to the License API over HTTPS.
4. License API validates the key, binds the device, and returns a signed
   license (Ed25519).
5. App verifies the signature locally and stores the license.
6. From this point on, internet can be disconnected permanently. All future
   license checks are verified locally against the stored signed license.
7. If the cloud License API is ever down, already-activated devices are
   unaffected — they never depend on reaching the server again for normal use.

## 6. Offline-first guarantee

After activation, the following require zero internet connectivity:

- Point-of-sale checkout
- Inventory management
- Sales history and reports
- Barcode scanning
- Receipt printing and cash drawer triggering
- Local backup and restore
- Cashier and admin login

Internet is only ever used for: initial activation, optional device
transfer/reactivation, and optional future software update checks (which the
app must never block on).

## 7. Data export

Sales/reports data can be exported to CSV/Excel directly from the device —
a read-only export of local data, not a sync mechanism, requires no
internet. Lets an owner or their accountant/bookkeeper work with the
shop's own records outside the app. Implemented as a `core/` service that
queries the local database and writes a file, with a platform-specific
share/save step in `features/`.

## 7.1 Bulk product import (CSV)

Reduces onboarding friction for shops with large existing catalogs
(hardware, electronics) — import products from a spreadsheet during setup
instead of entering each one manually. A `core/` service parses a CSV
(name, SKU, barcode, price, cost) and writes Products in a single
transaction, with row-level validation errors reported back before
anything is committed (all-or-nothing import, not partial).

## 7.2 Quotations

A quotation is a saved cart with pricing that has NOT been committed as a
sale — no inventory deduction, no payment. Common in hardware/electronics
where a customer wants a price before deciding. Printable/savable, and
convertible into an actual Sale later (which then does trigger the normal
transactional checkout flow, inventory deduction included). Stored
separately from Sales so an abandoned quotation never affects reports or
inventory.

## 7.3 GCash / QR Ph payments — manual confirmation only

GCash is effectively expected by PH customers, so it's a supported
Payment method — but no live QR generation or payment API integration is
built, deliberately. The flow: customer pays via their own GCash app to
the shop's existing number/QR code (printed/displayed, not generated
per-transaction), and the cashier marks the payment as received before
completing the sale. This closes the real customer expectation (GCash
works here) without requiring internet at checkout, which would
undermine the offline-first guarantee. See docs/DATABASE_SCHEMA.md for
the `Payments.ConfirmedByUserId` field this relies on.

## 7.4 Real-time low-stock alerts

A dashboard banner (e.g. "⚠ 3 items low on stock"), checked after every
completed sale rather than only surfaced when the owner opens the
Inventory report. No new data — reuses the existing InventoryMovements
ledger and each product's configured low-stock threshold. Purely a
`features/dashboard/` presentation concern on top of an existing `core/`
query.

## 7.5 End-of-day closing

A single "close my day" action in `features/cash_session/` that combines:
closing the active CashSession (starting cash, expected vs. actual,
variance) and generating a printable/exportable daily summary (total
sales, cash breakdown, top items) in one flow, instead of an owner
checking Cash Sessions and Reports separately. Composes existing data
from CashSessions, Sales, and SaleItems — no new tables.

## 8. Cross-platform considerations

- **Windows/desktop and laptop**: test explicitly on low-spec hardware
  (Celeron CPU, 2GB RAM) — do not assume "builds and runs on a dev machine"
  means "runs acceptably on a customer's old secondhand PC."
- **Android tablet/phone**: generally the more forgiving target for low-spec
  hardware; also has the more mature ecosystem for POS peripherals
  (ESC/POS printer libraries, barcode scanning, cash drawer triggers).
- **iOS**: distribution is meaningfully harder than Android (no simple
  sideloading) — only build this out if iPhone support is a confirmed,
  real requirement from customers, not a "nice to have."
- **Responsive layout, not duplicated screens**: use breakpoints to adapt
  the same widget tree across phone/tablet/desktop rather than maintaining
  separate screen trees per platform.

## 9. What the cloud side does NOT do

The License API and admin dashboard are intentionally kept minimal in scope:

- They do not store or process customer business data (sales, inventory,
  products) — that all stays local to each device.
- They are not required for the POS app to function day-to-day.
- They should be treated as a separate deployable with its own release cycle,
  not bundled into the Flutter app's build process.
