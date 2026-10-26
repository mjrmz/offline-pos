# Phase Q manual verification

Use a local test database with disposable sample transactions. Confirm the Home page and the destination after each click. No cloud connection is required.

- [ ] POS-only user sees only permitted actions and own sales.
- [ ] No Cash Session: opening a session is the first action.
- [ ] Active Cash Session: New sale is the first action and opened time is readable.
- [ ] Held Sales: count is own only and the link opens POS.
- [ ] Inventory-focused user has a useful Home without financial totals.
- [ ] Low stock alert opens the existing inventory filter.
- [ ] Out-of-stock alert opens the existing inventory filter.
- [ ] Near-expiry alert opens Expiry Monitor.
- [ ] Pending handover opens Cash Session and the existing handover workflow.
- [ ] Sales Orders and failed delivery alerts open Sales Orders.
- [ ] Receivables are visible only with Customer Credit access.
- [ ] Payables are visible only with Reports and Contacts access.
- [ ] Cost and profit remain absent for restricted users.
- [ ] Broad-access user sees a compact, coherent layout.
- [ ] Unusual custom permission combinations leave no inaccessible action.
- [ ] Each Quick Action, including More, opens its intended module.
- [ ] Each attention and operational row opens its intended module or filter.
- [ ] Refresh reflects new local data without leaving Home.
- [ ] Light theme has readable labels, borders, and semantic warnings.
- [ ] Dark theme has readable labels, borders, and semantic warnings.
- [ ] 1366×768 has no overflow, clipped labels, or horizontal scroll.
- [ ] 1600×900 has balanced spacing.
- [ ] 1920×1080 keeps the content width comfortable.
- [ ] Offline restart loads Home from the local database.
