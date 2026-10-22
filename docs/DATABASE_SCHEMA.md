# Local Database Schema (SQLite via drift)

Schema 40 adds normalized `roles` and `role_permissions` tables. Built-in
`owner`, `manager`, and `cashier` codes are seeded with their existing effective
access. The existing `users.role` column remains the single role code for each
user; this avoids rewriting user rows, credentials, and historical audit data.
New custom codes are UUIDs. Triggers reject unknown role codes on user insert
and role change. Custom role deletion is blocked while assigned. Backups at
version 40 verify valid role references, an active Owner for populated user
databases, and recognized permission keys. Earlier backups migrate on open.

Owner recovery, backup and restore, role administration, and the last active
Owner safeguard remain tied to Owner identity. Serial mismatch overrides and
opening cash funds also retain their existing Owner identity checks. Built-in
role definitions are read-only; custom roles provide editable access.

Schema 39 adds `purchase_order_line_source_links` for durable quotation sourcing,
nullable PO `sent_by` and `closed_by`, and Receiving `finalized_at`. Source
links retain their quotation item identifier and planned quantity when a
quotation is edited; old note-only POs are not automatically linked.

Schema 38 adds a nullable, unique `stock_receivings.sequence` for stable
human `RCV-` references. Migration assigns existing rows by insertion order;
new finalized Receivings take the next local number. Backup verification
requires the column for schema 38 and continues to accept older backups.

Schema 37 adds singleton `inventory_health_settings` with slow-moving,
dead-stock, and near-expiry day thresholds (defaults 60, 180, and 30).
The migration is additive. Derived health, aging, and expiry values remain
read models based on sales and remaining inventory layers.

Schema 36 adds nullable product reorder level, target stock (integer
thousandths), and preferred supplier configuration.

Schema 35 adds `held_sales` for persistent POS drafts and `sale_manual_discounts`
for authorized discount snapshots. `sales` gains nullable `walk_in_name`,
`walk_in_contact`, and `held_reference`; `sale_items` gains
`manual_discount_cents`. Existing rows retain their values through an additive
migration. Held drafts do not reserve stock and are included in backups.

This is the local, per-device database. It is the source of truth for that
device — never the UI, never the cloud.

## Core tables

**Products**
- Id, SKU, Barcode, Name, Price, Cost, IsActive
- Never hard-deleted — deactivate via `IsActive = false` so historical sales
  referencing the product remain intact.

**Categories** — Id, Name, ParentCategoryId (optional)

**Inventory** — current stock level per product

**InventoryMovements** — append-only ledger of every stock change
(+50 initial stock, -2 sale, +10 purchase, -1 damaged, +5 adjustment). This is
what lets you answer "why does this product have 62 units?" instead of just
showing a number with no history.

## Sales tables

**Sales** — Id, Timestamp, CashierId, Status (Completed/Voided/Refunded), Total

**SaleItems** — Id, SaleId, ProductId, ProductName, Quantity, UnitPrice, LineTotal
- `ProductName` is captured when the sale commits. Receipts and reprints use
  this historical name and the stored unit price and line total, so later
  product edits do not change the receipt. The Phase 4 forward migration fills
  names on older sale items from the catalog name available at migration time.

**Payments** — Id, SaleId, Method (Cash/GCash/Card/Other), Amount,
ConfirmedByUserId (nullable — set for GCash/e-wallet payments where the
cashier manually confirms receipt; not needed for Cash)

**Returns / Voids** — never delete a Sale row; record a Return or Void event
that references the original sale and adjusts inventory accordingly.

## People & access

**Customers** — optional, for stores that track customer purchase history

**Suppliers**

**Users** — Id, Name, PasswordHash (admin) or PinHash (cashier), Role

**Roles** — Cashier / Manager / Owner-Admin (see `docs/AUTH_AND_ROLES.md`)

## Cash management

**CashSessions** — Id, OpenedByUserId, OpenedAt, StartingCashCents,
ClosedAt (nullable), ExpectedCashCents (nullable), ActualCashCents (nullable).
Variance is calculated as actual minus expected; it is not stored. Only one
session can be active on this device. Closed sessions remain historical.

