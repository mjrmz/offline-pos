# Hardware Integration

All hardware access lives behind interfaces in `lib/hardware/`, so the rest
of the app never needs to know which platform or peripheral it's talking to.

## Receipt printers (58mm / 80mm thermal)

- Communicate via ESC/POS commands.
- The Phase 4 software supports the following printer transports on its
  current Android and Windows targets:

  | Platform | LAN (raw TCP ESC/POS) | USB | Bluetooth |
  |---|---|---|---|
  | Windows | Supported | Supported via a selected Windows printer queue | Unsupported |
  | Android | Supported | Unsupported by the selected printer package | Supported for a paired ESC/POS printer |

- The receipt model and ESC/POS encoder are shared across transports. The
  configured transport also sends the cash-drawer kick command.
- Flow: complete the database transaction and commit the sale **first**,
  then attempt to print. If the printer is disconnected or fails:
  - The sale still stands (it's already committed).
  - Show "Sale completed. Receipt could not be printed." with a
    **Reprint** action.
  - Never gate sale completion on a successful print.

## Cash drawer

- Typically triggered via the same ESC/POS connection as the printer
  (a "kick drawer" command), not a separate integration.

## Barcode scanners

- Most USB and Bluetooth barcode scanners behave like keyboard input —
  scan → text input → lookup, no special driver needed.
- Also support manual barcode entry as a fallback (scanner disconnected,
  damaged barcode, etc.).
- On Android mobile/tablet without a physical scanner, camera scanning is an
  alternative input method. Its result uses the same barcode lookup and cart
  path as typed and keyboard-emulation scanner input.

## Platform notes

- **Android and Windows**: the matrix above describes implemented printer
  software paths. Each path still requires testing with actual printer and
  drawer models before the Phase 4 exit criterion is met.
- **iOS/macOS/Linux**: peripheral support is part of the later cross-platform
  rollout; the Phase 4 printer matrix does not claim support on those targets.

## Digital weighing scale (weight-based pricing toggle)

- Feeds directly into checkout for weight-based products (rice, grains,
  feeds/agri) instead of manual weight entry
- Same integration pattern as the printer/scanner: USB, Bluetooth, or
  serial connection, behind an interface in `hardware/scale/`
- Manual weight entry remains available as a fallback — a scale isn't
  assumed to be present, same as the barcode scanner's manual-entry
  fallback
- Testing checklist addition: scale disconnected mid-sale falls back to
  manual entry without blocking checkout

## Testing checklist

- ✓ Printer disconnected mid-sale
- ✓ Printer runs out of paper
- ✓ Scanner disconnected — manual entry fallback works
- ✓ Scale disconnected — manual weight entry fallback works
- ✓ Cash drawer trigger fires correctly on cash sales
- ✓ Reprint produces an identical receipt to the original
# Phase 7 receipt data

For a numbered BIR-ready sale, the existing receipt renderer includes the
persisted integer invoice number. Reprints read that number from the stored
Sale row. The printer and cash drawer still run only after sale commit, so
hardware failure cannot advance invoice or grand-total state. Non-BIR sale
receipts continue to use the existing sale reference.
