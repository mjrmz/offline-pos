# Dual-Screen Customer Display

A real, fully-supported feature (Phase 9) — not a minor afterthought. Many
competitor POS terminals at this price point support this; it's part of the
"worth more than the competition" pitch, and part of looking like a serious,
professional product in a live demo.

## What it is

Some POS hardware has two screens: a front touchscreen for the cashier, and
a rear customer-facing screen that shows the customer their order and total
as it's rung up — no input needed on that side, purely informational.

## Target hardware

- All-in-one dual-screen POS terminals (e.g. 15" touch front + secondary
  LCD/customer display rear) — common from PH suppliers like Bismac,
  KwikPOS, VMAXPOS — see docs/EQUIPMENT_SOURCING.md
- Desktop PC + separate touch monitor + second monitor, assembled from parts
- Single-screen devices (most tablets, budget terminals) — the feature
  simply doesn't activate; must degrade gracefully, never error

## How it's built

- Flutter desktop multi-window support (`desktop_multi_window` plugin or
  the engine's multi-view APIs) — the main POS window runs on the
  cashier's touch monitor, a second lightweight window renders on the
  customer-facing monitor
- Both windows run in the same app process, so app state (cart, running
  total) is shared directly — no separate sync mechanism needed for the
  same-machine, two-monitor case
- Customer display content: cart items, running total, "Please pay ₱XXX,"
  idle/promo screen when no sale is in progress
- Must detect whether a second display is connected and simply not launch
  the second window if not — this is the common case for most customers,
  not the exception

## Platform notes

- This is a desktop-only feature for v1 (Windows) — tablets/phones
  generally can't drive a second independent display without an external
  device, which is a different, more complex problem (local network sync
  between two separate devices) and is not in scope for v1
- A future "tablet + separate customer-display device" version would need
  local WebSocket/mDNS sync between two devices — deferred, not part of
  Phase 9

## Exit criteria (Phase 9)

Tested on an actual dual-screen terminal, cart and total sync live and
correctly with the main till, and the app runs correctly with no errors on
single-screen hardware where the feature simply doesn't apply.