**CashMovements** — Id, SessionId, SaleId (nullable, unique), AmountCents,
Kind, CreatedAt. Phase 5 writes `cash_sale` in the same transaction as the sale,
when a session is open. Expected cash is starting cash plus the session's
persisted movement amounts. Existing refund reversals do not record an actual
cash payout, so they do not reduce expected cash. Future cash payout tracking
must persist an actual payout before it affects this calculation.

## Operational

**AuditLogs** — every login, void, refund, inventory adjustment, and settings
change — who, what, when. This is what resolves "who voided this sale"
disputes later.

**Settings** — one local row (`Id = 1`) for implemented Phase 4 store/device
configuration: `StoreName`, `PrinterEnabled`, `PrinterTransport` (`lan`, `usb`,
or `bluetooth`), `PrinterHost` and `PrinterPort` for LAN, `PrinterDeviceId` and
`PrinterDeviceName` for a selected USB/Bluetooth printer, `PrinterWidthMm`
(58 or 80), and `DrawerEnabled`. A forward migration adds this table; existing
Phase 4 printer preferences are imported into the row on first use.
Other documented Settings capabilities are added in their respective phases.

**DatabaseMigrations** — tracks applied schema versions

## Electronics/computer shop tables (RMA / warranty tracking toggle)

**ProductSerials** — one row per physical unit, not per SKU
- Id, ProductId, SerialNumber (or IMEI), Status (InStock/Sold/UnderRMA/Returned),
  SaleItemId (nullable — set once sold), ReceivingId (nullable — links to
  the delivery it arrived in)
- Enables per-unit warranty lookups instead of just per-SKU quantity

**StockReceivings** — minimal delivery/receiving record; a lightweight
predecessor to a full PurchaseOrders system, needed as the anchor point
for inbound RMAs
- Id, SupplierName, ReceivedAt, ReferenceNumber, Notes

**StockReceivingItems** — line items per receiving
- Id, StockReceivingId, ProductId, Quantity, SerialNumbers (if serial
  tracking is on for this product)

**RmaCases** — one row per warranty/return case, either origin
- Id, Origin ('customer' | 'inbound'), Status ('pending' | 'sent_to_supplier'
  | 'resolved' | 'rejected')
- SaleItemId (nullable — set for customer-origin RMAs)
- StockReceivingItemId (nullable — set for inbound-origin RMAs)
- ProductSerialId (nullable — set when serial tracking is on)
- SupplierName, SupplierReferenceNumber, Notes
- OpenedAt, ResolvedAt, Resolution ('replaced' | 'repaired' | 'refunded' | 'rejected')

**RmaStatusHistory** — append-only log of status changes on an RmaCase,
mirroring the InventoryMovements pattern — answers "what happened to this
RMA and when," not just its current status

## Utang / credit sales (running tab toggle)

**Customers** — extends the optional Customers table already noted in the
core schema; adds RunningBalanceCents so it can double as the utang ledger

**CreditSales** — one row per sale made on credit instead of paid in full
- Id, SaleId, CustomerId, AmountCents, Status ('open' | 'partially_paid' | 'settled')

**CreditPayments** — partial or full payments against a customer's balance
- Id, CustomerId, AmountCents, PaidAt, Notes
- CreditSales and CreditPayments both post to the same running balance —
  a customer's total utang is always derivable, not stored redundantly

## Discounts (Senior/PWD + general promos toggle)

**DiscountTypes** — configurable discount rules
- Id, Name, Type ('percentage' | 'fixed_amount'), Value, RequiresId (bool
  — true for Senior/PWD)

**SaleDiscounts** — applied discount(s) per sale
- Id, SaleId, DiscountTypeId, AmountCents, IdNumber (nullable — captured
  when RequiresId is true, e.g. Senior Citizen/PWD ID), HolderName
  (nullable, same condition)
- Senior/PWD discounts are just a DiscountType with RequiresId = true and
  the correct percentage/VAT-exemption rule applied — same mechanism as
  any other discount, not a separate system

## Supplier accounts payable (toggle)

**Suppliers** — Id, Name, ContactInfo
- StockReceivings (already defined above) references SupplierName as
  free text today; if this toggle is on, link it to a real Suppliers.Id
  instead

**SupplierPayments** — payments made against what's owed to a supplier
- Id, SupplierId, StockReceivingId (nullable — payment may cover
  multiple receivings or be a general payment), AmountCents, PaidAt, Notes
