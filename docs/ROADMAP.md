# Roadmap — Master Build Plan (Start to Finish)

For local final-product checks, see the [quick testing guide](QUICK_TEST_GUIDE.md).

This is the complete, locked build order — every product decision made so far
folded into one phased plan. Each phase should be genuinely done, tested, and
stable before the next starts. Exit criteria are the bar for "actually done,"
not "works on my machine."

**Feature scope is locked as of this version.** The business toggles,
reliability requirements, licensing model, and everything in
docs/BUSINESS_TYPES.md and docs/DATABASE_SCHEMA.md are the full v1 feature
set. The next real step is Phase 1 — not further feature planning.

---

## Phase 0 — Positioning (context, not a build step)

- Offline-first, cross-platform POS for Philippine SMBs
- Platforms: Android, iOS, Windows, macOS, Linux — one Flutter codebase
- Pricing: Non-BIR ₱25,000 / BIR-ready ₱35,000 — matched to competitor
  pricing intentionally; the product has to be genuinely better, not cheaper
- Value pitch: fully offline, cross-platform from one purchase, real
  crash/data recovery, dual-screen support — things most competitors at this
  price point don't actually have solid

## Phase 1 — Foundation
- Flutter project inside `modern-offline-pos`, platform targets enabled
  (start Android + Windows, add iOS/macOS/Linux in Phase 10)
- `core/`, `data/`, `licensing/`, `hardware/`, `features/`, `shared/`,
  `backup/` structure (already scaffolded in this repo)
- `drift` database configured, logging, app configuration
- **Exit criteria**: empty app builds and runs on Android and Windows

## Phase 2 — Core POS
- Products, Categories, Barcode lookup
- Cart, Checkout, Payments (cash first, other methods after)
- Inventory deduction on sale, InventoryMovements ledger
- **Exit criteria**: can ring up a real sale end-to-end, stock updates correctly

## Phase 3 — Business functions
- Sales history, Void, Refund (never hard-delete — see docs/DATABASE_SCHEMA.md)
- Cashier PIN login + Admin password login, roles (Cashier/Manager/Owner)
- Offline password recovery path (security questions or license-tied
  recovery code)
- Core reports: daily sales, gross/net, cash breakdown, low stock
- **Exit criteria**: a full shift can be run — login, sell, void, logout —
  with correct records

## Phase 4 — Hardware integration
- Barcode scanner (USB/Bluetooth keyboard-emulation + camera fallback on mobile)
- 58mm/80mm thermal printer (ESC/POS) — sale commits before printing,
  reprint always available
- Cash drawer trigger via printer connection
- **Software status**: implementation is complete for the Android and Windows
  printer transport matrix documented in docs/HARDWARE.md. Physical peripheral
  testing is still pending; Phase 4 is not complete.
- **Exit criteria**: tested against real hardware (see docs/HARDWARE.md and
  docs/EQUIPMENT_SOURCING.md), not just emulators

## Phase 5 — Reliability (the non-negotiable core of the value pitch)
- Every multi-step write wrapped in one transaction, rollback on failure
- Automatic backup (daily/weekly, multiple generations) with SQLite
  integrity verification
- Recovery mode launcher — database/license/backup health check,
  repair/restore options
- Audit logs — every login, void, refund, adjustment
- Cash session open/close with expected-vs-actual variance
- **Status**: Complete following software verification and disposable-device
  destructive reliability verification. Phase 4 peripheral testing remains
  pending separately.
- **Exit criteria**: deliberately kill power mid-sale, corrupt the DB,
  disconnect hardware — app recovers or fails gracefully every time.
  This phase gates everything after it — don't proceed until it's solid.

## Phase 6 — Licensing system
- **Status**: complete; manually verified offline before Phase 7 work began.
- License API (thin REST service) + PostgreSQL (Customers, Licenses,
  Devices, Activations, Revocations)
- Ed25519 signed licenses, device ID binding, local signature verification
- Activation flow: device ID + key → signed license → fully offline from
  then on
- Cloud outage never locks out an already-activated device
- Device transfer/reactivation flow, with per-tier device allowances
- Admin dashboard (React/Next.js) — manage customers, licenses, devices,
  activations
- **Exit criteria**: activate, disconnect internet permanently, app runs
  fully; license server can go down without affecting active customers

