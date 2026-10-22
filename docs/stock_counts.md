# Stock Counts and Inventory Adjustments

Inventory → Stock Counts contains count sessions and posted adjustments. Counts use independent `SC-000001` references; adjustments use `ADJ-000001`. The reference sequences are local to this database and independent of receipts and BIR invoices.

## Controls

- Managers and owners can create, enter, refresh, and cancel counts. Only owners can finalize counts or post one-off adjustments. Cashiers have no access to this workspace.
- A count snapshots each product's expected quantity, unit, and movement count when created. Blank counted quantity means uncounted; explicit zero means none was found. Count lines can carry notes. Only explicitly counted variance lines create adjustments. Matched and uncounted lines create no adjustment.
- Finalization compares current quantity and movement count with the snapshots for every counted line. Any changed line blocks the whole transaction, even when stock returned to the original quantity. Refresh resets its snapshots and clears its count, requiring a recount.
- Each posted adjustment writes a movement, audit log, and layer allocation. Negative ordinary stock consumes FIFO layers. Batch stock requires the affected batch. Serialized stock requires the exact serials. Positive stock creates an `adjustment` origin layer and requires a confirmed unit cost; layer-priced products also require a selling price.
- All quantities are integer thousandths. Finalized counts and adjustments have no edit or delete path. Corrections use a new adjustment or count. Reversal is not implemented in V1.
- The new tables are included in backup integrity verification. Historical sale COGS and BIR data are unchanged. Stock adjustments do not automatically become operating expenses in management reports.

## Manual checks

1. Create Product A with 10 units. Create a count, enter 8, review, and finalize. Product A should have 8 on hand, one `ADJ-` adjustment for -2, and one stock count variance movement. The count should be read-only.
2. Create two layers, 5 units at ₱50 and 5 units at ₱70. Post -7 Lost. The allocation should consume 5 from the older layer and 2 from the newer layer, leaving 3 in the newer layer. Sell the remaining 3 and confirm its sale COGS still uses ₱70 per unit.
3. Create a serialized product with SN001 and SN002. Adjust -1 Lost and select SN002. SN001 should remain available; SN002 should be marked unavailable and linked to the adjustment allocation.
4. Create a count at 10 units, then sell one before finalization. Enter 10 and review. Finalization must fail with a stock changed message. Refresh the line, recount, and review again.
5. Check count entry and dialogs at 1366×768, 1600×900, and 1920×1080 in light and dark modes. Verify Escape and Cancel dismiss dialogs without stock changes, then reopen them.

## V1 limits

The workspace has no reversal action. To correct a posted adjustment, make a new adjustment with a reason and notes. Counts are product scoped; variants and multiple warehouses are not separate count dimensions in the current data model.
