# 1. Start everything

Repository: `C:\Users\MJ\Desktop\VERTEX\modern-offline-pos`

## Terminal 1 — Start PostgreSQL

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe' start -D "$env:LOCALAPPDATA\modern-offline-pos-phase6\postgres-data" -l "$env:LOCALAPPDATA\modern-offline-pos-phase6\postgres.log" -o '-h 127.0.0.1 -p 55432'
```

Expected: PostgreSQL listens on `127.0.0.1:55432`.

## Terminal 2 — Start License API

```powershell
cd C:\Users\MJ\Desktop\VERTEX\modern-offline-pos\cloud\license_api
npm run migrate
npm start
```

Expected: `http://localhost:3000`. In another terminal, check:

```powershell
Invoke-RestMethod http://localhost:3000/healthz
```

## Terminal 3 — Start Admin Dashboard

```powershell
cd C:\Users\MJ\Desktop\VERTEX\modern-offline-pos\cloud\admin_dashboard
npm run dev
```

Expected: `http://localhost:5173`.

## Terminal 4 — Start POS

```powershell
cd C:\Users\MJ\Desktop\VERTEX\modern-offline-pos
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-phase6-windows.ps1
```

Do **not** normally use `flutter run -d windows`: the licensing dart-defines may be missing.

# 2. Admin login

Open `http://localhost:5173`. Username: `admin`. Read the local password with:

```powershell
Get-Content "$env:LOCALAPPDATA\modern-offline-pos-phase6\admin-password.txt"
```

# 3. Normal product test

- [ ] POS opens and login works
- [ ] Product is visible; add it to cart
- [ ] Enter cash and complete sale
- [ ] Stock decreases; sale appears in history
- [ ] Reports load; cash session works; backup works

# 4. Offline licensing test

1. Activate POS while the API is online, if needed.
2. Close POS; stop API and dashboard with `Ctrl+C`.
3. Disconnect internet; restart POS with `run-phase6-windows.ps1` from section 1.
4. Verify:
   - [ ] No activation screen; login works
   - [ ] Sale, inventory, history, reports, and backup work

# 5. BIR-ready test

Phase 7 status: **Complete**. Automated verification and manual live upgrade,
offline BIR, and restore monotonicity verification passed. Repeat the steps
below for future releases or installations.

1. Start API and dashboard; find the active Non-BIR license.
2. Click **Upgrade to BIR-ready**.
3. In POS: Owner → top-right menu → **Refresh license**.
4. Enter the existing activation key; restart POS.
5. Open cash session; make two sales; close the session.
6. Verify:
   - [ ] Old Non-BIR data exists; old sales have no BIR invoice number
   - [ ] First and second BIR sales get the correct sequential invoice numbers
   - [ ] Grand total increases; receipt/reprint keeps its original invoice number
   - [ ] Closing the session creates a Z-reading

# 6. BIR offline test

1. Stop API and dashboard; disconnect internet.
2. Restart POS; open cash session; make another sale.
3. Verify:
   - [ ] BIR works offline; invoice number and grand total continue
   - [ ] History works; Z-reading history still exists

# 7. Backup/restore BIR test

**DISPOSABLE TEST DATA ONLY**

1. Make BIR invoices 1 and 2; create a backup.
2. Make invoices 3 and 4.
3. Restore the backup from after invoice 2; make another sale.
4. Verify:
   - [ ] Invoice 3 and invoice 4 are not reused; next invoice is 5 or later
   - [ ] Grand total does not improperly decrease
   - [ ] Z-reading protection remains intact

# 8. Automated tests

From the repository root:

```powershell
dart run build_runner build
flutter analyze
flutter test --concurrency=1
flutter build windows
flutter build apk
```

Backend:

```powershell
cd C:\Users\MJ\Desktop\VERTEX\modern-offline-pos\cloud\license_api
npm test
```

Dashboard:

```powershell
cd C:\Users\MJ\Desktop\VERTEX\modern-offline-pos\cloud\admin_dashboard
npm test
npm run build
```

# 9. Stop everything

Stop License API and dashboard with `Ctrl+C`. Close POS. Stop the local PostgreSQL cluster:

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe' stop -D "$env:LOCALAPPDATA\modern-offline-pos-phase6\postgres-data"
```

# 10. Quick troubleshooting

## Failed to fetch

Run `Invoke-RestMethod http://localhost:3000/healthz`. If unavailable, start PostgreSQL and License API.

## Internal server error

Check the License API terminal. In `cloud/license_api`, run `npm run migrate`.

## License configuration or device ID unavailable

From the repository root, run `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-phase6-windows.ps1` instead of plain `flutter run`.

## Invalid admin credentials

Username: `admin`. Read the password with `Get-Content "$env:LOCALAPPDATA\modern-offline-pos-phase6\admin-password.txt"`.

## Refresh license missing

Log in as Owner; ensure `LICENSE_API_URL` is configured and a device ID is available.

# 11. Final pass checklist

- [ ] App launches; licensing and offline restart work
- [ ] Checkout, inventory, sales history, reports, and cash sessions work
- [ ] Backup/restore works
- [ ] Non-BIR → BIR-ready upgrade preserves data
- [ ] BIR invoice numbering, grand total, and Z-reading work
- [ ] BIR works offline; old backup does not reuse invoice numbers
- [ ] Windows and Android builds pass; automated tests pass