## Phase 7 — BIR-ready tier
- **Status**: Complete. The live Non-BIR to BIR-ready upgrade met the exit criterion.
- **Automated verification**: Complete, including crash/recovery and restore
  monotonicity tests.
- **Manual live upgrade verification**: Complete. The existing installation
  retained products, inventory, users, sales, cash sessions, and other local
  data. Historical Non-BIR sales stayed pre-BIR without invoice numbers;
  normal POS functions continued to work. New BIR sales received sequential
  invoice numbers, receipts and reprints used persisted numbers, the
  accumulating grand total followed the Phase 7 policy, and Z-readings were
  generated and retained.
- **Manual offline BIR verification**: Complete. BIR sales continued with the
  License API and dashboard stopped and the device offline. Restart retained
  BIR entitlement and invoice numbering.
- **Manual restore monotonicity verification**: Complete. Restoring an older
  backup did not reuse issued invoice numbers or improperly roll back the
  grand total; protected Z-reading and compliance state remained safe.
- Sequential, non-resettable invoice numbering
- Non-resettable accumulating grand total
- Retained Z-reading
- Feature-flagged via license `edition`/`features` — one codebase, not a fork
- In-place upgrade path: Non-BIR → BIR-ready, same install, same data,
  re-activation unlocks it
- **Exit criteria**: upgrade a live Non-BIR install to BIR-ready with zero
  data loss and correct numbering going forward

## Phase 8 — Business-type feature toggles
- **Current implementation status**: six core workflows implemented in schema
  version 10. All 97 automated tests and Windows and Android release builds
  pass. The Owner's manual exit check remains pending.
- Setup wizard asks "what do you sell?" (multi-select), not a single
  business-type choice — real shops (e.g. a sari-sari store selling rice,
  water refills, and LPG alongside general retail) combine categories
- Independent toggles, any combination on: weight-based pricing,
  container/refill pricing, tank deposit/exchange tracking, expiry/batch
  tracking, unit-of-measure variety, made-to-order tracking
- Free configuration (not license-gated), per-product not per-store —
  a single catalog can mix plain retail items with weight-priced or
  tank-tracked items
- **Exit criteria**: enabling/disabling any toggle in Settings correctly
  shows/hides the right per-product fields without breaking existing data

## Phase 9 — Dual-screen customer display
- Second-window support on Windows (multi-window desktop) for terminals
  with a rear customer-facing screen
- Read-only view: cart items, running total, "please pay ₱XXX," idle/promo
  screen
- Graceful no-op when no second display is detected
- **Exit criteria**: tested on an actual dual-screen terminal, syncs live
  with the main till

## Phase 10 — Full cross-platform rollout
- Add iOS, macOS, Linux builds on top of the now-stable Android + Windows core
- Per-platform hardware/peripheral testing (each platform handles
  printers/scanners differently)
- Responsive layout tuned per form factor: phone, tablet, laptop, desktop
- **Exit criteria**: same core product, verified working on all five platforms

## Phase 11 — Polish
- Full UI pass: error states, empty states, onboarding wizard, settings screen
- Installers/packaging per platform (`.exe`, `.apk`, etc.)
- **Exit criteria**: a non-technical shop owner can install and set up
  alone, following on-screen guidance

## Phase 12 — Testing (deliberately break it)
- Power loss mid-sale
- Database corruption
- Printer/scanner disconnected mid-use
- Full disk
- Invalid/expired license
- Device mismatch after copy
- Duplicate payment / double-click checkout
- Low-spec hardware (Celeron, 2GB RAM — common in real PH POS terminals,
  not an edge case — see docs/EQUIPMENT_SOURCING.md)

## Phase 13 — Launch
- Non-BIR tier first, Android tablet first customer, Windows desktop close
  behind
- Rollout: you → 5 friendly businesses → 20 → 100 → 1,000 → 10,000
- Each stage surfaces real problems invisible in development — don't skip
  stages

---

## Deferred — real future modules, sequenced after v1 ships and sells

- **Restaurant/carinderia module** — tables, kitchen tickets, modifiers, on
  the same core
- **Offline Services/Booking module** — appointment scheduling for salons,
  clinics, repair shops that specifically don't want cloud software (a
  segment the online Vertex-BOS Booking module structurally can't reach) —
  genuine differentiator, built once the core product is proven