- What's owed to a supplier is derived from StockReceivings' item costs
  minus SupplierPayments made — same running-balance pattern as utang

## Loyalty points (toggle)

**LoyaltyPointEvents** — append-only ledger, same pattern as
InventoryMovements — a customer's point balance is always derived from
this, never stored redundantly
- Id, CustomerId, SaleId (nullable — set when points are earned from a
  sale), PointsDelta (positive = earned, negative = redeemed),
  Reason ('earned' | 'redeemed' | 'adjustment'), CreatedAt
- Earn rate (points per peso) and redemption value are configurable in
  Settings, not hardcoded

## Price change history (toggle)

**PriceHistory** — append-only log of price changes per product
- Id, ProductId, OldPriceCents, NewPriceCents, ChangedByUserId, ChangedAt
- Written automatically whenever a product's price is edited — no manual
  step required, so the audit trail can't be skipped

## Quotations

**Quotations** — saved carts that are NOT sales; no inventory deduction,
no payment, convertible into a real Sale later
- Id, CustomerId (nullable), TotalCents, Status ('open' | 'converted' | 'expired'),
  ConvertedToSaleId (nullable), CreatedAt

**QuotationItems** — mirrors SaleItems structure
- Id, QuotationId, ProductId, Quantity, UnitPriceCents

## Layaway / reserved stock

**Layaways** — a sale-in-progress: deposit taken, stock reserved, balance
paid over time, same running-balance shape as CreditSales
- Id, CustomerId, TotalCents, DepositCents, Status ('active' | 'completed' | 'cancelled'),
  ReservedAt, CompletedAt (nullable)

**LayawayItems** — products/serials reserved against a layaway
- Id, LayawayId, ProductId, Quantity, ProductSerialId (nullable — set when
  serial tracking is on, marks that specific unit as reserved, not
  sellable, until the layaway completes or cancels)

**LayawayPayments** — partial payments toward a layaway balance
- Id, LayawayId, AmountCents, PaidAt

## Void/refund reason codes

**VoidReasons** / **RefundReasons** — small, configurable lookup tables
(e.g. wrong item, customer changed mind, damaged, price error)
- Id, Label

Extends the existing Sales.status change to require a ReasonId — makes
AuditLogs entries for voids/refunds actually filterable/reportable
("40 voids this month, 25 were price errors") instead of just a raw count.

## Petty cash / expense tracking

**Expenses** — day-to-day cash outflows logged against a cash session,
separate from sales
- Id, CashSessionId, AmountCents, Description, RecordedByUserId, RecordedAt
- Factored into the existing CashSessions expected-vs-actual variance
  calculation, so "how much cash should be in the drawer" accounts for
  more than just sales

## Agent services (cash-in/cash-out)

**AgentTransactions** — ledger only; the actual money movement happens
in the owner's own GCash/PayMaya agent app, outside this product
- Id, CashSessionId, Type ('cash_in' | 'cash_out' | 'bills_payment' | 'load'),
  AmountCents, CommissionCents, CustomerReference (nullable), RecordedByUserId,
  RecordedAt
- Commission income is summable per day/month for a dedicated report
- Factored into the CashSessions expected-vs-actual variance calculation,
  same pattern as Expenses above — this cash flow affects what should be
  in the drawer

## Receipt customization

**Settings** (existing table, extended) — adds StoreLogoPath, ReceiptHeaderText,
ReceiptFooterText fields alongside the existing store configuration
- No new table needed — this is additional fields on the Settings row
  already defined in the core schema above

## Deferred / later phases

- BarcodeAliases (multiple barcodes per product)
- StockAdjustments (structured, reason-coded adjustments beyond raw movements)
- Full PurchaseOrders (StockReceivings above covers the minimal case needed
  for inbound RMA; a full PO system with ordering/approval workflow is
  still deferred)

## Integrity rules

- All multi-step writes (e.g. completing a sale) happen in a single
  transaction: create Sale → create SaleItems → deduct Inventory → create
  Payment → record CashMovement → record AuditLog. Any failure rolls back
  the entire transaction.
- Use WAL mode, foreign key constraints, and parameterized queries throughout.
- Run periodic integrity checks, especially before and after backup/restore.
# Phase 7 local compliance additions (schema version 8)

