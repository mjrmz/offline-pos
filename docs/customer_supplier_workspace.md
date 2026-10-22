# Customers & Suppliers workspace

The contact workspace pages customer and supplier records in SQLite at 50 rows
per page. Search resets the page. Profile inspection stays in a right-side
drawer, while create and edit forms use centered dialogs.

Customer Purchases uses the sale date for its period filter and pages sales in
SQLite at 50 rows. Period net spend subtracts finalized returns tied to sales
in that period. The Overview lifetime metric uses the existing customer net
spend aggregate, preserving its historical return semantics.

Supplier **actual purchase value**, quantities, product costs, and the purchase
chart come from finalized Receiving records and use the Receiving date. They
never use the current Product purchase cost as historical cost. Purchase Order
dates and expected costs remain separate. Cost variance compares only Receiving
lines linked to Purchase Order lines; unlinked Receiving has no expected-cost
comparison. Open PO count is a current-state metric and is labelled as such.

The supplier cost views require Reports or Stock Receiving permission. Contact
and purchase history records remain intact when a supplier is inactive.
Supplier purchase lines can be filtered by product, category, and Receiving or
supplier reference. Preferred-supplier products are read from the Product
setting and are displayed without changing that setting.
Supplier PO progress and performance use grouped SQL quantities and delivery
dates, avoiding one detail query per PO. Incomplete lead-time and on-time
samples display "Not enough history" rather than a zero estimate.
