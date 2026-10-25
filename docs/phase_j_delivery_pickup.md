# Phase J: Delivery and pickup

Sales Orders keep three separate states: order status, inventory and Sale fulfillment, and physical fulfillment. Physical transitions update only the Sales Order and append a physical event. They do not create a Sale, change stock or reservations, post credit or cash, or allocate a BIR invoice number.

## Flow

- Pickup: Pending → Scheduled → Ready → Picked up.
- Delivery: Pending → Scheduled → Ready → Out for delivery → Delivered.
- Failed delivery: Out for delivery → Failed delivery → Scheduled for another attempt.
- Active physical fulfillment may be cancelled. Delivered, Picked up, and Cancelled are terminal.
- Ready, Delivered, and Picked up require all order quantities to have been fulfilled through H2 Sales. The physical handoff records a name, timestamp, actor, and optional notes. Failed delivery requires a reason.
- A Sales Order cancellation cancels active physical fulfillment and appends an event. It does not void or refund an existing Sale.

## Snapshots and schedule

Selecting Pickup or Delivery on a draft captures the customer's current name and phone; Delivery also captures the current free text address. These values can be edited on the order without changing the customer profile. The requested date remains separate from the operational scheduled date and time.

## Delivery fee

The optional delivery fee is stored in integer cents on the order, separately from product totals. Entry on the order does not collect it. H2 adds it to exactly one completed Sale: the Sale that fulfills the final remaining quantity. Earlier partial Sales have no delivery fee. The amount is recorded separately on that Sale and shown on its receipt. H2 checks prior nonvoided fulfillment Sales before charging, so a fee cannot be charged twice. The fee and method cannot change after collection, and a fee cannot be added after final fulfillment. Switching from Delivery to Pickup with an uncollected fee requires confirmation in the UI.

## Manual verification

1. Open an existing Sales Order, configure Pickup, schedule it, fulfill through H2, mark Ready, then Picked up with a released-to name.
2. Create a Delivery order, confirm the customer contact and address prefill, edit the snapshot, schedule, fulfill through H2, mark Ready, Out for delivery, and Delivered with a recipient name.
3. Mark an Out for delivery order Failed with a reason, reschedule it, and confirm the earlier failure remains in the event history.
4. Change the customer profile address and confirm the older order still shows its stored address.
5. Confirm Ready and handoff are blocked while any ordered quantity remains unfulfilled.
6. Fulfill a Delivery order in two Sales and confirm the fee appears only on the final Sale and its receipt.
7. Check Fulfillment Queue filters for Today, Ready, Out for delivery, and Needs attention; check an unauthorized user cannot change status.
8. Review light and dark themes at 1366×768, 1600×900, and 1920×1080.

## UI polish checklist

1. Open Sales Orders → Orders, search, filter by order status, method, physical status, and created date. Confirm the list remains readable at 1366×768.
2. Open Fulfillment Queue and try All Active, Today, Pickup, Delivery, Ready, Out for Delivery, and Needs Attention. Confirm failed and overdue work appears first.
3. Open a long-address Delivery order in the right drawer. Check item quantities, inventory state, contact, address, instructions, fee, linked Sales, and activity independently.
4. Configure Pickup and Delivery; confirm Pickup hides address and fee. Schedule each, then check Mark Ready, Out for Delivery, Failed Delivery, Reschedule, Delivered, and Picked Up dialogs.
5. Check terminal orders and users without Manage Sales Orders for absent operational actions. Check Ready is disabled when inventory fulfillment is incomplete.
6. Review light and dark themes at 1366×768, 1600×900, and 1920×1080, including keyboard focus, dialog scrolling, long address text, status contrast, and the action footer.
