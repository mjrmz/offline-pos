# Folder Structure

```
masd_pos/
├── lib/
│   ├── main.dart
│   │
│   ├── core/                      # Pure business logic — NO Flutter/UI imports
│   │   ├── models/                # Sale, Product, InventoryMovement, User, etc.
│   │   ├── services/
│   │   │   ├── sale_service.dart          # sale creation, transaction orchestration
│   │   │   ├── inventory_service.dart     # stock deduction, movement history
│   │   │   ├── cash_session_service.dart  # open/close till, variance calc
│   │   │   └── license_service.dart       # local signature verification
│   │   └── validators/
│   │
│   ├── data/                      # SQLite / drift layer
│   │   ├── database.dart          # drift database definition
│   │   ├── tables/                # Products, Sales, SaleItems, Inventory, Users, AuditLogs...
│   │   ├── daos/                  # Data access objects per table group
│   │   └── migrations/            # versioned schema migrations
│   │
│   ├── licensing/
│   │   ├── activation_client.dart # HTTPS call to License API (activation only)
│   │   ├── signature_verifier.dart # Ed25519 local verification
│   │   └── device_id.dart          # per-platform device fingerprint
│   │
│   ├── hardware/                  # platform-specific, behind an interface
│   │   ├── printer/               # ESC/POS abstraction + platform implementations
│   │   ├── barcode/               # USB keyboard-emulation + camera scan
│   │   ├── scale/                 # digital weighing scale (USB/Bluetooth/serial)
│   │   └── cash_drawer/           # triggered via printer connection
│   │
│   ├── features/                  # UI, organized by screen/feature
│   │   ├── auth/                  # cashier PIN login, admin password login
│   │   ├── dashboard/
│   │   ├── pos_checkout/
│   │   ├── inventory/
│   │   ├── sales_history/
│   │   ├── reports/
│   │   ├── cash_session/
│   │   ├── settings/
│   │   └── recovery/              # database/license/backup health screen
│   │
│   ├── shared/
│   │   ├── widgets/                # buttons, cards, adaptive layout helpers
│   │   ├── theme/
│   │   └── utils/
│   │
│   └── backup/
│       ├── backup_service.dart     # scheduled local backup + integrity check
│       └── restore_service.dart
│
├── test/                          # mirrors core/ and data/ — unit tests, no UI needed
│   ├── core/
│   └── data/
│
├── android/ ios/ windows/ macos/ linux/   # Flutter platform shells
│
├── cloud/
│   ├── license_api/                # licensing backend service
│   └── admin_dashboard/            # web dashboard for managing customers/licenses
│
├── docs/                           # this documentation set
│
└── pubspec.yaml
```

## Placement rules

Phase 6 adds `lib/licensing/license_store.dart`, `lib/features/activation/`,
PostgreSQL migrations and admin routes under `cloud/license_api/`, and a
separate React/Vite deployable under `cloud/admin_dashboard/`.

| If the code... | It goes in... |
|---|---|
| Computes a sale total, deducts stock, validates a license signature | `core/services/` |
| Defines a table, writes a query, runs a migration | `data/` |
| Talks to the License API or verifies a signature | `licensing/` |
| Talks to a printer, scanner, or cash drawer | `hardware/` |
| Is a screen, button, or anything the user taps | `features/<feature>/` |
| Is reused across multiple features (a themed button, a date formatter) | `shared/` |
| Handles scheduled backup or restore | `backup/` |

## Why this shape

- `core/` and `data/` are shared identically across every platform build —
  write the logic once, test it once, ship it five times (Android, iOS,
  Windows, macOS, Linux).
- `hardware/` is the only layer that meaningfully diverges per platform.
  Isolating it here means a printer bug on Windows can't silently affect the
  Android build, and vice versa.
- `features/` is organized by what the user does, not by widget type — this
  keeps related UI, state, and screen logic together instead of scattered
  across generic `screens/`, `widgets/`, `providers/` folders.
