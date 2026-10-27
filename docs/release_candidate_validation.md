# A–R hardening / release candidate validation

Date: 2026-10-26 (Asia/Manila). This section records Pass 1; the Pass 2 section below supersedes its backup findings.

## Baseline

- Branch: `main`; commit: `455539559e605a642c59626b793920488411eeb7`.
- Initial working tree was clean. No commit or push was made.
- Database schema declared by `AppDatabase`: 55.
- Flutter 3.47.5 stable; Dart 3.13.4.
- 149 test files. One declared skip requires `PHASE_L_HISTORICAL_BACKUP`.
- Windows CMake desktop target is present. Android release currently uses debug signing and the placeholder `com.example.modern_offline_pos` application ID.

## Automated validation

| Gate | Result |
| --- | --- |
| Initial `flutter analyze` | Passed, no issues |
| Initial `git diff --check` | Passed |
| Initial full `flutter test --reporter expanded` | 723 passed, 66 failed, 1 skipped; 16m49s |
| Isolated `inventory_overview_test.dart` | 5 passed, 3 failed after the narrow Stock Counts overflow fix; no remaining overflow in that file |
| Final full `flutter test --reporter expanded` after layout fix | 727 passed, 62 failed, 1 skipped; 10m26s |
| Final `flutter analyze` | Passed, no issues |
| Final `git diff --check` | Passed |
| Windows release build | Not run: full-suite green prerequisite not met |
| Android APK release build | Not run: full-suite green prerequisite not met |

The initial and final complete test logs are `.rc_flutter_test.log` and `.rc_flutter_test_final.log`; the isolated inventory rerun is `.rc_inventory_final.log`. These are local untracked diagnostic files.

## Failure triage

- **HIGH, validation blocker:** 66 failures in the first complete run and 62 in the final run. They include old migration fixtures with incomplete table sets, current databases relabeled with old `user_version` values, obsolete expected schema numbers (often 46), UI navigation/text expectations, and timeouts. These must be isolated and corrected before a release candidate claim. The failures were retained; no assertion or coverage was removed.
- **MEDIUM, application UI defect fixed:** Stock Counts header and list overflowed at narrow width. The header now stacks actions and the count grid scrolls horizontally when needed. The isolated inventory test no longer reports a rendering overflow.
- **Unclassified pending isolation:** restore durability, BIR journal, POS discount, and some UI failures occurred in the full parallel run. Timeout alone does not establish an application defect. The suite log preserves the exact stack traces.
- The previously known `inventory_overview_test.dart` still has three failing assertions after the overflow fix: the Expiry Monitor finder, `Inventory movements` text, and `DEL-42` reference. These require checking current UI behavior against intended navigation and data presentation.

## Database, backup, restore, and BIR

The schema 40–55 migration chain was inspected. Recent steps add order, reservation, delivery, cycle count, handover, barcode alias, and Kit structures. Schema 54→55 has an automated test, but the complete run contains migration fixture failures. A genuine historical schema 49/50 backup was not found under the project directory. The historical backup test skipped because `PHASE_L_HISTORICAL_BACKUP` was unset. Therefore metadata, SQLite integrity, foreign keys, business row counts, and a genuine copied backup restore to 55 remain **unverified**.

Backup/restore and BIR regression tests ran as part of the full suite. Several restore and durable journal tests failed or timed out under load, so protected invoice sequencing, grand total, retained Z records, recovery fallback, and restore safety cannot be signed off from this run. No genuine database was reset or restored over. No genuine backup was modified.

## Coverage and manual checks remaining

The full suite included promotion, licensing, authentication, permission, POS, inventory, purchase return, customer credit, supplier payable, sales order, delivery, handover, barcode alias, Kit, serial explorer, dashboard, audit, import, label, hardware abstraction, and theme tests. Passing tests provide partial coverage; the red suite prevents a module-wide sign-off. Non-BIR to BIR upgrade, real startup with a copied migrated database, Windows debug and release launch, Android device smoke, and 1366×768 visual review remain manual or blocked by the validation failures.

Physical printer, cash drawer, Bluetooth, and real Android device checks remain pending. Kit returns/voids and Sales Order Kits remain restricted as documented. Ordinary product creation/name/SKU events lack dedicated audit coverage. Android release signing and application ID need production configuration before distribution.

## Decision

**Pass 1: NOT READY.** The full suite was red, a genuine historical backup migration and restore had not then been proven, and release builds were not run. No new feature phase or Phase 9 work was started. BIR semantics and permission checks were not changed. No failing test was hidden or deleted. The working tree was not auto-committed.

