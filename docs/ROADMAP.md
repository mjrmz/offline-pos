# Roadmap — Master Build Plan (Start to Finish)

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
- **Exit criteria**: deliberately kill power mid-sale, corrupt the DB,
  disconnect hardware — app recovers or fails gracefully every time.
  This phase gates everything after it — don't proceed until it's solid.

## Phase 6 — Licensing system
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
- Sequential, non-resettable invoice numbering
- Non-resettable accumulating grand total
- Retained Z-reading
- Feature-flagged via license `edition`/`features` — one codebase, not a fork
- In-place upgrade path: Non-BIR → BIR-ready, same install, same data,
  re-activation unlocks it
- **Exit criteria**: upgrade a live Non-BIR install to BIR-ready with zero
  data loss and correct numbering going forward

## Phase 8 — Business-type feature toggles
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
