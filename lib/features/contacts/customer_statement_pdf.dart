import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/daos/receivables_reporting_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';

class CustomerStatementPdf {
  const CustomerStatementPdf(this.db);
  final AppDatabase db;

  Future<Uint8List> render(
      String customerId, DateTime start, DateTime end) async {
    final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(customerId)))
        .getSingle();
    final settings = await db.select(db.settings).getSingleOrNull();
    final reporting = ReceivablesReportingRepository(db);
    final first = await reporting.statementPage(customerId, start, end);
    final lines = <StatementLine>[...first.lines];
    final pages = (first.summary.count + 49) ~/ 50;
    for (var page = 1; page < pages; page++) {
      lines.addAll(
          (await reporting.statementPage(customerId, start, end, page: page))
              .lines);
    }
    final bytes = await rootBundle.load('assets/fonts/NotoSans.ttf');
    final font = pw.Font.ttf(bytes);
    final pdf = pw.Document();
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => [
              pw.Text(
                  settings?.storeName.isNotEmpty == true
                      ? settings!.storeName
                      : 'Customer Statement',
                  style: pw.TextStyle(
                      fontSize: 16, fontWeight: pw.FontWeight.bold)),
              if (settings?.storeAddress.isNotEmpty == true)
                pw.Text(settings!.storeAddress),
              if (settings?.storeContact.isNotEmpty == true)
                pw.Text(settings!.storeContact),
              pw.SizedBox(height: 12),
              pw.Text('Customer Statement',
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.Text('Customer: ${customer.name}'),
              pw.Text(
                  'Period: ${date(start)} to ${date(end.subtract(const Duration(days: 1)))}'),
              pw.Text('Generated: ${date(DateTime.now())}'),
              pw.SizedBox(height: 12),
              pw.Text(
                  'Opening ${formatPeso(first.summary.openingCents)}   New credit ${formatPeso(first.summary.chargesCents)}'),
              pw.Text(
                  'Payments ${formatPeso(first.summary.paymentsCents)}   Adjustments ${formatPeso(first.summary.adjustmentsCents)}'),
              pw.Text(
                  'Closing balance ${formatPeso(first.summary.closingCents)}',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 12),
              pw.TableHelper.fromTextArray(
                headers: [
                  'Date',
                  'Reference',
                  'Description',
                  'Charge',
                  'Payment/Credit',
                  'Balance'
                ],
                data: [
                  for (final line in lines)
                    [
                      date(line.date),
                      line.reference,
                      line.description,
                      line.chargeCents == 0 ? '' : formatPeso(line.chargeCents),
                      line.paymentCreditCents == 0
                          ? ''
                          : formatPeso(line.paymentCreditCents),
                      formatPeso(line.balanceCents)
                    ]
                ],
                cellStyle: pw.TextStyle(font: font, fontSize: 8),
                headerStyle: pw.TextStyle(
                    font: font, fontSize: 8, fontWeight: pw.FontWeight.bold),
              ),
            ]));
    return pdf.save();
  }
}
