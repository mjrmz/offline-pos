# Local Database Schema (SQLite via drift)

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
