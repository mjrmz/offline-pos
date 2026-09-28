# Business Type: Feature Toggles, Not a Single Preset

One product, one price. A shop's identity isn't a single category — a real
sari-sari store commonly sells general retail items *and* rice by the kilo
*and* water refills *and* LPG tank swaps, all from the same till, the same
day. Forcing a single "business type" choice would mean picking one of
these and losing the others.

## The model: independent, combinable toggles

Instead of a single business-type selector, Settings exposes independent
feature toggles — any combination can be on, all free, all changeable
later without breaking existing data:

- **Weight-based pricing** — for rice, grains, feeds/agri; price-per-kilo
  that can change daily, partial-sack/partial-kilo sales
- **Container/refill pricing** — for water refilling; flat per-container
  pricing, optimized for high transaction volume, low SKU count
- **Tank deposit/exchange tracking** — for LPG dealers; per-tank pricing
  plus tracking of empty-for-full tank swaps and deposits
- **Expiry/batch tracking** — for pharmacy items; expiry date and batch
  number fields on relevant products
- **Unit-of-measure variety** — for hardware stores; per-piece, per-meter,
  per-kilo selection instead of a fixed unit
- **Made-to-order tracking** — for bakeries; distinguishes made-to-order
  from off-the-shelf stock, simple batch/production tracking
- **Serial number tracking** — for electronics/computer shops; tracks
  individual units by serial number/IMEI rather than just SKU quantity,
  needed for per-unit warranty claims
- **RMA / warranty tracking** — for electronics/computer shops; tracks
  defective-item returns through to resolution, with two distinct origins:
  - *Customer RMA* — linked to an original sale, customer reports a
    problem within warranty, item goes shop → supplier → resolution →
    customer receives replacement/repair/refund
  - *Inbound/delivery RMA* — linked to a stock receiving record instead of
    a sale; defective on arrival from the supplier, goes straight back
    without a customer ever being involved
  - Status flow: Pending → Sent to Supplier → Resolved / Rejected, with
    supplier, reference/tracking number, and notes
  - Depends on a minimal Stock Receiving record (supplier, date, items
    received) to attach inbound RMAs to — see docs/DATABASE_SCHEMA.md
- **Utang / credit sales (running tab)** — very common in sari-sari and
  small retail; a sale can be marked "on credit" instead of paid in full,
  tracked against a customer's running balance, with partial payments
  accepted against that balance over time
- **Senior Citizen / PWD discount** — legally required in the Philippines
  (20% discount + VAT exemption on qualifying purchases); captures the
  required ID documentation and applies correct receipt/reporting
  treatment, connects to the BIR-ready tier's compliance requirements
- **General discounts / promos** — percentage or fixed-amount discount at
  checkout; Senior/PWD is a special case of this same mechanism
- **Supplier accounts payable tracking** — tracks what the shop owes each
  supplier and payment history, building on the StockReceivings record
  already used for inbound RMA
- **Sales data export (CSV/Excel)** — lets an owner or their
  accountant/bookkeeper pull sales/reports out for their own bookkeeping
  or tax filing
- **Loyalty points / repeat customer rewards** — earns points per peso
  spent on a customer's account, redeemable against future purchases;
  builds on the same Customers table used for utang tracking
- **Price change history / audit** — logs who changed a product's price
  and when, useful for shops with multiple staff who can edit inventory
- **Digital weighing scale integration** — feeds live weight directly into
  checkout for weight-based products (rice, grains, feeds), instead of
  manual entry; manual entry remains available as a fallback — see
  docs/HARDWARE.md
- **Bulk product import (CSV)** — import an existing product catalog from
  a spreadsheet during setup, useful for hardware/electronics shops with
  large catalogs — see docs/ARCHITECTURE.md
- **Quotations** — print or save a price quote without committing a sale
  or deducting inventory, convertible into a real sale later; common in
  hardware/electronics — see docs/ARCHITECTURE.md
- **Layaway / reserved stock** — customer puts a deposit down, stock is
  reserved (not sellable to anyone else), balance paid over time; common
  for appliances/electronics
- **Structured void/refund reason codes** — requires a reason (wrong item,
  changed mind, damaged, price error) on every void/refund, so patterns
  are actually reportable, not just recorded as raw counts
- **Petty cash / expense tracking** — logs day-to-day cash outflows
  against a cash session, so the drawer's expected-vs-actual accounts for
  more than just sales
- **Receipt customization** — store logo and custom header/footer text on
  printed receipts

## How it works in practice

- Each toggle affects which **fields appear on a per-product basis**, not
  the whole store — a sari-sari store can have some products as plain
  retail items, others with weight-based pricing, others with tank
  tracking, all in the same catalog.
- Toggles are set during first-run setup (asked as "what do you sell?"
  with multi-select, not "what type of business are you?") and can be
  changed anytime in Settings without affecting existing data.
- All toggles share the same `core/` and `data/` layer — this is
  configuration, not a schema fork.

## Agent services (cash-in/cash-out) toggle

**Agent services / cash-in-cash-out income tracking** — a real, common
secondary income stream for sari-sari and small stores: e-wallet
cash-in/cash-out (GCash, PayMaya), bills payment, and mobile load
selling, each earning the store owner a small commission per transaction.

- The actual money movement happens through the owner's own agent app on
  their phone (GCash/PayMaya agent tools) — modern-offline-pos does not
  process these transactions or integrate with any e-wallet API
- What's tracked is a simple ledger: transaction type (cash-in / cash-out
  / bills payment / load), amount, commission earned, optional customer
  reference, timestamp
- A daily/monthly commission income report — most agents don't track
  this well today and just estimate it, so this is a genuine, visible
  value-add
- Feeds into the existing cash session variance calculation the same way
  Petty Cash/Expenses does, since this cash flow affects what should be
  in the drawer
- See docs/DATABASE_SCHEMA.md for the AgentTransactions table

## Explicitly out of scope for this toggle model

- **Restaurant/carinderia** — needs a genuinely different transaction
  model (tables, open tabs, kitchen tickets, modifiers), not just
  different fields on a product. Deferred as its own module — see
  docs/ROADMAP.md.
- **Fuel-pump gas stations** — needs physical pump-controller protocol
  integration, a hardware problem, not a configuration difference.
  Permanently out of scope for this product.
- **Salon, laundry, repair shop, clinic (appointment/service-based)** —
  not item-based at all; needs calendar/resource scheduling, not a
  product catalog. Deferred as a future offline Booking module — see
  docs/ROADMAP.md.