`Sales.BirInvoiceNumber` is nullable and unique. Existing rows remain null.
The first sale after a locally verified BIR-ready entitlement creates the
single `BirComplianceState` row with `ActivatedAt`, then allocates the next
integer invoice number and increases `GrandTotalCents` in the same checkout
transaction. `HighestInvoiceNumber`, `GrandTotalCents`, and `HighestZNumber`
cannot decrease through normal database updates. Invoice display currently
uses the plain integer; no zero-padding policy is specified.

`ZReadings` stores an immutable snapshot on BIR-ready cash-session close:
unique sequence number and session ID, generation time and user, first and
last session invoice, gross BIR sales, recorded reversal amount, and the
accumulated grand total. It also stores expected and actual closing cash so
an older restored backup can reconstruct the session close consistently.
An empty BIR session has null invoice endpoints.
Database triggers reject update and delete. The session and user identifiers
are retained as text so a Z snapshot can be restored even if its related
cash session or user is absent from an older backup.

The grand total is the sum of committed BIR-ready sale amounts in integer
cents. A later void or refund has its own append-only reversal record and
does not reduce this issued-sales total. Z snapshots report reversal amounts
separately. Failed checkouts do not advance invoice or grand-total state.
BIR-ready checkout requires an open cash session so every numbered sale can
be included in a retained Z snapshot when that session closes.
Before committing the SQLite transaction, BIR checkout durably reserves the
invoice number, sale ID, sale amount, and resulting integer-cent grand total
in the installation-local compliance journal. Z close similarly reserves its
number and full snapshot. A clean rollback records an abort and permits reuse;
a crash with an unmatched pending reservation blocks new BIR issuance until
the outcome can be established. This favors no reuse over gap-free numbering.
Restoring an older backup may leave missing sale rows for invoices issued
after that backup; finalized journal state raises the counters and grand total
and restores retained Z snapshots rather than reusing those numbers.

## Phase 8 foundation (schema version 9)

`BusinessFeatureSettings` stores one local enabled flag per stable feature ID.
Absent rows mean disabled. `ProductBusinessConfigurations` stores configuration
JSON by product and feature. Disabling a feature does not remove these rows.
Both tables are included in the same SQLite backup and restore path.

## Phase 8 transactions (schema version 10)

Commercial quantities use **integer thousandths**: 1000 = 1 unit, 500 =
0.5 unit, 125 = 0.125 unit. `Inventory.QuantityMilli`,
`InventoryMovements.QuantityDeltaMilli`, and `SaleItems.QuantityMilli` are
authoritative. The old integer columns remain for older code and contain the
whole-number part; they must never be used for fractional calculations. The
forward migration multiplies existing whole quantities by 1000 without
changing their meaning. Prices, extra charges, and sale totals remain integer
cents. Line totals round half up once per line.

`SaleItems` also captures sale unit, mode, optional batch ID and number, and
optional per-unit extra charge. Receipts, reprints, and sales history read
these snapshots, not the current Product configuration. One sale transaction
writes the sale, all items, stock and movement rows, payment, cash movement,
audit, and BIR state together.

`ProductLots` holds multiple retained batches per product: batch number,
optional expiry date, quantity in thousandths, and receipt time. For a
batch-tracked product, the sum of lot quantities must equal Inventory's
scaled quantity; checkout checks this invariant. A single unexpired stocked
lot is selected automatically. With multiple eligible lots, checkout requires
an explicit choice. Expired lots are retained but cannot be sold. Converting
existing stock to batch tracking assigns it to an entered batch. A schema-9
batch-enabled product with stock migrates into a `Legacy unassigned` lot.

`TankEmptyMovements` is an append-only count ledger for returned empty tanks.
An exchange consumes one full unit from Inventory and records one returned
empty; a no-return sale consumes one full unit and adds the configured deposit
amount to the sale. A void/restocked refund reverses the corresponding empty
movement. This is count tracking, not per-tank asset identity.

For refill products, Inventory counts refill units. The container option adds
the configured per-unit container charge. Individual empty containers are not
stock-tracked. `MadeOrders` links a paid sale item to the retained status flow
`ordered → preparing → ready → completed`; these products do not deduct
finished-goods inventory at sale time. Voids/refunds mark an order cancelled.
# Phase 8.5 schema 11 additions

