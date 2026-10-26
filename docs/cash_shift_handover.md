# Phase M1: Cashier shift handover

Schema 52 adds `cash_shift_handovers` and
`cash_shift_handover_denominations`. Migration from schema 51 creates empty
tables. Existing Cash Sessions and business data are not rewritten.

Cash Session remains the financial authority. A handover references an open
session and snapshots its expected cash as opening cash plus Cash Movements.
The count is the sum of integer cent denominations times quantities. Variance
is actual minus expected. A nonzero variance requires a note. Completing a
handover never inserts a Cash Movement or changes the session balance.

References use `HOV-000001`, based on the handover's local integer sequence.
Available counts are PHP 1000, 500, 200, 100, 50, 20, 10, 5, and 1. The
20 peso note and coin share one value to avoid an ambiguous duplicate.

One draft or awaiting handover is allowed per session. The outgoing cashier
is the session opener, or the receiving cashier of the latest completed
handover. A manager with `closeAnyCashSession` can start or submit on their
behalf. The incoming user must be active, distinct, and allowed to sell and
manage a cash session. Drafts can be counted and submitted; submitted counts
are locked. Recount returns to draft with a fresh expected snapshot. The
manager acknowledgment requires `acknowledgeShiftHandover`; another user's
password is checked using the existing authentication hash and lockout
records. An authorized logged in manager can confirm directly. Completion
rechecks the session, users, expected cash, denomination sum, and variance
inside one SQLite transaction. Completed rows and their counts are immutable.
Cancelled rows remain historical.

The Cash Session opener is not changed. Existing POS sale and payment
ownership checks still use that opener, so receiving responsibility is
recorded in handover history without granting the incoming cashier the
opener's POS authority. Managers can use the existing close and reopen
workflow when the incoming cashier needs to become the financial session
owner. A pending acknowledgment blocks normal session close; drafts can be
cancelled or completed independently. Sales during a draft remain possible.
If expected cash changes, submission or acknowledgment fails and requires
recount. Variance never adjusts drawer cash automatically.

The Cash Session screen contains the start action, a three step count and
review flow, manager acknowledgment, completion summary, and paged manager
history with status and variance filters. Details open in a right drawer.
Cashiers see only their active handover; historical financial views require
the acknowledgment capability. Audit records start, submitted count,
manager acknowledgment, completion, and cancellation.

## Manual check

1. Open Cash Session as Cashier A and start handover.
2. Select active Cashier B; count denominations by direct quantity entry.
3. Review a balanced count and complete with manager acknowledgment.
4. Repeat with a short or over count; confirm a reason is required.
5. Confirm completion creates no Cash Movement and does not adjust expected cash.
6. Try a second active handover on the same session.
7. Make a cash sale during counting; confirm submission or acknowledgment asks for recount.
8. Try closing while awaiting acknowledgment; cancel or complete the handover.
9. Browse history and detail drawer with manager and cashier accounts.
10. Check light and dark themes at 1366 × 768.
