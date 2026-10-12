# Offline RMA

## Implemented now

The local Drift/SQLite database is authoritative. New customer requests use a
completed POS sale item and exact sold serial where applicable. Source search
matches receipt, customer, phone, product, SKU, barcode, and serial. Customer
and supplier references are `RMA-YYYY-NNNNNN` and `SRMA-YYYY-NNNNNN`.
New sales use the operational `POS-` receipt reference for source lookup;
the BIR invoice number remains a separate searchable identifier. Sales History
can open the customer RMA wizard with the source receipt filled in. Existing
RMA eligibility and serial validation still apply.

Schema 22 adds `rma_lifecycle_events`. Each event has actor, timestamp, action,
and structured scope or evidence. Old `rma_events` and `rma_cases` remain
intact. No receipt, inspection, custody, or handoff is backfilled for legacy
claims. A new customer claim is marked by its `requested` lifecycle event;
the old combined `transition` rejects it.
Schema 23 adds append-only serialized warranty snapshots. Existing sale and
RMA history is preserved; missing old warranty facts remain unknown.

For new customer claims, approval is separate from receipt. Rejection requires
a reason before approval; cancellation requires a reason and is blocked after
receipt or irreversible action. Receipt is bounded by the claimed quantity and
does **not** increase sellable stock. Matching serialized receipt changes the
sold serial to the non-sellable `rma` state. A mismatched physical serial is
stored separately from the expected serial; an owner must supply an override
reason. The expected serial remains sold when the physical serial differs.
Receipt records store custody. Inspection is bounded by received quantity and
keeps the technician finding separate from the reported issue.

Resolution intent stores customer outcome separately from physical disposition.
It has no cash or stock effect. Refund posting calls the existing Sales
repository, including its cash session and obligation rules. An unpaid
customer obligation remains pending until its ledger settlement is confirmed;
authorization alone never deducts cash. Restock requires
an inspected eligible condition and restores the original
`SaleItemInventoryAllocation` layer; scrap never adds sellable stock. Execution
and completion are guarded against repetition. A serialized replacement is
reserved by exact `SerialUnit`, excluded from POS availability, releasable
before handoff, and consumed only at the customer handoff. Handoff records the
recipient and exact serial. Completion is derived after the required refund or
handoff and physical disposition facts exist.

An inspected customer claim with supplier disposition can open a linked
Supplier RMA only when the original receiving provenance is unambiguous. The
supplier comes from `InventoryLayer`/`SerialUnit` and receiving, never a
preferred supplier. Supplier decision is a separate event from fulfillment.
Actual supplier credit and serialized replacement fulfillment are recorded;
the newly received supplier replacement is quarantined from sellable stock;
neither automatically resolves the customer claim. Duplicate replacement
serials are rejected by Inventory receiving.

## UI state

The RMA workspace now has Customer RMAs and Supplier RMAs tabs, a searchable
queue with lifecycle-derived stages, and a full case detail page. Customer
creation uses a four-step wizard: find transaction, select item/unit, claim
details, review/create. New customer requests call `RmaLifecycleRepository`.
The detail page shows progress, a next action, returned-item custody, separate
reported issue and inspection finding, customer outcome versus physical
disposition, refund pending versus completed, exact replacement serial, and a
readable lifecycle timeline. Supplier cases appear in the same module with
receiving provenance and decision/fulfillment progress. Direct supplier intake
is available from the Supplier RMAs tab. It selects an exact available serial
from Receiving, or a non-serialized Receiving item with one authoritative
inventory layer. Intake quarantines stock and records a `supplier_intake`
lifecycle fact. Sending to the supplier, its decision, and fulfillment remain
separate facts. No customer is required. A linked Supplier RMA can also be
opened from an eligible inspected customer resolution. Legacy claims remain visible with an
explicit physical-history limitation. Operations continues to count open
`rma_cases`. SQLite backup includes lifecycle events automatically.

The workspace has compact customer summary metrics, search and filters, and a
separate supplier queue. Routine approval, receipt, inspection, resolution,
supplier sending, and supplier decisions use the contextual detail panel.
Customer handoff and supported supplier fulfillment use dedicated responsive
dialogs. Supplier creation uses a four-step wizard for source, exact item or
unit, claim details, and review. It supports eligible linked customer claims
and direct defective Receiving stock. Hold execution remains unavailable.
Manual 1366x768, mobile, and theme checks remain open.

### RMA workspace

The page shows compact customer open, inspection, and supplier counts. Customer
RMAs have text search and lifecycle stage filters. Supplier RMAs have their own
queue and create action. Aging & attention lists customer claims awaiting
suppliers, and Reports shows case counts. Supplier SLA overdue counts and
editable policy Settings are not implemented in this workspace.

### Customer RMA wizard

The four-step wizard finds a completed sale item, selects one returnable line or
exact sold serial, records the reported issue and notes, and reviews the claim.
Source search has initial, loading, empty, error, and retry states. One case is
still one sale line or serial. Claim type is not persisted, so this UI does not
pretend to create a separate warranty policy snapshot.

### Customer detail

The persistent detail shows six compact progress stages and a contextual action
panel alongside claim, item, custody, fulfillment, and supplier recovery facts.
The timeline is collapsed by default and shows actor, local time, and notes.
Linked supplier claims open directly from the detail.

### Receipt

Physical receipt is inline. It shows approved, received, and remaining
quantities, with a valid remaining quantity prefilled. Serialized claims require
the physical serial; a mismatch shows both identities and opens an Owner reason
dialog. Receipt does not restore sellable stock.

