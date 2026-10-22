import '../../core/services/sales_service.dart';
import '../cash_drawer/cash_drawer.dart';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import 'receipt.dart';
import 'receipt_printer.dart';
import 'package:drift/drift.dart' show Variable;

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

  Future<HardwareOutcome> afterCommittedCashSale(String saleId,
      {bool openDrawer = true}) async {
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
          ReceiptDocument.fromDetail(detail, settings.storeName, settings),
          settings);
      printed = true;
    } catch (_) {/* Sale is already committed. */}
    if (settings.drawerEnabled && openDrawer) {
      try {
        await drawer.open(settings);
        opened = true;
      } catch (_) {/* Independent post-commit outcome. */}
    }
    return HardwareOutcome(
        true, printed, settings.drawerEnabled && openDrawer, opened);
  }

  Future<bool> reprint(String saleId) async {
    try {
      final settings = await settingsStore.load();
      if (!settings.configured) return false;
      final detail = await sales.detail(saleId);
      await printer.print(
          ReceiptDocument.fromDetail(detail, settings.storeName, settings),
          settings);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> reprintReturn(String returnId) async {
    try {
      final settings = await settingsStore.load();
      if (!settings.configured) return false;
      final db = sales.repository.db;
      final rows = await db.customSelect(
          '''SELECT r.reference, r.kind, r.original_sale_id,
          r.refund_value_cents, r.replacement_value_cents, r.cash_effect_cents,
          r.created_at, s.receipt_number, replacement.receipt_number AS replacement_receipt,
          u.name AS actor_name
        FROM sale_returns r JOIN sales s ON s.id=r.original_sale_id
        JOIN users u ON u.id=r.actor_id
        LEFT JOIN sales replacement ON replacement.id=r.replacement_sale_id
        WHERE r.id=? AND r.status='finalized' ''',
          variables: [Variable.withString(returnId)]).get();
      if (rows.isEmpty) return false;
      final row = rows.single;
      await sales.detail(row.read<String>('original_sale_id'));
      final lines = await db.customSelect('''SELECT rl.id, rl.quantity_milli,
          rl.refund_cents, si.product_name, si.sale_unit, si.unit_price_cents
        FROM sale_return_lines rl JOIN sale_items si ON si.id=rl.sale_item_id
        WHERE rl.return_id=? ORDER BY rl.rowid''',
          variables: [Variable.withString(returnId)]).get();
      final receiptLines = <ReceiptLine>[];
      for (final line in lines) {
        final serialRows = await db.customSelect('''SELECT su.serial_number
          FROM sale_return_allocations ra JOIN serial_units su ON su.id=ra.serial_unit_id
          WHERE ra.return_line_id=? ORDER BY ra.rowid''',
            variables: [Variable.withString(line.read<String>('id'))]).get();
        final milli = line.read<int>('quantity_milli');
        receiptLines.add(ReceiptLine(
            line.read<String>('product_name'),
            milli ~/ 1000,
            line.read<int>('unit_price_cents'),
            line.read<int>('refund_cents'),
            quantityMilli: milli,
            unit: line.read<String>('sale_unit'),
            serialNumbers: serialRows
                .map((s) => s.read<String>('serial_number'))
                .toList()));
      }
      final original =
          row.readNullable<String>('receipt_number') ?? 'Legacy sale';
      final replacement = row.readNullable<String>('replacement_receipt');
      final cash = row.read<int>('cash_effect_cents');
      final isExchange = row.read<String>('kind') == 'exchange';
      final replacementValue = row.read<int>('replacement_value_cents');
      final document = ReceiptDocument(
          row.read<String>('reference'),
          DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
          row.read<String>('actor_name'),
          settings.storeName,
          receiptLines,
          row.read<int>('refund_value_cents'),
          isExchange
              ? (cash > 0
                  ? 'Customer paid difference'
                  : cash < 0
                      ? 'Customer refunded difference'
                      : 'Even exchange')
              : 'Cash refund',
          cash.abs(),
          null,
          settings.storeAddress,
          settings.storeContact,
          'COMMERCIAL ${isExchange ? 'EXCHANGE' : 'RETURN'}\nOriginal: $original${replacement == null ? '' : '\nReplacement: $replacement\nReplacement value: ${receiptMoney(replacementValue)}'}',
          settings.receiptFooter);
      await printer.print(document, settings);
      return true;
    } catch (_) {
      return false;
    }
  }
}
