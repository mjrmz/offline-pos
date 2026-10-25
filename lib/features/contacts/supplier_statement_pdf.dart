import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/database.dart';
import '../../data/daos/supplier_payables_repository.dart';
import '../../shared/utils/money.dart';

class SupplierStatementPdf {
  const SupplierStatementPdf(this.db);
  final AppDatabase db;

  Future<Uint8List> render(String supplierId, DateTime start, DateTime end) async {
    final supplier = await (db.select(db.suppliers)
          ..where((s) => s.id.equals(supplierId))).getSingle();
    final settings = await db.select(db.settings).getSingleOrNull();
    final repository = SupplierPayablesRepository(db);
    final first = await repository.statementPage(supplierId, start, end);
    final lines = <SupplierLedgerEntry>[...first.lines];
    for (var page = 1; page * 50 < first.summary.count; page++) {
      lines.addAll((await repository.statementPage(supplierId, start, end,
          page: page)).lines);
    }
    final fontBytes = await rootBundle.load('assets/fonts/NotoSans.ttf');
    final font = pw.Font.ttf(fontBytes);
    final pdf = pw.Document();
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final summary = first.summary;
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 1000,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (_) => [
        pw.Text(settings?.storeName.isNotEmpty == true
            ? settings!.storeName : 'Supplier Statement',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        if (settings?.storeAddress.isNotEmpty == true)
          pw.Text(settings!.storeAddress),
        if (settings?.storeContact.isNotEmpty == true)
          pw.Text(settings!.storeContact),
        pw.SizedBox(height: 12),
        pw.Text('Supplier Statement', style: pw.TextStyle(
            fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.Text('Supplier: ${supplier.name}'),
        pw.Text('Period: ${date(start)} to ${date(end.subtract(const Duration(days: 1)))}'),
        pw.Text('Generated: ${date(DateTime.now())}'),
        pw.SizedBox(height: 12),
        pw.Text('Opening balance: ${formatPeso(summary.openingCents)}'),
        pw.Text('Receiving charges: ${formatPeso(summary.chargesCents)}'),
        pw.Text('Supplier credits: ${formatPeso(summary.creditsCents)}'),
        pw.Text('Payments: ${formatPeso(summary.paymentsCents)}'),
        pw.Text('Closing balance: ${formatPeso(summary.closingCents)}',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        if (summary.unappliedCreditCents > 0)
          pw.Text('Current unapplied supplier credit: '
              '${formatPeso(summary.unappliedCreditCents)}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: const ['Date', 'Reference', 'Description', 'Charge',
            'Payment/Credit', 'Balance'],
          data: [for (final line in lines) [
            date(line.date), line.reference, line.type,
            line.purchaseCents == 0 ? '' : formatPeso(line.purchaseCents),
            line.settlementCents == 0 ? '' : formatPeso(line.settlementCents),
            formatPeso(line.balanceCents),
          ]],
          cellStyle: pw.TextStyle(font: font, fontSize: 8),
          headerStyle: pw.TextStyle(font: font, fontSize: 8,
              fontWeight: pw.FontWeight.bold),
        ),
        if (summary.legacyCount > 0) ...[
          pw.SizedBox(height: 12),
          pw.Text('Historical Receiving records with unknown settlement status '
              'are excluded from collectible balances.'),
        ],
      ],
    ));
    return pdf.save();
  }
}
