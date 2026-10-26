# Barcode aliases (Phase N1)

Each product keeps its primary barcode. Optional aliases are additional exact
lookup keys for the same product. They do not carry prices or quantities.

In the Product CSV template, `barcode_aliases` uses `|` between codes, for
example `111111|222222|ABC-OLD`. Whitespace around each code is trimmed.
On update, nonblank aliases merge with existing aliases. A blank cell leaves
them unchanged. Existing aliases are never removed by import. Disable an alias
in the Product detail drawer if it should stop resolving in checkout.

Barcode matching is case sensitive, as for the existing primary barcode.
The database reserves inactive aliases too, so an old code cannot be assigned
to another product accidentally. Package quantities are outside Phase N1.
