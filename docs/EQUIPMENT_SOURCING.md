# Equipment Sourcing (Philippines)

This product is software-only — it installs on standard POS-class hardware
rather than requiring custom-built machines. This doc lists real supplier
options for reference and for testing hardware compatibility.

## Local suppliers

- **Bismac** (Makati, also Cebu/Bacolod/Iloilo/Davao) — touchscreen
  all-in-one POS terminals from 10.1" to 18.5", Intel Celeron J1900 up to
  i3/i5, running POS Ready 7 or Windows 10 IoT Enterprise, with separate
  2-line LCD or up to 15" customer displays, cash drawers, pole displays,
  POS keyboards.
- **CCS (Competitive Card Solutions Phils Inc.)** — 15" touch POS
  terminal, aluminum housing, ELO resistive touch panel, Intel Celeron
  1037U, 2GB RAM, 32-128GB SSD, sold without OS, 1-year warranty.
- **KwikPOS** — dual-screen 15" all-in-one terminals, 10-point capacitive
  touchscreen.
- **VMAXPOS** — dual-screen 15" all-in-one terminals, Intel Celeron (Bay
  Trail), multi-touch PCAP screens, dual-display with the second screen
  showing order details/payment/receipt to the customer.
- **Lazada / Shopee** — dual-screen integrated POS terminals available
  directly, useful for one-off purchases or price comparison; less
  consistent warranty/support than a dedicated local supplier.

## What to look for when testing/recommending hardware

- **Confirm Windows-based** (POS Ready 7 / Windows 10 IoT Enterprise) for
  desktop-class terminals — matches this product's primary desktop target
- **Note the RAM** — a lot of these ship at 2GB as standard, not an
  upgrade option, which is why low-spec (Celeron, 2GB RAM) is a hard
  testing requirement (see docs/ROADMAP.md Phase 12), not an edge case
- **Dual-screen models** — confirm the customer-facing display is a real
  second screen (not just a 2-line LCD/VFD) if you want the full
  docs/CUSTOMER_DISPLAY.md experience; the simpler LCD/VFD customer
  displays are a different, lower-effort integration (text-only, not a
  Flutter window) worth considering as a cheaper alternative for
  budget-conscious customers

## Sales model options

- **Software-only**: customer buys/owns their own terminal (from any of
  the above, or reuses an existing PC), you install and activate the
  license. Lower cost and inventory risk for you.
- **Bundled hardware + software**: buy terminals wholesale, pre-install
  and pre-activate, sell as a complete "till in a box." Higher upfront
  cost and inventory management, but a stronger sales pitch and likely
  better margin per sale.

This is a business/sales decision, not a technical constraint — the
product works the same either way.
