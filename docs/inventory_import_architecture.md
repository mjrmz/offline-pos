# Future inventory CSV workflows

CSV import is a future feature. Keep **Import Products** and **Import Opening Inventory** as separate workflows so a product can exist without stock.

Product CSV: parse → validate → preview → resolve duplicate SKU/barcode/name decisions → call the same Product domain service used by manual creation. A layer-priced product may have no master selling price when it has no opening stock.

Opening Inventory CSV: parse → validate → preview → resolve product and duplicate serial/lot decisions → create opening inventory through the inventory domain service. Each opening layer carries its own cost and, for received-stock pricing, its own selling price. Batch number and expiry belong to the actual layer; serialized stock requires real serial numbers.

Both workflows should report row-level errors before committing, use integer cents and fixed-point quantities, and commit only through domain services in a transaction. Direct database inserts would bypass validation, movement history, serial authority, and audit behavior. Supplier deliveries remain in Receiving.
