# Cash activity v2

The drawer is calculated only by `CashSessionRepository.expected`: opening cash plus signed `cash_movements`. A new drawer expense writes one negative `cash_movements` row and one descriptive `business_cash_movements` row in the same transaction. The descriptive row is never summed into the drawer. A reversal writes one positive drawer movement. Closed shift drawer expenses cannot be reversed, because the closing expected amount and any Z reading must stay stable.

`business_cash_movements` is an append-only ledger for expenses, replenishments, opening counts and reversals. Petty cash and company cash balances are derived from source and destination signs. Personal expenses create reimbursement due without changing a business cash balance. Owners can record an opening count for either standalone fund. Manager or owner can move company cash into petty cash; this is a transfer, never revenue. Standalone funds cannot be spent below zero.

SQLite triggers reject updates and deletes to posted business cash movements. Corrections are new reversal rows with an actor, timestamp, reason, and original reference.

Existing `petty_cash_entries` remain intact and retain their original cash-session links. They are shown as legacy drawer expenses and remain in the authoritative drawer calculation through their existing `cash_movements` rows. They are not copied into the new ledger, so migration does not duplicate their effect. Existing category names seed managed categories only when historical records exist; otherwise defaults are used. Each new movement snapshots its category name, so later rename or deactivation does not change history.

Cashiers can record drawer expenses. Managers and owners can record from other sources, replenish, manage categories, and reverse open-shift or standalone movements. Only owners can record opening fund cash. These rules use the existing user roles.

Future work: fund-to-fund transfer UI beyond company-to-petty replenishment, cash drops, change-fund additions, reimbursement settlement, approval thresholds, receipt attachments, CSV export, and accounting integration.
