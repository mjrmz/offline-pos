# POS checkout architecture

Visual Catalog remains the product-card checkout for specialty retail. Scan-First is a full-cart barcode checkout: a compact customer and scanner strip, one scrollable cart table, and a persistent total and Pay action. Both layouts live in `CheckoutScreenState` and share its cart, customer, quotation context, stock checks, payment inputs, and `SaleService`. Layout switching keeps the mounted checkout state; quotation conversion uses the selected layout.

The Owner selects a layout in Settings → POS. `PosLayoutPreference` stores the layout and scanner options in device-local `SharedPreferences`. No database migration or data reset is involved. Visual Catalog remains the default. Hybrid, Quick Keys, and Compact are reserved for future work.

Scan-First accepts barcode, SKU, or serial on Enter. Resolution checks exact barcode, then exact available serial, then case-insensitive SKU. Ordinary scans merge quantity in the shared cart. Configured additions receive separate cart-line identities, so LPG exchange and deposit, refill and container, and distinct serialized or made-to-order additions can coexist. The sale repository processes each configured line in the existing sale transaction. Batch and FIFO allocation, stock checks, cash session, BIR, receipt, and audit remain in the existing sale path.

Keyboard shortcuts: F1 help, F2 customer, F3 scanner focus, F4 product lookup, F5 selected ordinary-line quantity, F6 hold sale, F7 held sales, F8 payment, F10 more actions, F11 focus mode, Up/Down cart selection, Delete selected line, and Escape to dismiss an exception or dialog. Both layouts use the same actions. The app treats scanners as keyboard input; it does not detect USB connectivity.

## Workspace focus and shortcut strip

The POS shell owns Focus Mode. F11 or the compact POS control toggles it for either Visual Catalog or Scan-First. The native window title bar and POS shift status remain visible; the navigation sidebar and its account footer disappear while the checkout fills the freed space. Leaving POS restores the normal shell. Returning to POS uses this device's saved default. The current cart, customer, quote context, scanner and payment input remain in the mounted checkout state during a toggle. **Focus Mode changes presentation only. It does not change transaction processing.**

Settings → POS → Workspace stores **Start POS in Focus Mode** (off by default) and separate device-local shortcut-bar choices for each layout. Visual Catalog defaults to off; Scan-First defaults to on. Existing devices with the former single shortcut-bar preference keep that choice until a layout-specific choice is saved. The Owner's existing Settings permission controls these defaults. A cashier may toggle runtime Focus Mode without changing the default.

Shortcut profiles control presentation only. Scan-First shows a fuller shortcut strip; Visual Catalog keeps compact Hold and Held Sales actions beside the current sale. F8 opens the same payment dialog in both layouts. Focus Mode respects the active layout's bar setting and reclaims the bottom space when the bar is off.

Held sales persist as cart snapshots in `held_sales`; they do not reserve inventory. Resume checks active products, stock, batches, serials, customer status, and rewards. Current prices apply on resume, with a notice when totals change. One manager-approved manual discount may apply to a line or the order. Its effect is allocated to sale item totals, and `sale_manual_discounts` stores the reason and authorizer. Walk-in name and contact are optional sale snapshots without a Customer record or loyalty account. A completed checkout shows its receipt, payment, customer, and rewards summary until New sale clears the state.

Current future work: promotions, mixed payments, quantity prefixes, embedded-weight barcodes, Hybrid, Quick Keys, and Compact. Hardware scanner, printer, and cash drawer behavior still require verification on target devices.
