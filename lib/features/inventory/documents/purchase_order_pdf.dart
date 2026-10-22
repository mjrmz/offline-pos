import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/quantity.dart';
import '../../../core/services/business_logo_store.dart';
import '../../../data/database.dart';
import '../../../data/daos/purchase_order_repository.dart';

class PurchaseOrderPdf {
  final AppDatabase db;
  const PurchaseOrderPdf(this.db);

  static String filename(PurchaseOrder order) =>
      '${PurchaseOrderRepository.number(order)}.pdf';

  Future<Uint8List> render(String orderId) async {
    final detail = await PurchaseOrderRepository(db).detail(orderId);
    final order = detail.order;
    final supplier = await (db.select(db.suppliers)
          ..where((s) => s.id.equals(order.supplierId)))
        .getSingle();
    final products = {
      for (final product in await db.select(db.products).get())
        product.id: product
    };
    final users = {
      for (final user in await db.select(db.users).get()) user.id: user.name
    };
    final settings = await db.select(db.settings).getSingleOrNull();
    pw.MemoryImage? logo;
    try {
      final file = await BusinessLogoStore().load();
      if (file != null) logo = pw.MemoryImage(await file.readAsBytes());
    } catch (_) {
      // A missing optional logo does not prevent a purchase order document.
    }
    final font =
        pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans.ttf'));
    final pdf = pw.Document(
        title: 'Purchase Order ${PurchaseOrderRepository.number(order)}',
        theme: pw.ThemeData.withFont(base: font, bold: font));
    String date(DateTime? value) => value == null
        ? 'Not set'
        : '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    String money(int cents) => '₱${(cents / 100).toStringAsFixed(2)}';
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (logo != null) ...[
            pw.Image(logo, width: 54, height: 54),
            pw.SizedBox(width: 10),
          ],
          pw.Expanded(
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                pw.Text(
                    settings?.storeName.isNotEmpty == true
                        ? settings!.storeName
                        : 'Business',
                    style: pw.TextStyle(
                        fontSize: 17, fontWeight: pw.FontWeight.bold)),
                if (settings?.storeAddress.isNotEmpty == true)
                  pw.Text(settings!.storeAddress),
                if (settings?.storeContact.isNotEmpty == true)
                  pw.Text(settings!.storeContact),
              ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('PURCHASE ORDER',
                style:
                    pw.TextStyle(fontSize: 19, fontWeight: pw.FontWeight.bold)),
            pw.Text(PurchaseOrderRepository.number(order)),
            if (order.status == 'draft')
              pw.Text('DRAFT',
                  style: pw.TextStyle(
                      color: PdfColors.red700, fontWeight: pw.FontWeight.bold)),
          ]),
        ]),
        pw.SizedBox(height: 20),
        pw.Text('Supplier: ${supplier.name}',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        if (supplier.contact?.isNotEmpty == true)
          pw.Text('Contact: ${supplier.contact}'),
        if (supplier.phone?.isNotEmpty == true)
          pw.Text('Phone: ${supplier.phone}'),
        if (supplier.address?.isNotEmpty == true)
          pw.Text('Address: ${supplier.address}'),
        pw.SizedBox(height: 10),
        pw.Text('Order date: ${date(order.orderDate)}'),
        pw.Text('Expected delivery: ${date(order.expectedDeliveryDate)}'),
        pw.Text('Status: ${detail.status.replaceAll('_', ' ')}'),
        pw.Text('Prepared by: ${users[order.createdBy] ?? 'Unknown / legacy'}'),
        pw.SizedBox(height: 20),
        pw.TableHelper.fromTextArray(
          headers: ['Product', 'Qty', 'Expected / unit', 'Line total'],
          data: [
            for (final line in detail.lines)
              [
                products[line.productId]?.name ?? 'Product',
                Quantity.format(line.orderedQtyMilli),
                money(line.expectedUnitCostCents),
                money(Quantity.lineCents(
                    line.expectedUnitCostCents, line.orderedQtyMilli)),
              ]
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 12),
        pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Expected total: ${money(detail.estimatedTotal)}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
        if (order.notes?.isNotEmpty == true) ...[
          pw.SizedBox(height: 16),
          pw.Text('Notes', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.Text(order.notes!),
        ],
      ],
    ));
    return pdf.save();
  }
}
