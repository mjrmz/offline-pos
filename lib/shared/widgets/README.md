# shared/widgets/

Reusable workspace components live in `app_workspace.dart`: page headers, tabs,
metrics, search, filters, semantic status badges, entity rows, bounded list
containers, pagination, and empty/loading/error states. The list panel expects
the caller to supply a 50-row page and a filtered total. It hides pagination
controls for a single page. Search and filter changes must reset the caller's
page index to zero.

`record_details_drawer.dart` provides the shared record drawer.
`app_confirm_dialog.dart` provides the destructive confirmation pattern.
`app_feedback.dart` replaces the current transient snackbar before showing a
new three-second message.

Layaway and directory screens query their 50-row pages from SQLite. Quotation
and RMA lists still filter loaded records because their filters include derived
stock and product data. They must not be treated as database-paged until those
predicates are represented in repository queries. Quotation list metadata now
loads items and receipt numbers in bounded batches.
