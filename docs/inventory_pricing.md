# Product and stock-layer pricing

Products have one of two selling-price policies. Both retain actual purchase cost on each inventory layer. FIFO or exact serial allocation determines which layer supplies cost of goods sold.

Product definition holds identity, unit, tracking and selling capabilities. Current commercial configuration holds the refill container charge and LPG deposit for future checkouts. Stock instances hold quantity, actual cost, optional layer selling price, batch, expiry, serial identity, and source. Product reference purchase cost is an optional default; it is not the cost of stock on hand.

Create Product asks for identity and behavior, then the Starting Inventory path, then pricing and any opening stock values. With no stock or supplier receiving, Product-price mode asks for one Product selling price; layer-price mode waits for opening or received stock. With normal opening stock, the single selling-price field stores either the current Product price or the opening layer price according to the selected policy. Opening quantity and required stock cost start blank. Batch totals derive from batch rows; serialized totals derive from serial entries.

Weight controls quantity behavior independently of selling-price policy. A kg or g product may use either one product price or separate layer prices. Product price is usually simpler for shelf-price grocery; layer pricing suits stock acquisitions with genuinely different selling prices.

The current Product form disables weight with refill, LPG, or made-to-order, and serial tracking with weight or made-to-order stock. Serial units must be whole. Batch tracking can be combined with weight or serial tracking; batch with made-to-order is unavailable. Refill and LPG are separate checkout workflows. These rules are validated when a Product is saved as well as shown in the form.

## Use one product price

The Product holds the current selling price. Receiving and opening inventory record their actual per-unit costs, but do not need a separate editable layer selling price.

Example: Product selling price ₱15; Layer A cost ₱8; Layer B cost ₱10. Both layers sell at the current Product price of ₱15. FIFO determines whether the sale consumes cost ₱8 or ₱10.

## Price each stock layer separately

The Product does not require a master selling price. Each opening or finalized Receiving layer holds its own purchase cost and selling price. A zero-stock Product has no priced layer yet. Receiving must collect the selling price before its stock is finalized.

Example: Layer A costs ₱8 and sells for ₱15; Layer B costs ₱10 and sells for ₱17. FIFO or an exact serial allocation determines the layer and its cost and selling-price snapshot.

When a sale spans differently priced layers, the sale total adds each FIFO allocation at that layer's selling price. The arithmetic uses integer milli-units and cents with fixed-point rounding per allocation. Container and LPG charges are current Product settings, while sales and quotations store the charge applied at transaction time. Editing a current charge does not reprice historical transactions.

Batch number and expiry belong to the opening or received layer. Serial units identify actual physical units on a layer. Neither capability creates stock by itself. Opening stock is a layer; supplier stock becomes a layer only when Receiving is finalized.

The layer cost and selling-price snapshots leave room for future gross-margin reporting. This workflow does not calculate or display profit analytics. Future CSV import workflows are described in [inventory_import_architecture.md](inventory_import_architecture.md); they must create Products and opening layers through domain services.