## RC Hardening Pass 2 — Migration / Restore / BIR

Date: 2026-10-27 (Asia/Manila). Scope was limited to migration, backup, restore, and BIR integrity. The prior Stock Counts change remains untouched.

### Latest prior-suite failure inventory

The 727/62/1 run had **28 migration**, **4 data backup/restore**, and **2 BIR** failures under these non-overlapping categories. The file and test names below identify every relevant failure; messages are condensed from `.rc_flutter_test_final.log`.

| Category | File and failing test(s) | Failure message / classification |
| --- | --- | --- |
| Migration | `customer_credit_migration_test.dart`: v44 credit rows | `no such table: sales`; invalid historical fixture containing only two tables |
| Migration | `inventory_health_test.dart`: schema 36 upgrade; `inventory_layer_migration_test.dart`: both v19 backfills | `cash_shift_handovers already exists` (one also timed out); current-schema databases relabeled as old versions, invalid fixtures |
| Migration | `migration_test.dart`: v6→v7 cash movements | `cash_shift_handovers already exists`; invalid historical fixture |
| Migration | `migration_test.dart`: v5→v6 Settings | 30-second timeout; flaky timing under full-suite load; genuine legacy schema builder used |
| Migration | `phase85_migration_test.dart`: schema 29, 28, 21, 18, 17, 14, 11 | `cash_shift_handovers already exists` (schema 18 also timed out); invalid newer-schema/older-version fixtures |
| Migration | `phase85_migration_test.dart`: schema 22, 16, 10 | Expected schema 46, actual 55; stale expected version; fixtures also need historical validation |
| Migration | `phase8_foundation_test.dart`: version 8 migration; `phase8_quantity_migration_test.dart`: schema 9→10 | Windows temp-directory deletion denied while file in use; environment/cleanup issue under full-suite load |
| Migration | `promotion_repository_test.dart`: version 40; `promotion_checkout_migration_test.dart`: versions 41 and 42 | `cash_shift_handovers already exists`; current-schema-derived fixtures mislabeled as old versions |
| Migration | `purchase_return_test.dart`: schema 43; `sales_order_fulfillment_test.dart`: schema 48; `sales_order_physical_test.dart`: schema 49; `sales_order_repository_test.dart`: schema 46; `stock_reservation_test.dart`: 47→48 | Expected schema 46 or 50, actual 55; stale expectations on reconstructed fixtures that still need historical validation |
| Migration | `rbac_test.dart`: v39 upgrade; `serialized_opening_stock_test.dart`: version 20 | `cash_shift_handovers already exists`; invalid newer-schema/older-version fixtures |
| Backup | `loyalty_test.dart`: backup keeps ledger; `procurement_traceability_test.dart`: source links survive backup; `rbac_test.dart`: backup preserves custom roles | Expected schema 46, actual 55; stale backup version assertions, fixed to compare with current DB schema |
| Restore | `phase8_restore_test.dart`: restore replaces later state | 30-second timeout in full suite; passes focused serial run |
| BIR | `phase7_test.dart`: cutover and old-backup reconciliation; `phase7_durability_test.dart`: commit-before-finalize recovery | 30-second timeout in full suite; both pass focused serial run |

The invalid migration fixtures were **not** made to pass by lowering `user_version` or by weakening production migrations. They remain release-validation debt. No application migration defect has been reproduced with the genuine schema 40 and 49 backups. The 54→55 delta test passes, but its fixture is reconstructed rather than a genuine backup.

### Genuine backup and protected restore

Genuine source backups were found in `C:\Users\MJ\Documents\backups`. The schema 40 daily backup dated 2026-10-24 and schema 49 daily backup dated 2026-10-25 were each inspected read-only, copied to a temp directory, staged, restored, migrated to schema 55, reopened, and checked for SQLite integrity and foreign-key violations. Metadata filename, byte count, schema, and declared integrity agreed with each database. The tests assert source file and metadata timestamps and sizes are unchanged.

| Table | Schema 40 before/after | Schema 49 before/after |
| --- | ---: | ---: |
| Products | 13 / 13 | 13 / 13 |
| Sales | 29 / 29 | 29 / 29 |
| Sale items | 31 / 31 | 31 / 31 |
| Inventory layers | 13 / 13 | 13 / 13 |
| Customers | 6 / 6 | 6 / 6 |
| Suppliers | 3 / 3 | 3 / 3 |
| Audit logs | 371 / 371 | 375 / 375 |
| BIR compliance rows | 1 / 1 | 1 / 1 |
| Z-readings | 2 / 2 | 2 / 2 |
| Stock counts | 2 / 2 | 2 / 2 |