Schema 11 adds `customers`, `suppliers`, `petty_cash_entries`, and
`price_history` through a forward migration from schema 10. Contacts are
deactivated, never hard-deleted. Petty cash records reference the open cash
session and write a matching negative `cash_movements` row in one transaction.
Price changes append old and new price/cost snapshots; prior sale item prices
remain unchanged. SQLite backup/restore includes these tables.

Schema 12 adds `sales.cash_session_id`, backfilled from historic cash
movements. Schema 13 adds `sales.customer_id` and `customer_credit_entries`.
Signed ledger amounts represent `credit_sale` (positive), `payment` (negative),
and `sale_reversal` (negative). The ledger is the balance source. Sale payments
record cash and credit portions separately; only cash enters the drawer.

Schema 14 adds `stock_receivings` and `stock_receiving_items`. A finalized
receiving stores supplier, actor, reference, each fixed-point quantity and
unit-cost snapshot. The same transaction increases Inventory, updates batch
lots where enabled, writes InventoryMovements, and appends an audit event.
Schema 15 adds a nullable payment method snapshot to customer credit entries
so a recorded cash or confirmed GCash debt payment remains explainable.
Schema 16 adds receipt address, contact, optional header, and optional footer
to the existing Settings row. Existing BIR invoice and total fields remain
generated from persisted sale data.

Schema 17 adds `customer_refund_obligations` and append-only
`customer_refund_settlements`. A reversal of a credit sale offsets the pooled
receivable by the smaller of the sale's credit amount and the current pooled
balance. Any excess becomes a separate refund obligation, so utang never goes
negative. Mixed-sale cash is returned in full before reversal and writes a
negative cash movement in the current open session. A later cash settlement
also writes a negative movement; confirmed GCash does not change drawer cash.
The reversal, ledger change, obligation, cash movement, and audit are atomic.
Schema 17 also adds `products.serial_tracking`, `serial_units`, and
append-only `serial_sale_links`. Supplier receiving inserts one unique serial
per whole unit; schema 21 also permits exact serial entry for opening stock.
Checkout requires
selected available serial IDs and atomically marks them sold with their sale
item. The link table retains historical sale identity after a restocked void.
Schema 17 also adds `rma_cases` and append-only `rma_events` for customer
sale-item and supplier receiving-item origins. RMA cases retain the intake
quantity in thousandths. Supplier intake quarantines that quantity out of
sellable inventory; restock disposition reverses the quarantine. `quotations` and
`quotation_items` hold price and unit snapshots. Quote creation writes no
sale, payment, inventory movement, or BIR invoice. Conversion validates open
status and stock in the normal sale transaction and links the Sale once.
Schema 17 adds `layaways`, `layaway_items`, `layaway_serials`, and
`layaway_payments`. Active item quantities reserve sellable stock without
changing physical Inventory. Cash deposits and later payments write separate
cash movements referencing their payment rows; they issue no Sale invoice.
Completion consumes physical stock once through the normal sale transaction,
recognizes the full sale total, and records previously paid funds separately
from final cash. Cancellation releases reservations and creates a customer
refund obligation for paid deposits, with no automatic payout.

# Schema 18 RMA note

`rma_cases.replacement_serial_unit_id` retains the issued same-product serial
for a customer replacement. The original `serial_unit_id` remains attached to
the returned unit. The schema-17 to 18 migration adds this nullable column
without resetting existing RMA records.

# Schema 20 inventory acquisition layers

`products.pricing_policy` is `current` by default or `layer`. Product
`cost_cents` is the current purchase cost reference, not historical COGS.
`stock_receiving_items.unit_selling_price_cents` is nullable; its cost and
optional price are snapshots when the delivery is finalized.

`inventory_layers` has primary key `id`, Product FK, unique nullable
ReceivingItem FK, source (`receiving`, `opening`, or `legacy_opening`),
quantity received and remaining in integer thousandths, unit cost in cents,
nullable unit selling price in cents, optional batch and expiry, and received
time. Supplier is obtained through ReceivingItem → Receiving → Supplier.
Depleted layers remain for audit. `serial_units.inventory_layer_id` points
to the exact stock layer; `serial_sale_links` retains historical sale links.
Since schema version 21, `serial_units.receiving_item_id` is nullable so
opening serials link directly to an opening layer without a fabricated
supplier delivery. Existing receiving links remain intact. Opening layers
snapshot Product current purchase cost and, for layer pricing, its current
selling price. FIFO includes opening layers; selected serials use their exact
layer.

