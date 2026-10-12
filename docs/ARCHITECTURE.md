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

The app supports System, Light, and Dark appearance. `AppTheme` defines both
palettes; `ThemeModeController` owns the selected mode and saves only
`system`, `light`, or `dark` under `appearance.themeMode` in device-local
SharedPreferences. A fresh installation defaults to System, which follows the
operating system appearance. Existing installations without this preference
also use System. Changes apply immediately without rebuilding business state
or modifying the SQLite database.

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
# Phase 7 compliance restore boundary

The local signed license decides BIR entitlement. SQLite schema version 8
adds invoice, compliance-state, and Z-reading records to the same database.
Checkout and cash-session close update these records inside their existing
SQLite transactions. SQLite is the live source for sale and Z rows. An
installation-local append-only compliance journal protects their monotonic
invoice, grand-total, and Z state against replacement of that database.
Before the SQLite commit, the app writes a numbered reservation containing
the intended sale or Z identity and complete compliance state to both journal
copies. Both copies and the journal head must acknowledge the reservation
before the transaction can commit. After commit, a finalize record is written.
Clean transaction rollback writes an abort record and can safely reuse the
number. The application serializes BIR checkout and Z close through this
protocol.

The files `compliance-protection.json.journal-a` and `.journal-b` contain
hash-chained JSON records. `.journal-head` and `.journal-head.previous` retain
checksummed durable sequence heads; `.journal-active` marks a BIR installation.
Writes use Dart `File.writeAsString(flush: true)`; head replacement uses a
flushed temporary file and rename, retaining the previous generation. A
shorter or damaged single journal copy can be repaired from the other. If
both copies or the head cannot prove the protected sequence, BIR issuance
stops and recovery mode reports the error. This protocol depends on the
platform honoring Dart's file flush and rename behavior; it cannot guarantee
survival of simultaneous loss or deliberate deletion of all local protection
files, or a storage device that falsely acknowledges a flush.

On startup and after restore, a pending reservation is finalized automatically
only when the matching SQLite row exists. If the row is absent, the app cannot
distinguish an uncommitted transaction from a committed row lost with the
database, so BIR issuance stays blocked for supervised recovery. A finalized
journal reconciles an older restored database upward, including grand total
and retained Z snapshots. Backup snapshots contain SQLite only; the protected
journal remains installation-local. A backup transferred to another device
does not carry a continuous BIR sequence. The former single-file
`compliance-protection.json` mirror is migrated only when the live database
can validate its state; a historical commit lost before that old mirror was
written cannot be reconstructed.

## Phase 8 local business capabilities

The six business features are local configuration, separate from the signed
license. Setup asks “What do you sell?” with independent choices; Owner
Settings can change them later. Store flags govern which product fields may be
edited. Existing configured products keep their runtime behavior while a flag
is off. Product configuration is stored by product and feature in the same
SQLite database and backup path.

One checkout path handles ordinary and specialty cart lines. The repository
revalidates sale mode, unit precision, stock, batch eligibility, and extra
charges inside the existing transaction before reserving any BIR invoice.
Quantity math uses integer thousandths and integer-cent half-up line rounding.
SaleItem stores the transaction-time unit, mode, batch, and charge snapshot;
receipt and history never reinterpret it from current catalog settings.
Batch stock and full-tank/refill stock use Inventory and its movement ledger;
batch rows and returned-empty-tank movements are additional local records.
## Unified Inventory workspace and acquisition layers

The sidebar exposes one Inventory destination with Overview, Products,
Receiving, and Movements views. Product is catalog configuration and the
current reference purchase cost/selling price. Receiving is a supplier
delivery. Each finalized receiving line creates an InventoryLayer with its
own remaining thousandth quantity, cost, optional selling price, batch, and
receipt link. The receipt supplies supplier provenance. Opening stock is
pre-existing inventory: it creates an `opening` layer without a supplier or
receiving document. Its cost snapshots Product current purchase cost; layer
price mode snapshots Product selling price. Serialized opening stock requires
one unique serial per unit linked to that layer. Batch opening stock retains
its batch metadata. Legacy opening stock has no invented supplier.

Ordinary stock is consumed FIFO by received time and stable layer ID.
Serialized checkout uses the selected serial's exact layer. Batch checkout
keeps its existing explicit batch selection and allocates only inside that
batch; it does not silently use FEFO. Every SaleItem consumption persists
allocation quantity, cost, and selling price snapshots. Current price mode
charges the current Product price while keeping each consumed layer cost.
Layer price mode charges each consumed layer's price, falling back to Product
price where an older layer has no override. When prices differ, checkout
persists separate SaleItems under the same Sale and BIR invoice. All amounts
are integer cents and quantities are integer thousandths.