### Inspection

Inspection is inline. It bounds quantity to received stock, shows exact
original and returned serials, uses a condition picker and explicit Yes, No,
and Not tested choices, and shows validation in the action panel. Successful
inspection refreshes the same detail.

### Resolution

Resolution selection, applicable details, disposition, and review stay in the
action panel. Refund, serialized replacement, supplier warranty, no-fault, and
rejected-claim outcomes are offered where supported. Authorization does not post
cash or stock. Physical disposition and refund execution remain separate
lifecycle actions. Hold execution is not offered as successful completion.

### Handoff

Handoff uses a dedicated responsive dialog for recipient, released serial,
time, notes, and warranty treatment. A serialized handoff appends a warranty
snapshot. Continue original is the default and copies documented original
dates. If no original warranty fact exists, it records Legacy / unknown rather
than inventing an expiry. Restart and custom require an explicit future end
date. No warranty records a terminal no-warranty fact. Original sale history
is never changed. Restart, custom, and no-warranty customer overrides require
Owner authorization; managers can continue the original warranty.

### Supplier RMA wizard

The four-step wizard chooses an eligible inspected Customer RMA or defective
Receiving stock, selects the exact source item/unit, enters claim details, and
reviews before creation. Direct intake requires no customer. Ambiguous
non-serialized provenance is blocked by the repository.

### Supplier detail and fulfillment

Supplier detail shows its own progress, Receiving provenance, contextual action,
decision, and fulfillment facts. Its queue distinguishes awaiting shipment,
supplier review, fulfillment, and fulfilled states. Direct and linked claims
send inline; supplier decisions are also recorded inline. Credit and serialized
replacement fulfillment use dedicated dialogs. Repaired
original, no-fault original, and rejected original returns require the exact
existing serial and record store custody. A rejected supplier item then needs
documented hold, scrap, restock if eligible, or customer return disposition.
Repaired or no-fault originals that belong to the business also need an
explicit hold, scrap, or eligible restock action. Supplier decisions never imply that
inventory or customer obligations have been fulfilled.

### Cross-linking

Linked customer and supplier cases show a direct navigation row on both detail
pages. Customer completion follows the customer obligation. A refund can
complete the Customer RMA while a linked Supplier RMA remains open. An
immediate store replacement completes after exact-serial handoff. Supplier
recovery is shown separately with its own status and link. When the item still
needs to be sent, the completed customer detail links to the Supplier RMA's
Ready to send action. Authorization creates the linked claim from Receiving
provenance in Ready to send state. Sending is an inline supplier-detail action
that records the distinct physical shipment and changes custody to supplier.

The supplier warranty customer path keeps the customer case open after sending.
A received supplier replacement gets a new SerialUnit identity and is held
outside sellable inventory for that customer. Handoff requires that exact new
serial. For a direct Inventory Supplier RMA or an already satisfied customer,
the new supplier replacement remains store inventory. The original sold,
returned, store replacement, supplier replacement, and final handoff serials
remain distinct. Supplier replacement fulfillment also records supplier
warranty treatment, defaulting to Unknown / not provided. Customer handoff
records its own warranty fact.

Both creation wizards open in a centered large dialog on desktop and a full
screen route on narrow devices. Dialog bodies scroll while their header and
actions remain visible. Case detail also opens as a large desktop dialog and a
full screen route on narrow devices.

## Detail workspace

Customer and Supplier RMA details use a persistent workspace. The reference
appears once as the page heading, beside a status derived from lifecycle facts.
Six connected progress markers sit below it. At desktop widths, a capped
1600-pixel detail uses a roughly 66/34 split: the left scroll area shows
compact claim and item rows, fulfillment, supplier recovery, and a vertical
activity and custody timeline; the subtly tinted right scroll area keeps the
current step in view. Supplier detail separates source, decision, fulfillment,
and customer impact.
On narrow screens the action panel appears above the details. Approval,
ordinary receipt, inspection, resolution selection and review, supplier send,
and supplier decision happen in that panel. Successful actions refresh the
same detail and queue projections. Validation errors stay beside the form.
Serial mismatch override, rejection, exact replacement selection, supplier
fulfillment, refund execution, and final customer handoff retain confirmation
dialogs. Passive waiting and completed states have no primary action button.

## Deferred

One case still represents one sale line or serial. Multi-item parent claims,
per-item approval, and mixed-stage parent completion are not implemented.
Return policy, store-credit issuance,
non-serialized replacement reservations, upgrade exchange, customer hold
execution, supplier SLA, and optional local
file evidence remain unimplemented. Supplier fulfillment differences need a
separate override path. Legacy `openCustomer` and `transition` still serve old
records/tests; the app's new customer creation path uses lifecycle events.

The current `rma` serial state is non-sellable. A mismatched returned serial
has custody evidence but no invented `SerialUnit` identity. Such property is
not restocked as the expected unit. No legacy physical facts are inferred from
old status values.

## Manual verification

Check normal and warranty returns; expired policy and override once added;
exact and mismatched serials; partial receipt and inspection; refund intent,
cash payout and obligation settlement; replacement reservation, release,
reselection and handoff; supplier credit, replacement and rejection; no-fault
handoff; restock and scrap; opening stock and missing/ambiguous provenance;
legacy and mixed-stage cases; backup/restore and restart with open claims;
light/dark/system themes and narrow layout. Manual verification remains open.