The historical backup test does not reproduce the original device's external compliance journal. Its successful migration proves SQLite data preservation; BIR journal reconciliation is covered by separate focused tests.

### Changes and focused checks

- **LOW production fix:** `RestoreService` now deletes the staged candidate if closing the active DB fails, leaving the active file untouched. A focused test asserts the stage and pre-restore files are absent and live data remains readable.
- The restore regression now checks that the pre-restore copy exists, passes backup verification, and contains the state that existed immediately before replacement.
- The BIR 1–4 / backup-after-2 / restore / next-invoice-5 scenario now runs through `RestoreService` with the production reconciliation callback. It verifies grand total 500 cents, retention of the Z-reading ending at invoice 4, subsequent invoice 5, and Z immutability.
- A metadata mismatch regression rejects a backup whose declared schema disagrees with SQLite.
- Stale backup assertions in loyalty, procurement traceability, and RBAC tests now compare with the database's current schema version. No assertion was removed.
- Focused serial integrity run: **55 passed, 0 failed**. Separate schema 40 historical backup and RBAC backup runs also passed. The BIR journal design reserves before SQLite commit and finalizes afterward; a committed sale with interrupted finalization is reconciled from the durable reservation. No new durability gap was reproduced in focused tests.

### Pass 2 gate

| Gate | Result |
| --- | --- |
| Full suite after pass | 734 passed, 58 failed, 0 skipped; 8m50s. Genuine schema 49 backup test included via `PHASE_L_HISTORICAL_BACKUP`. |
| Migration failures (same classification) | 28 before, 28 after; invalid fixtures and stale version expectations remain |
| Data backup/restore failures | 4 before, 0 after |
| BIR failures | 2 before, 0 after |
| Flutter analyze | Passed, no issues |
| `git diff --check` | Passed; Git emitted only CRLF normalization notices |
| Windows / Android release builds | Intentionally not run in this pass |

**Pass 2 decision: NOT READY.** The full suite still has 58 failures, including 28 migration tests built around invalid historical fixtures or stale version expectations. The remaining 30 are outside this pass or load-sensitive and need separate triage. The real schema 40 and 49 backup migrations and focused BIR/restore checks are green, but they do not make the red suite release-ready. No business DB was reset, no genuine backup was modified, no BIR semantics or permission checks were weakened, no new feature phase or Phase 9 was started, and no commit or push was made.

## RC Hardening Pass 3 — migration fixtures and regression cleanup

Starting gate: **734 passed, 58 failed, 0 skipped**. The [Pass 3 failure inventory](rc_pass3_failure_inventory.md) lists all 58 failures and their initial causes.

### Migration fixture repair

Genuine backup schemas 7, 8, 22, 29, 37, 39, 40, and 49 were inspected read-only. Test-only JSON snapshots contain DDL only, with no business rows. The historical fixture helper builds an actual older schema from those snapshots, copies compatible seeded test rows, and validates SQLite integrity and foreign keys. It does not relabel a current-schema database by lowering `user_version`. The repaired migration tests cover versions 6, 8–22, 28–29, and 36–49; focused groups passed: early migrations **28/28**, phase 8.5 **10/10**, schema 36–39 **11/11**, schema 40–49 **35/35**. Structural tests compare reconstructed checkpoints with genuine archived schemas.

One production migration defect was found: the genuine schema 22 `serial_units.receiving_item_id` column was non-null, even though current opening serials require null. The upgrade now rebuilds that historical table with nullable receiving provenance while preserving serial rows. A genuine schema 22 backup was migrated and restored on an isolated copy, and that focused test passed. The source backup was not modified.

The first full-suite checkpoint after migration repair recorded **760 passed, 50 failed**. Most new migration fixture failures were 30-second timeouts under the parallel full-suite load; the same groups passed in focused runs. The remaining regression cleanup includes POS workflow schema and below-cost fixtures, dashboard layout, current shell navigation expectations, and Inventory tab positions. Focused POS workflow tests passed **4/4** after repair.

### Final gate

| Check | Pass 3 result |
| --- | --- |
| Starting full suite | 734 passed, 58 failed, 0 skipped |
| Migration failures | 28 before; **0 after** |
| Non-migration failures | 30 before; **0 after** |
| Final full suite | **810 passed, 0 failed, 0 skipped**; serial execution, two-minute per-test timeout, genuine schema 49 backup supplied |
| Flutter analyze | Passed after unused test-import cleanup |
| `git diff --check` | Passed; Git reported only line-ending normalization notices |
| Release build gate | **READY FOR PASS 4**; builds were not run in Pass 3 |

