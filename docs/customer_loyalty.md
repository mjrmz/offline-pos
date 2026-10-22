# Customer profiles and loyalty (schema 34)

Loyalty stays within Customers & Suppliers. Points are keyed by customer ID and
stored as append-only movements in `loyalty_ledger`. Balance is the signed sum
of those movements; it may become negative after a legitimate return reversal.
Future earnings offset a negative balance. Normal redemption and manual
decrease require enough available points. Customers without movements have no
loyalty activity, and anonymous sales never earn points.

The store-wide rule defaults to ₱100 of eligible spend per point and 100 points
per ₱10 discount. Settings changes affect only future sales. A completed sale
stores eligible cents, earned points, redeemed points, discount cents, and both
rule snapshots in `sale_loyalty`. Earned points are
`eligible_cents ~/ spend_per_point_cents`. Redemption uses whole conversion
units and is limited to the ledger balance and positive payable total. Earn and
redeem entries commit in the sale's SQLite transaction. Loyalty discounts stay
separate from Utang and other payments.

Eligible spend is the completed sale total after loyalty redemption. Exchange
credit is a payment for the replacement sale; the returned side separately
reverses its original points, so the replacement earns on its full value.
Customer lifetime net spend uses completed sale totals less
finalized commercial return `refund_value_cents`. Voided and fully refunded
sales are excluded. The list summary aggregates this in one database query.

For a partial return, each returned line uses its original saved line total.
If the sale used points, the cash refund is reduced by the incremental share of
the saved loyalty discount. Incremental share is the difference between
`discount * cumulative_gross_returned ~/ original_gross_sale` after and before
this return. Redeemed points are restored using the same cumulative allocation
with the original redeemed points. Earned points are reversed using the
incremental share of original earned points against cumulative net returned
value over original eligible spend. This integer method allocates rounding to
later returns and sums to the original amounts on a full return. Return
movements commit with the return transaction. Exchanges apply the return side
first and link the replacement sale to the same customer, earning on its
full commercial value. Full void/refund appends separate earned reversal and
redeemed restoration entries; original entries remain auditable.

Customer groups use one optional primary group. Missing group rows display as
Retail. Owner changes, manual point adjustments, and settings changes are
audited. Existing SQLite backup and restore carries the four new tables.
Customer merge, tier progression, promotions, and point expiration are future
work.
