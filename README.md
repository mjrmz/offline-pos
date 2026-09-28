# modern-offline-pos

Offline-first, cross-platform Point-of-Sale system for Philippine SMBs — runs on
Android, iOS, Windows, macOS, and Linux (phone, tablet, laptop, desktop) from a
single Flutter codebase, with a local SQLite database as the source of truth and
a one-time online license activation.

## Why this exists

Most small retail shops in the Philippines can't rely on always-on internet.
modern-offline-pos is built so the till, inventory, sales, and reports all keep
working with zero connectivity after a one-time activation — the cloud is only
ever contacted for licensing, never for day-to-day operation. Priced to match
competitors while being genuinely more capable: real cross-platform coverage,
real crash/data recovery, and real dual-screen support.

## Product at a glance

- **Two tiers, one codebase**: Non-BIR (₱25,000) and BIR-ready (₱35,000),
  with an in-place upgrade path between them
- **Business features are free, combinable toggles**, not a single
  business-type choice — a shop can mix general retail, weight-based
  pricing (rice/grains), container pricing (water refilling), tank
  deposit/exchange (LPG), expiry/batch tracking (pharmacy), UOM variety
  (hardware), and made-to-order tracking (bakery) all in one catalog,
  matching how real shops (like sari-sari stores selling rice, water,
  and LPG together) actually operate
- **Dual-screen customer display** supported as a real feature, not an
  afterthought
- **Restaurant and offline appointment-booking (Services)** modules are
  planned as later additions, not v1

## Repo layout

```
modern-offline-pos/
├── lib/                # Flutter application (see docs/FOLDER_STRUCTURE.md)
├── test/                # Unit tests mirroring lib/core and lib/data
├── android/ ios/ windows/ macos/ linux/   # Flutter platform shells
├── cloud/
│   ├── license_api/     # Licensing backend (see docs/LICENSING.md)
│   └── admin_dashboard/ # Web dashboard for managing customers/licenses/devices
├── docs/                 # Full documentation set (start here)
└── pubspec.yaml
```

## Start here

Read the docs in this order:

1. [`docs/ROADMAP.md`](docs/ROADMAP.md) — the master build plan, phase by phase, start to finish
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — full system design
3. [`docs/FOLDER_STRUCTURE.md`](docs/FOLDER_STRUCTURE.md) — what goes where and why
4. [`docs/DATABASE_SCHEMA.md`](docs/DATABASE_SCHEMA.md) — local SQLite schema
5. [`docs/LICENSING.md`](docs/LICENSING.md) — activation and offline license verification
6. [`docs/HARDWARE.md`](docs/HARDWARE.md) — printer, barcode scanner, cash drawer integration
7. [`docs/AUTH_AND_ROLES.md`](docs/AUTH_AND_ROLES.md) — cashier/admin offline login and permissions
8. [`docs/BUSINESS_TYPES.md`](docs/BUSINESS_TYPES.md) — business-type presets and what's explicitly out of scope
9. [`docs/CUSTOMER_DISPLAY.md`](docs/CUSTOMER_DISPLAY.md) — dual-screen customer-facing display
10. [`docs/EQUIPMENT_SOURCING.md`](docs/EQUIPMENT_SOURCING.md) — real PH POS hardware suppliers and what to check for

## Core principles

- **The local database is the source of truth.** Not the UI, not the printer, not the cloud.
- **Nothing about daily operation requires internet.** Only activation does.
- **`core/` and `data/` never import Flutter UI code.** Business logic must be
  testable and reusable without a screen.
- **Each device is a standalone install.** No cross-device sync unless
  explicitly added later as a separate feature.
- **Reliability ships before anything visible.** Phase 5 (transactions, backup,
  recovery mode, audit logs) gates every later phase — this is the actual
  substance behind charging a premium price.
