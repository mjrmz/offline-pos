import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/quantity.dart';
import '../../../core/services/business_logo_store.dart';
import '../../../data/database.dart';
import '../../../data/daos/purchase_order_repository.dart';
import '../../../data/daos/stock_receiving_repository.dart';

class ReceivingPdf {
  final AppDatabase db;
  const ReceivingPdf(this.db);

  static String filename(StockReceiving receipt) =>
      '${StockReceivingRepository.number(receipt)}.pdf';

  Future<Uint8List> render(String receiptId) async {
    final receipt = await (db.select(db.stockReceivings)
          ..where((r) => r.id.equals(receiptId)))
        .getSingle();
    final items = await StockReceivingRepository(db).items(receiptId);
    final supplier = await (db.select(db.suppliers)
          ..where((s) => s.id.equals(receipt.supplierId)))
        .getSingle();
    final products = {
      for (final p in await db.select(db.products).get()) p.id: p
    };
    final users = {
      for (final u in await db.select(db.users).get()) u.id: u.name
    };
    final settings = await db.select(db.settings).getSingleOrNull();
    final order = receipt.purchaseOrderId == null
        ? null
        : await PurchaseOrderRepository(db).detail(receipt.purchaseOrderId!);
    pw.MemoryImage? logo;
    try {
      final file = await BusinessLogoStore().load();
      if (file != null) logo = pw.MemoryImage(await file.readAsBytes());
    } catch (_) {}
    final font =
        pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans.ttf'));
    final pdf = pw.Document(
        title: 'Receiving ${filename(receipt)}',
        theme: pw.ThemeData.withFont(base: font, bold: font));
    String date(DateTime value) =>
        '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    String money(int cents) => '₱${(cents / 100).toStringAsFixed(2)}';
    final total = items.fold<int>(
        0,
        (sum, item) =>
            sum + Quantity.lineCents(item.unitCostCents, item.quantityMilli));
    pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => [
              pw.Row(children: [
                if (logo != null) ...[
                  pw.Image(logo, width: 50, height: 50),
                  pw.SizedBox(width: 10)
                ],
                pw.Expanded(
                    child: pw.Text(
                        settings?.storeName.isNotEmpty == true
                            ? settings!.storeName
                            : 'Business',
                        style: pw.TextStyle(
                            fontSize: 17, fontWeight: pw.FontWeight.bold))),
                pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('GOODS RECEIVED NOTE',
                          style: pw.TextStyle(
                              fontSize: 17, fontWeight: pw.FontWeight.bold)),
                      pw.Text(StockReceivingRepository.number(receipt)),
                    ]),
              ]),
              pw.SizedBox(height: 20),
              pw.Text('Supplier: ${supplier.name}'),
              pw.Text(
                  'Supplier invoice / reference: ${receipt.externalReference ?? 'Not set'}'),
              pw.Text(
                  'Purchase Order: ${order == null ? 'Direct receiving' : PurchaseOrderRepository.number(order.order)}'),
              pw.Text('Received date: ${date(receipt.receivedAt)}'),
              pw.Text(
                  'Finalized by: ${users[receipt.userId] ?? 'Unknown / legacy'}'),
              if (receipt.finalizedAt != null)
                pw.Text('Finalized date: ${date(receipt.finalizedAt!)}'),
              pw.SizedBox(height: 16),
              pw.TableHelper.fromTextArray(headers: [
                'Product',
                'Received qty',
                'Actual / unit',
                'Line total'
              ], data: [
                for (final item in items)
                  [
                    products[item.productId]?.name ?? 'Product',
                    Quantity.format(item.quantityMilli),
                    money(item.unitCostCents),
                    money(Quantity.lineCents(
                        item.unitCostCents, item.quantityMilli)),
                  ]
              ], headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text('Total actual cost: ${money(total)}',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
              if (receipt.notes?.isNotEmpty == true) ...[
                pw.SizedBox(height: 12),
                pw.Text('Notes: ${receipt.notes}'),
              ],
            ]));
    return pdf.save();
  }
}
