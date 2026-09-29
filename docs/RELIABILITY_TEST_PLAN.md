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
  Recovery reports backup integrity and the honest pre-license state. SQLite
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
   inspect Sales, SaleItems, Payments, InventoryMovements, CashMovements, and
   stock. Each attempt must leave either no sale-related writes or a complete
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
3. **Restore point.** Create manual backup A. Add a recognizable product and
   complete a test sale. Restore A using the Owner recovery tab. Log in again.
   The later product and sale must be absent; earlier data must match A. Check
   that `.before-restore` preserves the previous live database for manual
   rollback if needed.
4. **Hardware disconnect.** Configure a supported printer, make a test sale,
   and disconnect the printer just after checkout commits and before printing.
   The UI should warn about printing, while the sale, payment, and stock
   changes remain. Reconnect and reprint the stored receipt. Repeat with the
   cash drawer disconnected through the printer connection.
5. **Backup write failure.** On a disposable Windows profile, remove write
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
