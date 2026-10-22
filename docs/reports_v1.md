# Management Reports V1

Reports is a read-only workspace with Overview, Sales, Profit & Loss, Expenses,
and Inventory views. The reporting period uses local calendar boundaries; its
end is exclusive. Inventory is a current snapshot and is labelled separately
from the selected sales period.

## Sales and cost rules

- Revenue comes from persisted sale totals, full sale reversals, and RMA item
  refunds. The BIR grand total is never used as management revenue.
- A sale contributes revenue and its persisted allocation cost on its sale date.
  A full reversal contributes negative revenue on the reversal date. Its COGS
  reverses only when the reversal restored sellable stock.
- An RMA item refund contributes negative revenue on its refund date. The
  current RMA refund workflow does not restore inventory, so its original COGS
  remains recognized.
- COGS comes from each `SaleItemInventoryAllocation` quantity and
  `unitCostSnapshotCents`. Current product reference cost is not used.
  If historical allocation quantities are incomplete, profit totals show
  **Unavailable** instead of an invented amount.
- Product/category attribution follows the current product/category mapping
  where no historical category snapshot exists. Historical sale-item names are
  used for product labels.
- Payment-method totals show original tender for sales recorded in the period.
  They are not a cash-flow report.

## Expenses and inventory

- Expense totals include business expense movements and historical drawer
  expenses. An expense reversal offsets its original expense when posted.
  Personally paid expenses are recognized when recorded.
- Fund openings, replenishments/transfers, and reimbursement settlements do
  not become expenses or revenue. There is currently no separate reimbursement
  settlement entry in the cash activity repository.
- Inventory cost value uses remaining inventory-layer quantities and their
  persisted unit costs. If layer quantity does not reconcile with on-hand
  quantity, cost value is shown as partial/unavailable.
- Retail value uses current product price for current-price products. For
  layer-priced products, it uses remaining layer selling prices and is shown
  as unavailable when price snapshots or layer reconciliation are incomplete.
  Potential gross profit is unrealized and is separate from the P&L.
- Low-stock status uses current available quantity after reservations.

Future views can use the same `ReportPeriod` and reporting repository: Cash
(where the cash is), Receivables (Utang/credit), Daily Business Summary,
period comparisons, PDF export, and CSV export. They have no V1 controls or
sidebar destinations.
