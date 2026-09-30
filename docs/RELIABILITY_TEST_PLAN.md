# Phase 5 reliability test plan

Phase 5 software behavior is implemented for the current Windows and Android
scope. The destructive exit criterion remains unverified until these steps are
run on disposable test installations. Phase 4 physical printer/scanner testing
also remains pending.

## Current behavior

- The live SQLite database uses WAL and foreign keys. Sales, reversals, cash
  sessions, and their audit records use Drift transactions.
- `VACUUM INTO` creates consistent local SQLite snapshots without copying a
  live WAL database file. A backup is published only after `integrity_check`,
  schema inspection, and metadata creation succeed.
- Backups are kept in the app documents `backups` directory: seven rolling
  daily, four rolling weekly, and five manual generations. The app checks for
  due backups at startup and hourly while running. Each snapshot has a JSON
  sidecar with type, creation time, app version, schema version, size, and
  integrity status.
- Restore verifies the selected backup before closing the active database,
  stages it beside the live database, preserves the previous live database as
  `.before-restore`, reopens and checks the restored database, and rolls back
  the file replacement on failure. The owner must be logged in, or must
  provide credentials found in the selected backup when the database cannot
  open. A successful restore logs out the prior session.
- Known-corrupt databases route to recovery and cannot be used for checkout.
  Recovery reports backup integrity and the local Phase 6 license state. SQLite
  repair is not offered; restore from a verified backup is the recovery path.
- Expected cash is starting cash plus persisted `cash_sale` movements for the
  session. Variance is actual minus expected. Refund reversals currently have
  no persisted cash-payout record, so they do not reduce expected cash.

## Manual destructive checks

Use a disposable Windows user profile, virtual machine, or Android test device
with test-only data. Record the app documents directory and copy it outside
the device before each test. Never corrupt a production database.

1. **Power interruption during sale.** Create a product with stock 10. Open a
   cash session. Repeatedly start checkout, then force-stop the test app or
   power off the disposable VM while the sale is being submitted. Restart and
   inspect Sales, SaleItems, Payments, Inventory, InventoryMovements, and
   CashMovements. Each attempt must leave either no sale-related writes or a complete
   sale with one payment, all items and movements, and matching stock. Repeat
   before and after the confirmation appears.
2. **Database corruption.** Make a valid manual backup. Exit the app fully.
   Copy the test database and its `-wal`/`-shm` files elsewhere. On the
   disposable installation only, remove the test `-wal`/`-shm` files after
   the app is fully closed, then replace `modern_offline_pos.sqlite` with a
   short invalid file. Restart. Normal checkout must be blocked, and
   recovery must show the database error and valid backup. Authenticate with
   the owner credentials from that backup, restore it, and verify sales and
   stock. Check that invalid backup files are marked invalid and cannot be
   restored.
3. **Restore point.** Record state A: product list, sales count, inventory
   quantities, active users, and open/closed cash-session state. Create manual
   backup A. Add a recognizable product, complete a test sale, and change a
   cash session to establish state B. Restore A using the Owner recovery tab
   and log in again. Products, sales, stock, users, and cash-session state must
   match A; B-only records must be absent. Check that `.before-restore`
   preserves the previous live database for manual rollback if needed.
4. **Failed restore.** Keep live state B. On the disposable installation,
   copy a valid backup and its `.json` sidecar to `invalid.sqlite` and
   `invalid.sqlite.json`. Change the sidecar's `file` value to
   `invalid.sqlite`, then alter one byte in the copied SQLite header with a
   hex editor without changing its length. Refresh recovery: this entry must
   be marked invalid and have no Restore action. Restart and confirm B's
   products, sales, inventory, users, and cash sessions remain unchanged;
   no restore-success message may appear. Automated tests separately force
   incompatible-schema and post-open restore failures and verify rollback.
5. **Hardware disconnect — Pending physical hardware.** Configure a supported printer, make a test sale,
   and disconnect the printer just after checkout commits and before printing.
   The UI should warn about printing, while the sale, payment, and stock
   changes remain. Reconnect and reprint the stored receipt. Repeat with the
   cash drawer disconnected through the printer connection.
6. **Backup write failure.** On a disposable Windows profile, remove write
   access from that profile's app documents `backups` directory using file
   permissions. Try a manual backup. The UI should report failure and the live
   database should still accept a test sale. Restore the directory permission
   immediately afterward. This simulates a backup write failure without
   filling the OS disk. The automated test also injects an unusable backup
   directory path.

Record device, OS, app version, database schema version, backup selected,
observed rows/status, and screenshots or logs for each run. A build or an
automated test is not evidence that the physical power and peripheral checks
passed.
# Phase 7 disposable installation checks

1. On the currently activated Non-BIR test installation, add a product,
   stock, a user, two sales, an open cash session, and a manual backup.
   Record counts, stock, receipts, and the SQLite file location.
2. In the admin dashboard upgrade that same license to BIR-ready. In POS,
   choose **Refresh license**, enter the same activation key, and restart.
   Verify all old data remains and old sales have no invoice numbers.
3. Complete two sales. Verify invoice 1 then 2 in history and persisted
   receipts/reprints; verify the grand total equals their combined cents.
   Close the cash session and verify the Z snapshot survives restart.
4. Stop the API and dashboard, disconnect networking, restart, and complete
   another numbered sale. Verify the locally signed entitlement is sufficient.
5. On disposable data, create a backup after invoice 2, issue invoices 3 and
   4, then restore that older backup. The next sale must get invoice 5 and
   the accumulated total must include all five issued BIR sales. The Z
   snapshot must remain in history. Keep the before-restore copy.

These manual checks have not yet been performed. In particular, a build and
an automated restore test do not satisfy the live upgrade exit criterion.

## Phase 7 destructive durability run (disposable installation only)

1. Copy the entire application data directory to a safe location. Record its
   path, the database path, and the `compliance-protection.json.journal-*`,
   `.journal-head*`, and `.journal-active` files. Never run this on a business
   installation.
2. Activate BIR-ready mode, open a cash session, issue invoices 1 and 2, and
   create a manual backup. Record both amounts and the accumulated grand total.
3. Issue invoice 3 and immediately force-close the process or cut power to the
   disposable device. Restart and inspect sales history, invoice sequence,
   grand total, and any recovery error. If invoice 3 committed, it must never
   be reused. If an unmatched reservation remains, BIR checkout must stay
   blocked until supervised recovery. Repeat several times with fresh copies.
4. Once a run has a committed invoice 3 and a finalized journal, close the app.
   Corrupt or remove only the **main SQLite database and its `-wal`/`-shm`
   companions**; retain the journal files. Restart into recovery mode and
   restore the backup from step 2. Verify the next issued invoice is at least
   4 and the protected grand total still includes invoice 3. Compare any
   retained Z snapshots before and after restore.
5. Separately, with a fresh disposable copy, damage one journal and verify
   repair from the other. Damage both, or remove the head, and verify BIR
   checkout is blocked with a recovery error. Restore the saved whole data
   directory before continuing other tests.

The post-commit/pre-finalize interval is too short to target reliably by hand.
The automated Phase 7 failure-injection tests deliberately stop at that exact
boundary and verify persisted recovery. Manual power cuts exercise the full
device and filesystem path but cannot prove that exact interval was hit.
