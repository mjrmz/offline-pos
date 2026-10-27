# RC Pass 3 failure inventory

Source: `.rc2_full_test.log` (734 passed, 58 failed, 0 skipped). Categories record the initial triage: A invalid historical fixture; B stale schema assertion; C production defect; D stale UI expectation; E responsive/layout assertion; F timing; G Windows locking; H test isolation; I environment; J other. Focused investigation refined some causes after this inventory was written.

**Final disposition:** all 58 original failures passed in the final serial suite (`.rc3_full_final.log`: 810 passed, 0 failed, 0 skipped). Migration failures fell from 28 to 0; other failures fell from 30 to 0. Historical fixture repairs and schema expectation updates resolved the migration group. The genuine schema 22 serial-source defect and dashboard overflow required production fixes. Current navigation/control expectations resolved stale UI tests. Serial execution with a two-minute per-test timeout eliminated parallel-load timeouts and Windows temp-file contention. No remaining failing tests.

| # | Test | Failure signal | Category |
| ---: | --- | --- | :---: |
| 1 | `test/cash_activity_widget_test.dart`: Escape dismisses replenish inside the POS shell | Test failed. See exception logs above. | D |
| 2 | `test/data/customer_credit_migration_test.dart`: v44 credit rows survive additive v45 migration | SqliteException(1): while executing, no such table: sales, SQL logic error (code 1) | A |
| 3 | `test/cycle_count_historical_backup_test.dart`: genuine historical backup validates and restores on isolated copy | TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. See https://pub.dev/packages/test#timeouts | F |
| 4 | `test/cycle_count_hardening_test.dart`: restart preserves link, frozen category scope, and overdue boundary | TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. See https://pub.dev/packages/test#timeouts | F |
| 5 | `test/data/inventory_health_test.dart`: schema 36 upgrade adds defaults without touching products | TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. See https://pub.dev/packages/test#timeouts | F |
| 6 | `test/data/inventory_layer_migration_test.dart`: v19 backfill preserves stock and marks unresolved opening quantity | TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. See https://pub.dev/packages/test#timeouts | A |
| 7 | `test/data/inventory_layer_migration_test.dart`: v19 backfill follows surviving batches and serial identities | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 8 | `test/data/migration_test.dart`: v1 to v7 preserves historic sale, stock, cash session and audit | TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. See https://pub.dev/packages/test#timeouts | F |
| 9 | `test/data/migration_test.dart`: v6 to v7 adds cash movements and preserves Phase 4 data | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | J |
| 10 | `test/data/phase85_migration_test.dart`: schema 29 petty cash survives cash activity migration without double counting | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 11 | `test/data/phase85_migration_test.dart`: schema 28 catalog quotation lines survive nullable product migration | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 12 | `test/data/phase8_foundation_test.dart`: version 8 migration retains existing POS rows and defaults flags off | PathAccessException: Deletion failed, path = 'C:\Users\MJ\AppData\Local\Temp\phase8-migration-13bd8278' (OS Error: The process cannot access the file because it is being used by another process, errno = 32) | G |
| 13 | `test/data/phase85_migration_test.dart`: schema 22 upgrades warranty snapshots without changing legacy RMA | Expected: &lt;46&gt; | A |
| 14 | `test/data/phase8_quantity_migration_test.dart`: schema 9 to 10 scales historic quantities and keeps BIR and flags | PathAccessException: Deletion failed, path = 'C:\Users\MJ\AppData\Local\Temp\phase8-v9-217d82ac' (OS Error: The process cannot access the file because it is being used by another process, errno = 32) | G |
| 15 | `test/data/phase85_migration_test.dart`: schema 21 RMA survives append-only lifecycle migration | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 16 | `test/data/pos_workflow_test.dart`: held sales persist across restart without reserving stock | Expected: &lt;46&gt; | B |
| 17 | `test/data/phase85_migration_test.dart`: schema 18 RMA survives item refund and supplier replacement migration | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 18 | `test/data/pos_workflow_test.dart`: fixed order discount reduces loyalty eligible spend and rejects excess | Bad state: Below-cost authorization required; sale changed or approval is missing | J |
| 19 | `test/data/phase85_migration_test.dart`: schema 17 RMA records survive schema 18 replacement link migration | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 20 | `test/data/promotion_checkout_migration_test.dart`: version 41 sale migrates to 43 without changing historical totals | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 21 | `test/data/promotion_repository_test.dart`: version 40 upgrades add promotion tables without changing products | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 22 | `test/data/phase85_migration_test.dart`: schema 16 upgrades refund accounting without losing credit entries | Expected: &lt;46&gt; | A |
| 23 | `test/data/promotion_checkout_migration_test.dart`: version 42 adds promotion analytics index without changing sales | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 24 | `test/data/phase85_migration_test.dart`: schema 14 adds debt payment method and receipt settings | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 25 | `test/data/purchase_return_test.dart`: schema 43 upgrades additively and preserves receiving and stock | Expected: &lt;46&gt; | B |
| 26 | `test/data/rbac_test.dart`: v39 upgrade preserves users and credentials while seeding roles | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | J |
| 27 | `test/data/phase85_migration_test.dart`: schema 11 backfills sale session from cash movement | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 28 | `test/data/sales_order_fulfillment_test.dart`: schema 48 migrates without fabricating fulfillment links | Expected: &lt;50&gt; | B |
| 29 | `test/data/sales_order_physical_test.dart`: schema 49 migration preserves order and initializes physical state | Expected: &lt;50&gt; | B |
| 30 | `test/data/phase85_migration_test.dart`: schema 10 upgrades to current schema and preserves Phase 8 data | Expected: &lt;46&gt; | A |
| 31 | `test/data/sales_order_repository_test.dart`: schema 46 adds order tables without changing business rows | Expected: &lt;50&gt; | B |
| 32 | `test/data/serialized_opening_stock_test.dart`: version 20 serial upgrade retains persisted receiving provenance | SqliteException(1): while executing, table cash_shift_handovers already exists, SQL logic error (code 1) | A |
| 33 | `test/data/stock_reservation_test.dart`: 47 to 48 migration retains stock and leaves orders unreserved | Expected: &lt;50&gt; | B |
| 34 | `test/global_search_navigation_test.dart`: partial barcode input keeps POS focus on Ctrl K | Test failed. See exception logs above. | D |
| 35 | `test/inventory_overview_test.dart`: Tools keeps Expiry Monitor in the Inventory workspace | Test failed. See exception logs above. | D |
| 36 | `test/inventory_overview_test.dart`: Movements ledger filters and stacks at narrow width | Test failed. See exception logs above. | D |
| 37 | `test/inventory_overview_test.dart`: Movements show supplier reference without exposing UUID | Test failed. See exception logs above. | D |
| 38 | `test/label_printing_widget_test.dart`: Inventory Tools label picker, quantity, removal and preview (ThemeMode.light) | Test failed. See exception logs above. | D |
| 39 | `test/label_printing_widget_test.dart`: Inventory Tools label picker, quantity, removal and preview (ThemeMode.dark) | Test failed. See exception logs above. | D |
| 40 | `test/inventory_workflow_widget_test.dart`: serialized opening stock requires exact scanned serials | Test failed. See exception logs above. | D |
| 41 | `test/inventory_workflow_widget_test.dart`: Products search, detail, and receive shortcut | Test failed. See exception logs above. | D |
| 42 | `test/home_widget_test.dart`: sale appears when history and reports tabs open | Test failed. See exception logs above. | D |
| 43 | `test/rbac_navigation_test.dart`: inventory role cannot reach POS or sales from navigation | Test failed. See exception logs above. | D |
| 44 | `test/ux_shell_test.dart`: desktop groups destinations and keeps cart beside catalog | Test failed. See exception logs above. | D |
| 45 | `test/ux_shell_test.dart`: sidebar fills workspace and account menu stays at bottom | Test failed. See exception logs above. | D |
| 46 | `test/ux_shell_test.dart`: light sidebar keeps account footer readable | Test failed. See exception logs above. | D |
| 47 | `test/ux_shell_test.dart`: F11 and visible control toggle POS focus without replacing checkout | Test failed. See exception logs above. | D |
| 48 | `test/ux_shell_test.dart`: quotation editor keeps the desktop application shell | Test failed. See exception logs above. | D |
| 49 | `test/ux_shell_test.dart`: mobile keeps five primary destinations and exposes More | Test failed. See exception logs above. | D |
| 50 | `test/ux_shell_test.dart`: Settings keeps inventory health and product features inline | Test failed. See exception logs above. | D |
| 51 | `test/ux_shell_test.dart`: Settings embeds team and receipt hardware screens | Test failed. See exception logs above. | D |
| 52 | `test/ux_shell_test.dart`: global shift status keeps cashier in POS when closed | Test failed. See exception logs above. | D |
| 53 | `test/ux_shell_test.dart`: POS restores only a genuinely open session across app mounts | Test failed. See exception logs above. | D |
| 54 | `test/ux_shell_test.dart`: Inventory is one destination with four internal views | Test failed. See exception logs above. | D |
| 55 | `test/ux_shell_test.dart`: desktop shell, POS, Inventory and cash session render in light | Test failed. See exception logs above. | E |
| 56 | `test/ux_shell_test.dart`: narrow shell renders in light | Test failed. See exception logs above. | E |
| 57 | `test/ux_shell_test.dart`: desktop shell, POS, Inventory and cash session render in dark | Test failed. See exception logs above. | E |
| 58 | `test/ux_shell_test.dart`: narrow shell renders in dark | Test failed. See exception logs above. | E |