Receiving, sale allocation, stock balance, serial state, payment, and movement
writes share their existing transactions. A full void or restocked full-sale
refund restores original layer quantities. RMA supplier quarantine and
restock use the receiving layer; customer restock uses original sale
allocations. Layaway still reserves available stock before final sale and
consumes layers only at completion. Historic sale prices and acquisition costs
do not change when current Product defaults are edited.
Existing reports continue to show sales and cash metrics; they do not yet
expose a historical COGS or gross-margin read model. Allocation snapshots
are the source for any future margin calculation.
Quotation conversion and layaway completion continue to honor their saved
selling-price snapshots; they do not reprice from later receiving layers.

# Phase 8.5 local records

Customer and supplier directories, petty cash, and price history live in the
same local SQLite database as sales. Their writes use the existing Drift
transaction and audit pattern. No new network dependency was added.
Schema 12 links each sale to its cash session. Z-reading sales and reversals
come from sale rows; expected drawer cash still comes from cash movements.
Schema 13 links sales to customers and adds an append-only credit ledger.
Credit checkout records cash and receivable separately while the BIR invoice
and grand total use the full sale amount. Debt payment creates no product sale
or BIR invoice.
Schema 17 supports mixed-credit reversal with a confirmed cash payout in an
open session. A reversal offsets the pooled receivable only up to its current
balance. Previously paid excess becomes an explicit customer refund obligation,
separate from debt. Its later cash or confirmed GCash settlement is recorded
with an append-only settlement and audit event. Cash payout decreases the
current drawer; neither payout nor debt settlement creates a new sale.
Supplier receiving is a separate local workflow. One transaction writes its
header and lines, inventory and batch changes, movement ledger, and audit.
Serial-enabled products receive only through supplier receiving. One unique
serial is required per unit, and a sale selects exact available serials in
the same inventory transaction. An append-only sale link preserves serial
history when a restocked void makes a unit available again.
Schema 22 customer claims use `RmaLifecycleRepository` and append-only
`rma_lifecycle_events`. Request, approval, receipt, inspection, intent,
disposition, financial execution, replacement reservation, supplier action,
handoff, and completion are separate local transactions. Physical receipt
does not increase sellable stock. Legacy RMA rows retain their original
`rma_events`; missing physical facts are not inferred. See [RMA.md](RMA.md).

Customer RMA intake searches receipts, customers, products, and serials;
supplier intake searches receiving records, suppliers, products, batches, and
serials. Both retain status events. Supplier intake quarantines measured stock,
including batch quantities and serials; restock disposition restores it.
Customer same-item replacement deducts stock and records its issued serial
against the case without changing the sale or issuing an invoice. Repaired
return restores the original serial to its sold state. Item-level RMA refunds
reuse the shared sale reversal accounting path: the original SaleItem snapshot
sets the amount; pooled credit is allocated proportionally with cumulative
integer rounding; receivables are offset up to the current balance and the
remainder is paid from an open drawer or retained as a refund obligation.
Original sales and invoices remain unchanged. The RMA disposition controls
stock separately. A supplier replacement creates a linked receiving record;
its replacement serial or batch becomes available once while the defective
original remains unavailable.
Quotations are stored separately from sales and convert once through the
normal checkout transaction at their saved prices.
Layaway reserves quantities against physical stock. Ordinary checkout uses
physical minus active reservations; serialized units have a reserved status.
Inventory layers retain the FIFO provenance and remaining physical quantities.
The `inventory` row is the transactionally maintained physical stock projection;
receiving, sales, and stock adjustments update it alongside layers and movement
history. Active layaway items supply the reserved amount. Inventory and POS read
the same physical and reserved totals through `PosRepository.stockLevels()`;
available stock is physical minus reserved. The mounted POS catalog watches the
tables that affect its products and availability, so receiving and catalog edits
appear without restarting the application.
Deposits and later payments affect cash sessions when cash is collected, while
the full Sale and BIR invoice occur only on completion. Cancellation releases
reservations and records money owed back as a customer refund obligation.
# Cash shift ownership

POS owns the current cashier's normal shift lifecycle: opening cash, opening the shift, reviewing expected cash and variance, and closing the shift. Cash Session provides read-only current status and details, previous shift reconciliation, and Z-reading history. Administrative handling of another user's shift remains subject to existing permissions and repository rules. Both screens use the same Cash Session repository; this split changes only the user interface.
The POS "Shift open" amount is expected cash: opening cash plus recorded cash movements. It equals opening cash immediately after a new shift opens, and changes as cash sales and other movements are recorded. An open session remains open across app restarts until it is explicitly closed.