- **Fuel-pump gas stations** — explicitly out of scope permanently;
  different hardware integration problem (pump controller protocols), not
  a POS feature
# Inventory architecture cleanup after Phase 8.5

Schema 20 adds one Inventory destination with Overview, Products, Receiving,
and Movements; supplier-linked acquisition layers; FIFO allocation for
ordinary stock; exact serial allocation; and current versus receipt-layer
selling price policies. Sale allocations retain quantity, cost, and price
snapshots. Migration preserves existing stock as reconstructed receipt layers
and explicit opening balances. Packaged desktop/mobile verification remains
pending. Phase 9 is unstarted.

Schema 21 makes the SerialUnit receiving-item reference nullable for
serialized opening balances. Opening inventory creates supplier-free layers,
requires exact serial entry for serialized units, preserves batch rows, and
uses the Product cost and applicable selling price as opening snapshots.
Supplier Receiving remains a separate delivery workflow. Phase 9 remains
unstarted.

# Phase 8.5 software implementation

Schema 17 supports customer purchases, an append-only utang ledger, full and
partial credit checkout, customer payments, and Z-reading sales based on sale
rows. Supplier directories, petty cash, price history, and expiry UX are also
implemented. The reported Refresh License Cancel assertion awaits production
verification. Mixed-credit cash refunds and paid-credit reversal now have an
explicit accounting path. Serial receiving and sale linkage are implemented.
RMA intake and event history and quotation conversion are implemented.
The Vertex-BOS aligned RMA rework is in progress. Schema 22 adds append-only
lifecycle facts for new claims: approval, receipt, inspection, custody,
intent, execution, exact replacement reservation, handoff, and linked supplier
decision/fulfillment. Existing cases remain single-line. Multi-item claims,
warranty policy configuration, supplier SLA, remaining outcome paths, and
manual review are still required. Schema 23 adds append-only serialized warranty
snapshots without rewriting original sale history.
Customer refund completion now follows refund execution independently of linked
supplier recovery. Exact store replacement handoff can also complete the
customer case while supplier recovery remains open. The supplier warranty path
holds an exact supplier replacement serial for customer handoff; direct or
already-satisfied recovery becomes store stock. The detail page shows a
separate supplier recovery action or link. Linked Supplier RMA creation now
occurs at authorization; physical sending is a later custody event. Exact
repaired-original and no-fault returns, rejected original disposition, and
warranty treatment at handoff are supported.
The RMA UI now has customer/supplier tabs, a lifecycle-derived queue, compact
summary metrics, a four-step customer request page, and a full detail page with
progress, custody, next action, and timeline. Direct supplier intake from
Receiving is available without a customer; it quarantines exact sourced stock
and records a separate lifecycle intake fact. Supplier creation has a four-step
page for linked customer claims and direct defective inventory. Receipt and
inspection now use dedicated responsive dialogs with bounded quantities,
condition choices, serial mismatch evidence, and visible validation hints.
Resolution intent uses a four-step outcome/details/disposition/review dialog.
Customer handoff and supported supplier fulfillment now have dedicated
responsive dialogs. Remaining dedicated approval, refund, and supplier decision
action sheets,
broader widget coverage,
and responsive/theme manual verification remain to finish the UI rebuild.
See [RMA.md](RMA.md) for the exact current boundary. Phase 8.5 RMA is not
complete.
RMA financial resolution now supports a claimed SaleItem quantity. Layaway stock
reservation, deposits, completion, and cancellation are implemented. Do
not start Phase 9 or claim manual verification.
Schema 18 adds a persisted replacement serial link. Same-item customer
replacement now consumes inventory in one transaction without a new sale or
invoice. Repaired-item return is executable. Schema 19 records item-level RMA
refunds and linked supplier replacement receipts. The refund uses the original
line snapshot, pooled credit ledger, refund obligations, and cash movements.
Supplier replacements reuse receiving stock and serial/batch rules. Automated
software validation is recorded in the final run report; packaged-app manual
verification remains pending with the owner.
Supplier receiving now supports multi-item ordinary, batch, and serialized
stock with cost snapshots, history, rollback, and backup.
An Owner Operations screen now lists out-of-stock and low-stock products,
expired and soon-expiring batches, outstanding utang, and pending made orders.
Owner printer settings now include store address, contact, and receipt
header/footer while preserving BIR sale details.
