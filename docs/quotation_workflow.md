# Quotations

A quotation is a commercial offer. Saving it does not create a sale, payment,
cash movement, BIR invoice, stock reservation, serial allocation, batch
consumption, or FIFO inventory movement.

Quote lines persist the product name, SKU, barcode, quantity, unit, base selling
price, transaction mode, mode surcharge, and line total. The PDF uses these saved
values, so changing a catalog price or product name later does not rewrite the
offer. Historical lines from older databases receive the best available product
name, SKU, and barcode during migration. Older quotation references remain valid;
new references use `Q-YYYY-000001` format.

Open quotations can be edited. Updating quantity or notes retains the saved
unit price and customer-facing item identity for existing lines. Changing an
LPG/refill option recalculates only that option's surcharge. Converted and
cancelled quotations cannot be edited. The PDF always renders the latest saved
open-quote revision and keeps converted documents separate from sale receipts.

Customer name and phone, and the preparer's name, are also saved on the quote.
Older rows are backfilled from the available directory records during migration.

Tank products require an exchange or deposit choice on the quote. Refill products
require refill only or container plus refill. Made to order products carry their
existing made order mode. The quoted surcharge is saved with the line. Serialized
items quote a quantity without allocating specific units. Batch items quote a
quantity without consuming a lot. Weight products use the same integer
thousandths quantity model as checkout.

For inventory layer priced products, quotation uses the current catalog selling
price as a fixed commercial offer. It does not inspect or allocate FIFO layers
to derive a quote price. Conversion keeps that saved price while physical layer
consumption follows the existing FIFO implementation.

Conversion checks current sellability and stock. Serial and batch choices are
made during conversion. The sale transaction uses the saved quote prices and
modes; it marks the quote converted and links the sale only if that transaction
commits. Cancelling conversion leaves the quote open. Expired quotes remain
readable but cannot be converted under the existing policy.

The quotation PDF is a separate A4 customer document, generated locally from
persisted quotation rows. Preview, print, save, and share use the same rendered
bytes. On Windows, Send / Share saves the file to Downloads or application
documents if Downloads is unavailable. The document is never a POS receipt or
BIR invoice. Its business identity comes from Printer & Receipt settings, while
quotation field visibility and terms are configured under Settings > Quotation
template.

The PDF bundles Noto Sans from the Google Fonts repository under the SIL Open
Font License (see `assets/fonts/OFL.txt`), so customer names and peso amounts
render without a network request.
