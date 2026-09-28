# Hardware Integration

All hardware access lives behind interfaces in `lib/hardware/`, so the rest
of the app never needs to know which platform or peripheral it's talking to.

## Receipt printers (58mm / 80mm thermal)

- Communicate via ESC/POS commands.
- Support USB, Bluetooth, and network (LAN) printers depending on what's
  common in-market — USB and Bluetooth are the most likely for small PH
  retail shops.
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
- On mobile/tablet without a physical scanner, support camera-based
  scanning as an alternative input method.

## Platform notes

- **Android/iOS**: most mature ecosystem for POS peripherals — favor this
  platform for early hardware testing.
- **Windows/macOS/Linux desktop**: test explicitly with the actual printer
  and scanner models you intend to support before launch — desktop
  peripheral support in Flutter is less traveled than mobile.

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
