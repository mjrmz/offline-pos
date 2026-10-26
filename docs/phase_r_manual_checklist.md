# Phase R manual check

Use a populated offline database. Audit Explorer appears under Admin & Settings for accounts with **Manage users**.

- [ ] Open Audit Explorer as an authorized user; verify an account without Manage users cannot see or open it.
- [ ] Check Today, Last 7 days, Last 30 days, and a custom date range.
- [ ] Filter by actor, module, and action; search a human reference; clear filters.
- [ ] Page through more than 50 events; verify newest first and stable ordering.
- [ ] Inspect Product, Sale, Receiving, Stock Count, Purchase Return, Customer Credit, Supplier Payables, Sales Order, Delivery, customer RMA, supplier RMA, Cash Session, Shift Handover, Promotion, Import, and Kit component events when present.
- [ ] Open source links for Sale, Product, Receiving, Purchase Order, Purchase Return, Stock Count, Sales Order, and RMA; verify unsupported events show a text reference.
- [ ] With an audit viewer lacking catalog, contact, credit, cash, and receiving permissions, verify restricted cost, payable, receivable, and customer or supplier details remain hidden.
- [ ] Confirm password, PIN, token, recovery, and other credential metadata never appears.
- [ ] Check light and dark themes at 1366×768, 1600×900, and 1920×1080.
- [ ] Restart offline and verify the same historical audit records remain available; viewing and searching must not add audit rows.

Known source coverage gap: ordinary product creation and name or SKU edits do not currently write a dedicated product audit event. Kit creation, product price or business configuration changes, barcode aliases, and kit component changes are audited. This explorer does not backfill missing events.
