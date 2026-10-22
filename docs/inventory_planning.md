# Inventory planning (schema 36)

Products may store a reorder level, target stock, and preferred supplier. Quantities are integer thousandths. Blank levels disable the corresponding warning or suggestion. The target must be at least the reorder level.

The shared planning query reads physical stock from `inventory`, subtracts active layaway reservations and RMA reserved serials for available stock, and sums the remaining quantities of sent purchase order lines for incoming stock. Cancelled line quantities and quantities already received are subtracted. Draft, closed, and cancelled orders do not contribute. Incoming is never added to physical stock.

Projected stock is available plus incoming. Suggested reorder is `max(0, target - projected)`. Reorder level is a warning threshold, not an order quantity. Creating a PO does not update inventory; finalized receiving does.

Last and previous purchase costs come from stock receiving items in date order. Aging begins at the oldest inventory layer with a positive remaining quantity. Cost value uses the remaining quantity and layer unit cost. These read values are not persisted or used to change FIFO allocation, valuation history, or profit.

The migration only adds nullable product columns. Existing records keep their stock and transaction history. SQLite backup and restore retain the three configuration fields because they are part of the database; derived values are recalculated.
