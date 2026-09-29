import '../../core/services/sales_service.dart';
import '../cash_drawer/cash_drawer.dart';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import 'receipt.dart';
import 'receipt_printer.dart';

class HardwareOutcome {
  final bool printerAttempted;
  final bool printed;
  final bool drawerAttempted;
  final bool drawerOpened;
  const HardwareOutcome(this.printerAttempted, this.printed,
      this.drawerAttempted, this.drawerOpened);
}

class ReceiptService {
  final SalesService sales;
  final PrinterSettingsStore settingsStore;
  final ReceiptPrinter printer;
  final CashDrawer drawer;
  ReceiptService(this.sales, this.settingsStore, this.printer, this.drawer);

  Future<HardwareOutcome> afterCommittedCashSale(String saleId) async {
    PrinterSettings settings;
    try {
      settings = await settingsStore.load();
    } catch (_) {
      return const HardwareOutcome(false, false, false, false);
    }
    if (!settings.configured) {
      return const HardwareOutcome(false, false, false, false);
    }
    var printed = false;
    var opened = false;
    try {
      final detail = await sales.detail(saleId);
      await printer.print(
          ReceiptDocument.fromDetail(detail, settings.storeName), settings);
      printed = true;
    } catch (_) {/* Sale is already committed. */}
    if (settings.drawerEnabled) {
      try {
        await drawer.open(settings);
        opened = true;
      } catch (_) {/* Independent post-commit outcome. */}
    }
    return HardwareOutcome(true, printed, settings.drawerEnabled, opened);
  }

  Future<bool> reprint(String saleId) async {
    try {
      final settings = await settingsStore.load();
      if (!settings.configured) return false;
      final detail = await sales.detail(saleId);
      await printer.print(
          ReceiptDocument.fromDetail(detail, settings.storeName), settings);
      return true;
    } catch (_) {
      return false;
    }
  }
}
