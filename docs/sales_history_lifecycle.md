# Sales History lifecycle values

Sales History reads persisted transactions. It does not rewrite a sale or its
original receipt total.

- **Gross sale** is the committed original sale total.
- **Returned / refunded** is the sum of finalized commercial return values
  linked to the original sale, plus recorded item refunds from RMA resolution.
  An open RMA without an item refund contributes zero.
- **Net retained sale value** is gross sale minus that value, clamped to zero.
  A void or legacy full refund is displayed separately with zero retained value.
- An exchange reduces the original sale only by its finalized return side.
  Its replacement receipt is a separate sale with its own gross and retained
  values.
- Management Reports allocates that same finalized return value across the
  returned lines using cumulative rounding, so discounted returns add back to
  the same total in product groups and Sales History.
- Return quantities come from finalized `sale_return_lines`, never from
  current inventory. Old records without line provenance cannot show exact
  returned quantities.

The lifecycle status prefers a void or legacy full refund, then exchange,
then commercial return. Active RMA is a secondary badge. The status is a
read-only interpretation of existing records and does not alter return,
inventory, BIR, or accounting behavior.
