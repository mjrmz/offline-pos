# Purchase Orders in Inventory

Inventory has Overview, Products, Purchase Orders, Receiving, and Movements. A Purchase Order records an intended supplier purchase. Saving or marking it sent does not create stock, an inventory movement, an expense, or a cash movement. Only the existing Receiving finalization transaction changes stock and creates FIFO layers. Receiving stores actual cost; the PO keeps expected cost.

Receiving records use a local `RCV-000001` sequence. Existing records receive numbers during the additive schema 38 migration, ordered by their original insertion order. The supplier invoice/reference is a document identifier, not an accounts payable entry. A repeated nonblank reference is checked within the same supplier; managers and owners may confirm an intentional reuse.

An open sent PO is overdue after the local calendar date of its expected delivery, provided quantity remains. Draft, fully received, cancelled, and closed orders are not overdue. The received cost comparison uses only quantities linked to PO lines across finalized Receivings. It compares the original expected unit cost with actual receiving unit cost for those quantities; unplanned receipt lines are excluded.

Copying a PO creates a new draft with the supplier and ordered lines. It does not carry receipt history, PO status, expected delivery date, quotation notes, or quotation source links. New quotation sourcing creates a durable link per PO line with fixed planned quantity. Legacy quotation notes remain plain text and do not establish a relational source link.

Supplier lead time is measured in calendar days from PO `sentAt` to the first recorded Receiving date. Completion uses the last Receiving date only for fully received or closed POs. Drafts and negative/backdated intervals are excluded. First-delivery performance compares that first Receiving date with the expected delivery calendar date: earlier is Early, the same day is On time, later is Late. The supplier profile displays an average or rate only after at least two observations. These are operational measures, not inventory valuation or supplier scores. Recent cost changes use actual Receiving unit costs.

PO and Goods Received Note PDFs use the existing PDF/printing packages. Draft POs are marked DRAFT. The documents show business references and avoid database IDs.

## Traceability verification

1. Create a quotation with a stock shortage and create a PO from its sourcing action. Edit the PO note. The quotation detail should still list the PO with planned, received, and incoming quantities; the PO line should still show the quotation source.
2. Receive part of the PO, click its RCV reference in the PO, then use **View Purchase Order** from the Receiving detail. A direct Receiving should say **Direct receiving** and show no PO action.
3. Open the supplier profile after at least two sent POs with deliveries. Check calendar-day first and completion averages, the first-delivery on-time rate, and recent actual cost changes. Drafts do not contribute to lead time.
4. Print or save a Draft PO and a finalized Goods Received Note. Check business and supplier details, human references, quantities, costs, and the DRAFT label where applicable. No database IDs should appear.

Managers and owners can create drafts, edit drafts, mark orders sent, and receive stock. Owners can cancel open orders with a required reason or close fully received orders. Sent commercial details are locked. A cancelled order retains finalized Receiving history and cancels only its remaining quantities. Receiving has no draft or reversal operation in the current application; it finalizes immediately and atomically.

Incoming quantity is the remaining quantity of sent or partially received orders. It is planning information and is not part of physical or available stock. PO numbers use a separate local sequence from invoices, receipts, and quotations. Duplicate product lines are rejected so a receipt can link unambiguously to a PO line. Serial numbers, batch and expiry values, and any layer selling price are captured during Receiving.

## Manual verification

1. Create supplier **ABC Distribution** and **Product A** with zero stock.
2. Create a PO for 10 Product A at expected cost ₱500, then mark it sent. Confirm on hand is 0, incoming is 10, and no inventory movement, expense, or cash movement exists for the PO.
3. Open **Receive Stock** on the PO. Receive 4 at actual cost ₱520 and finalize. Confirm on hand is 4, incoming is 6, PO status is Partially received, and the first FIFO layer is 4 at ₱520.
4. Receive the remaining 6 at actual cost ₱515. Confirm on hand is 10, incoming is 0, PO status is Fully received, and FIFO layers are 4 at ₱520 followed by 6 at ₱515. Sell stock and confirm existing FIFO allocation behavior.
5. In a separate run, receive 4 of 10 and cancel the order with a reason. Confirm received is 4, cancelled is 6, incoming is 0, and the received layer remains.
6. Back up after a partial receipt, finalize another receipt, then restore according to the existing backup flow. Confirm the PO, lines, receipt links, and partial progress match the restored point in time.

POs do not create supplier payments, Accounts Payable, expense records, or accounting journal entries. The quotation sourcing action can prefill a PO but does not mark a quotation ready; stock must still be received.

## Receiving screen checks

1. For **PO-000001**, order 10 Product A. Open **Receive Stock**. Product A should already be in **Items received**, with receive quantity 10 and expected cost shown. Change quantity to 4 and actual cost to ₱520, then **Finalize Receiving**. Check on hand 4, received 4, remaining 6, Partially received, and a FIFO layer of 4 at ₱520.
2. Open **Receive Stock** again. Product A should preload with remaining quantity 6. Set actual cost to ₱515 and finalize. Check on hand 10, Fully received, incoming 0, and FIFO layers of 4 at ₱520 and 6 at ₱515.
3. For a separate PO, order Product A quantity 5 and Product B quantity 3. Open **Receive Stock** and confirm both lines preload. Set B to 0, then use **Add unplanned item** for Product C quantity 2. Finalize. Check A stock +5, B stock +0, C stock +2; B remains open with 3 ordered and 3 remaining.
4. Before finalizing, try ESC and Cancel. Confirm neither changes stock or PO progress. Try a PO quantity above its remainder; the form should reject it before confirmation.