Production defects fixed in this pass: the genuine schema 22 serial-source nullability migration and a dashboard metric tile overflow at desktop test sizes. Twenty-five existing test files were updated during Pass 3 for historical fixture setup, schema 55 expectations, current navigation/controls, serial lifecycle detail, and below-cost fixture economics. Eight schema-only snapshots and a test fixture builder support historical migration coverage. No original failing test remains red in the final serial suite; no test was deleted or skipped to conceal a failure.

The earlier parallel checkpoint had 50 failures, many from 30-second per-test timeouts and Windows temp-file locks under load. The final serial run finished without a timeout or lock failure. This result establishes a green validation command with explicit serial execution and a two-minute timeout; it does not claim the default parallel 30-second command is stable on this Windows host.

Only copies and temp files of genuine historical backups were used; the source backups were not modified. No business data was reset. BIR safeguards and Restore protections were not weakened. Invalid historical fixtures were rebuilt from archived schemas instead of forcing production migrations to accept impossible schema/version combinations. No Windows or Android release build, Android signing change, new feature work, Phase 9 work, commit, or push was performed.

## RC Hardening Pass 4 — Release Builds / Smoke

Date: 2026-10-27 (Asia/Manila). The source tree entered this pass at schema 55 with the Pass 3 serial suite green (**810 passed, 0 failed, 0 skipped**). `flutter analyze` and `git diff --check` both passed before building. No runtime source or build configuration was changed in Pass 4.

| Gate | Result |
| --- | --- |
| App version | `0.1.0`, Android versionCode `1`; package ID `com.example.modern_offline_pos` |
| Windows release build | **PASS** — `flutter build windows --release`; 299.6 seconds |
| Windows artifact | `build/windows/x64/runner/Release/modern_offline_pos.exe` with adjacent `data`, Flutter DLL, SQLite, PDF, printing, and thermal printer libraries; raw release folder, no installer |
| Windows runtime smoke | **NOT VERIFIED** — the current Windows Documents profile contains a business SQLite database, and no Windows Sandbox or other isolated user profile is available. Launching this build would open that live database and could run startup backup/migration work. No launch was attempted against it. |
| Windows offline restart/UI | **NOT TESTED** for the same isolation reason; Dashboard, POS, Inventory, Sales History, Sales Orders, Cash Session, Serial Explorer, Audit Explorer, backup UI, and BIR/Non-BIR release paths remain manual checks on a disposable profile |
| Android signing | **DEBUG** — Gradle release uses `signingConfigs.getByName("debug")`; `apksigner` confirmed `CN=Android Debug`. This blocks production Android distribution. No production keystore was generated. |
| Android APK build | **PASS** — `flutter build apk --release`; 332.3 seconds; 103,224,406 bytes |
| Android artifact | `build/app/outputs/flutter-apk/app-release.apk` |
| Android emulator smoke | Release APK installed and launched on an Android emulator; app process remained alive with no `AndroidRuntime` or Flutter error entries. Fresh activation, authentication, and navigation **NOT VERIFIED** because the build shows “License configuration or device ID is unavailable. Contact support.” |
| Android offline restart | APK relaunched with emulator Wi-Fi and data disabled and reached the same license-configuration gate without a crash. Valid-license offline behavior **NOT VERIFIED**. Network settings were restored and the emulator was closed. |
| Final static checks | `flutter analyze`: **PASS**; `git diff --check`: **PASS** (line-ending notices only) |

The Windows runner executable was reused by the incremental native build; its freshly built `data/app.so` is the release Dart payload. SHA-256: Windows `data/app.so` `28F99D4F27DF901EA9FE053A2A70C0B588E3BD652AB1C1933634D287A881D701`; APK `CDB9EA0C270BB15E93B1F80348D18E49BD8A1DC7357AA085784117F4D54EAF42`.

**HIGH — release configuration blocker:** both plain release builds lack the `LICENSE_PUBLIC_KEY_BASE64` build define; the license API URL was left unset at the user's direction. Current startup requires the public key and an API URL to show fresh activation, so the built artifacts cannot complete normal first-use licensing. The Android emulator displayed the expected configuration gate. No debug bypass or license workaround was added. A securely supplied release public key and an approved API origin, or a separately reviewed offline provisioning flow, are needed before functional release smoke and distribution.