`sale_item_inventory_allocations` has primary key `id`, SaleItem and
InventoryLayer FKs, optional SerialUnit FK, quantity in thousandths, immutable
unit cost and selling price snapshots in cents, and creation time. A current
price SaleItem can have several cost allocations. Layer price sales split
customer-facing SaleItems by consumed layer, all under one Sale/invoice.

The 19→20 migration does not alter Inventory balances or historical sales.
It creates receipt-linked layers for surviving quantities, assigning current
stock to newest receipt lines first. Batch receipts reconcile to each
current batch lot, and serialized receipts reconcile to available/reserved
serial identities. Any remaining balance becomes a
`legacy_opening` layer using Product's cost snapshot and no supplier. Because
past sale provenance was never recorded, historical sales are not retroactively
allocated. Receipt allocation during migration is a conservative
reconstruction, not proof of which old units were sold. Indexes support FIFO
lookup and SaleItem allocation lookup.
SQLite guards reject edits/deletion of receiving source fields, inventory
layer source fields, and sale allocation snapshots. Layer remaining quantity
is the mutable stock balance and changes only in inventory transactions.

# Schema 19 RMA resolution

`sale_item_refunds` links one RMA, original Sale and SaleItem, refunded
thousandth quantity, original-line refund amount, pooled cash/credit allocation,
receivable reduction, obligation, cash payout, and the open cash session used
for Z-reading. Each RMA is unique. Original Sale and SaleItem rows stay intact.
`customer_refund_obligations.rma_case_id` links deferred item refunds without
reusing the unique full-sale reversal reference. `inbound_rma_replacements`
links one inbound RMA to the replacement receiving header, item, quantity,
and new serial. Batch and expiry live on the linked receiving item. Schema 18
upgrades forward; existing records are preserved.

# Schema 22 RMA lifecycle

Schema 22 adds append-only `rma_lifecycle_events` for new customer and linked
supplier claims. Each row records a typed action, actor, timestamp, bounded
quantity, serial evidence, inspection finding, outcome, disposition, financial
amount, recipient, and optional related case. Existing `rma_cases` and
`rma_events` are preserved. No lifecycle facts are backfilled for legacy rows.
The migration creates the table and case/action index without resetting data.

# Schema 23 serialized warranty snapshots

Schema 23 adds append-only `serial_warranty_snapshots`. Each row identifies the
SerialUnit, source RMA and lifecycle event, treatment, source, optional start
and end dates, notes, and creation time. Customer handoff writes a new fact;
supplier replacement fulfillment can write a separate supplier warranty fact.
Original Sale and SaleItem history is unchanged. Missing historical warranty
facts remain Legacy / unknown. The forward migration creates this table and a
serial/creation index without deleting or backfilling existing data.

# Schema 24 operational receipt reference

`sales.receipt_number` is a nullable, unique operational reference. Every new
completed sale receives a `POS-000001` style value inside the sale transaction.
The next value is derived from committed `POS-` references, so rollback does
not reserve a number and a restored database continues after its highest
existing reference. A unique index prevents duplicates and a trigger prevents
changing an assigned reference. Preexisting sales remain null and display
`Legacy sale`; no old reference is represented as having been printed.
`receipt_number` is separate from `bir_invoice_number` and does not participate
in BIR numbering, grand total, Z-reading, or FIFO. SQLite backups include the
column and its values.

## Customer loyalty (schema version 34)

Schema 34 adds `loyalty_settings`, `loyalty_ledger`, `sale_loyalty`, and
`customer_groups`. The ledger is append-only and indexed by customer ID;
`UNIQUE(kind, source_id)` prevents a sale or return from posting the same
movement twice. `sale_loyalty` stores the original earning and redemption
rules alongside the sale. Existing customers implicitly belong to Retail
until an Owner selects another primary group. See
[customer_loyalty.md](customer_loyalty.md) for calculation policies.