The APK build also emitted future-support warnings for Gradle 8.14.0, Android Gradle Plugin 8.11.1, and Kotlin 2.2.20; these did not fail the build. The Android application ID is still a placeholder. No production signing setup, AAB, installer, or store package was created. Physical receipt printer, cash drawer, Bluetooth/LAN printer, and camera scanning on real hardware were **NOT PHYSICALLY VERIFIED**. Existing product limitations remain: Kit return/refund/void and Kit Sales Order fulfillment are restricted; ordinary product creation/name/SKU changes lack dedicated audit coverage.

**Internal RC status: NOT READY. Production distribution status: NOT READY.** Both release artifacts compile, but Windows release startup/navigation has not been safely exercised and the current licensing configuration blocks a fresh install. Android debug signing and the placeholder application ID also block production Android distribution. No business data was reset, no genuine backup was modified, no BIR safeguard or permission check was weakened, and no feature or Phase 9 work was started. Windows and Android builds ran sequentially. No signing secret was exposed, no production keystore was generated, and nothing was committed or pushed.

## RC Hardening Pass 5 — release configuration and isolated functional smoke

The existing ignored Ed25519 public key is now supplied to Windows and APK release builds by `scripts/build-release.ps1`. The script validates its 32-byte shape and rejects an HTTP or local release API origin. At the user's direction, the License API URL remains unset. Startup accepts an already valid signed local license while fresh activation shows a configuration gate. Missing or malformed embedded public keys fail closed. No private signing key is embedded in the client.

An internal Windows smoke build used the compile-time `RC_ISOLATED_DATA` switch and a temporary data root. The existing development-profile signed license was copied there with user authorization. Its signature and device binding verified; the source file was untouched. The release app created a new schema 55 SQLite database in that root; integrity was `ok` and foreign-key violations were zero. A disposable Owner was created, signed in, and opened a zero-cash session. Home, POS, Inventory, Sales History, Sales Orders, Cash Session, Serial Explorer, Audit Explorer, and Settings rendered. The app closed and reopened against the same isolated root, accepted the existing local license and Owner login, and returned to Home with the cash session intact. No sale was entered. Network connectivity was not physically disabled during the restart; the compiled API URL was absent.

The key-configured Android APK built successfully (99.0 MB) and installed on the emulator. It cannot complete fresh activation while the URL remains unset. Android release signing is still the debug key and the application ID remains `com.example.modern_offline_pos`. A production keystore, final application ID, HTTPS License API origin, and real-device hardware checks remain distribution gates.

The temporary smoke build must not be distributed. A normal Windows release rebuild without `RC_ISOLATED_DATA` follows the smoke run. The business database and genuine backup files were not used or changed; no BIR or permission safeguard was weakened. No feature phase or Phase 9 was started, and no commit or push was made.

### Pass 5 gate

| Gate | Result |
| --- | --- |
| Baseline suite | Pass 3: 810 passed, 0 failed, 0 skipped; no new full-suite run in Pass 5 |
| Windows functional smoke | PASS on isolated internal release build: valid signed local license, disposable Owner, Home/POS and listed navigation, restart to Home |
| Android APK launch | PASS on emulator: process alive, expected fresh-activation configuration gate |
| Windows normal release build | PASS, existing public key embedded, isolated smoke switch absent |
| Production distribution | NOT READY: API origin unset by request; Android debug signer and placeholder package ID; physical hardware not verified |

**Internal RC status: READY for Windows evaluation with an already provisioned valid local license. Production distribution status: NOT READY.** Fresh installations cannot activate with the intentionally unset API origin. The Windows restart was API-offline by configuration, but host network connectivity was not disabled. The Android valid-license path remains untested. Automatic approval review rejected cleanup of the isolated temporary test folder with a generic "blocked by policy" result; the copied signed test license and disposable database remain under the recorded temp path for manual cleanup. It also rejected a proxy-based offline relaunch; the successful restart used the unset API origin instead.

Pass 5 artifact SHA-256: Windows `data/app.so` `E7865CD7260D1E116A8F3C04A11F9108CABC14075D03C169CABD752B0A99616C`; Android APK `534182DFA295F5935E6DD8E62EDA3B79FB9A14F9BD85D9D2F848C9B38785823E`. Focused licensing/configuration tests: 7 passed. `git diff --check` passed with only line-ending notices. The emulator process remained alive with no AndroidRuntime fatal exception in recent error logs.

Final static analysis note: the repository-wide `flutter analyze` run stalled without a result and was cancelled. A targeted `dart analyze` of the changed licensing, smoke-root, main, and regression-test files completed with **no issues**. The prior full `flutter analyze` run earlier in Pass 5 had completed clean before the final artifact builds.
