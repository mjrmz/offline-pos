import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/models/quantity.dart';
import '../../../data/database.dart';

class QuotationPdf {
  final AppDatabase db;
  const QuotationPdf(this.db);

  static String safeFilename(String reference, String customer) {
    String clean(String value) => value
        .replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return 'Quotation-${clean(reference)}-${clean(customer)}.pdf';
  }

  Future<Uint8List> render(String quotationId) async {
    final quote = await (db.select(db.quotations)
          ..where((q) => q.id.equals(quotationId)))
        .getSingle();
    final items = await (db.select(db.quotationItems)
          ..where((i) => i.quotationId.equals(quotationId)))
        .get();
    final settings = await db.select(db.settings).getSingleOrNull();
    final template =
        await db.select(db.quotationDocumentSettings).getSingleOrNull();
    final status = quote.status == 'open' &&
            quote.validUntil != null &&
            quote.validUntil!.isBefore(DateTime.now())
        ? 'Expired'
        : '${quote.status[0].toUpperCase()}${quote.status.substring(1)}';
    final receipt = quote.convertedSaleId == null
        ? null
        : await (db.select(db.sales)
              ..where((s) => s.id.equals(quote.convertedSaleId!)))
            .getSingleOrNull();
    final fontBytes = await rootBundle.load('assets/fonts/NotoSans.ttf');
    final font = pw.Font.ttf(fontBytes);
    final document = pw.Document(
        title: 'Quotation ${quote.reference}',
        theme: pw.ThemeData.withFont(base: font, bold: font));
    final muted = PdfColor.fromHex('64748B');
    final dark = PdfColor.fromHex('172033');
    String date(DateTime value) => '${const [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec'
        ][value.month - 1]} ${value.day}, ${value.year}';
    String money(int cents) {
      final whole = (cents.abs() ~/ 100)
          .toString()
          .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
      return '${cents < 0 ? '-' : ''}₱$whole.${(cents.abs() % 100).toString().padLeft(2, '0')}';
    }

    String modeLabel(String mode) => switch (mode) {
          'exchange' => 'Tank exchange',
          'deposit' => 'New tank / deposit',
          'refill' => 'Refill only',
          'container' => 'Container + refill',
          'made_order' => 'Made to order',
          _ => '',
        };
    final total = items.fold<int>(0, (sum, item) => sum + item.lineTotalCents);
    document.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(38, 34, 38, 38),
        header: (context) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Expanded(
                          child: pw.Column(
                              crossAxisAlignment: pw.CrossAxisAlignment.start,
                              children: [
                            pw.Text(
                                settings?.storeName.isNotEmpty == true
                                    ? settings!.storeName
                                    : 'Business',
                                style: pw.TextStyle(
                                    fontSize: 17,
                                    fontWeight: pw.FontWeight.bold,
                                    color: dark)),
                            if (settings?.storeAddress.isNotEmpty == true)
                              pw.Text(settings!.storeAddress,
                                  style:
                                      pw.TextStyle(fontSize: 9, color: muted)),
                            if (settings?.storeContact.isNotEmpty == true)
                              pw.Text(settings!.storeContact,
                                  style:
                                      pw.TextStyle(fontSize: 9, color: muted)),
                          ])),
                      pw.SizedBox(width: 16),
                      pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: [
                            pw.Text('QUOTATION',
                                style: pw.TextStyle(
                                    fontSize: 23,
                                    fontWeight: pw.FontWeight.bold,
                                    color: dark)),
                            pw.Text(quote.reference,
                                style: pw.TextStyle(
                                    fontSize: 12,
                                    fontWeight: pw.FontWeight.bold,
                                    color: dark)),
                            pw.Text('Date: ${date(quote.createdAt)}',
                                style: const pw.TextStyle(fontSize: 9)),
                            pw.Text(
                                'Valid until: ${quote.validUntil == null ? 'No expiry' : date(quote.validUntil!)}',
                                style: const pw.TextStyle(fontSize: 9)),
                            pw.Text('Status: $status',
                                style: const pw.TextStyle(fontSize: 9)),
                            if (receipt?.receiptNumber != null)
                              pw.Text(
                                  'Converted to receipt ${receipt!.receiptNumber}',
                                  style: const pw.TextStyle(fontSize: 9)),
                          ]),
                    ],
                  ),
                  pw.SizedBox(height: 8),
                  pw.Divider(color: PdfColor.fromHex('DCE3EB')),
                ]),
        footer: (context) => pw.Column(children: [
              pw.Divider(color: PdfColor.fromHex('DCE3EB')),
              pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                        template?.footer.isNotEmpty == true
                            ? template!.footer
                            : 'This document is a quotation only and is not an official receipt or tax invoice.',
                        style: pw.TextStyle(fontSize: 8, color: muted)),
                    pw.Text(
                        'Page ${context.pageNumber} of ${context.pagesCount}',
                        style: pw.TextStyle(fontSize: 8, color: muted)),
                  ])
            ]),
        build: (context) => [
              pw.SizedBox(height: 11),
              pw.Text('BILL TO / CUSTOMER',
                  style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: muted)),
              pw.SizedBox(height: 5),
              pw.Text(quote.customerNameSnapshot ?? 'Walk-in customer',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
              if (quote.customerPhoneSnapshot?.isNotEmpty == true)
                pw.Text(quote.customerPhoneSnapshot!),
              if (quote.preparedBySnapshot.isNotEmpty &&
                  (template?.showPreparedBy ?? true))
                pw.Text('Prepared by: ${quote.preparedBySnapshot}'),
              pw.SizedBox(height: 16),
              pw.TableHelper.fromTextArray(
                cellAlignments: {
                  1: pw.Alignment.centerRight,
                  if (template?.showUnit ?? true) 2: pw.Alignment.center,
                  if (template?.showUnit ?? true) 3: pw.Alignment.centerRight,
                  if (template?.showUnit ?? true) 4: pw.Alignment.centerRight,
                  if (!(template?.showUnit ?? true))
                    2: pw.Alignment.centerRight,
                  if (!(template?.showUnit ?? true))
                    3: pw.Alignment.centerRight,
                },
                headerStyle: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                headerDecoration: pw.BoxDecoration(color: dark),
                cellStyle: const pw.TextStyle(fontSize: 9),
                cellPadding:
                    const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                border: pw.TableBorder(
                    horizontalInside:
                        pw.BorderSide(color: PdfColor.fromHex('E5E9EF'))),
                headers: [
                  'Description',
                  'Qty',
                  if (template?.showUnit ?? true) 'Unit',
                  'Unit price',
                  'Amount'
                ],
                data: [
                  for (final item in items)
                    [
                      '${item.productNameSnapshot.isEmpty ? 'Product' : item.productNameSnapshot}${item.customNotes?.isNotEmpty == true ? '\n${item.customNotes}' : ''}${(template?.showSku ?? true) && item.skuSnapshot?.isNotEmpty == true ? '\nSKU: ${item.skuSnapshot}' : ''}${(template?.showBarcode ?? false) && item.barcodeSnapshot?.isNotEmpty == true ? '\nBarcode: ${item.barcodeSnapshot}' : ''}${modeLabel(item.saleMode).isNotEmpty ? '\n${modeLabel(item.saleMode)}' : ''}',
                      Quantity.format(item.quantityMilli),
                      if (template?.showUnit ?? true) item.unitSnapshot,
                      money(item.unitPriceCents + item.extraCents),
                      money(item.lineTotalCents),
                    ]
                ],
              ),
              pw.SizedBox(height: 14),
              pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Container(
                      width: 215,
                      child: pw.Column(children: [
                        pw.Row(
                            mainAxisAlignment:
                                pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text('Subtotal',
                                  style:
                                      pw.TextStyle(fontSize: 9, color: muted)),
                              pw.Text(money(total),
                                  style: const pw.TextStyle(fontSize: 9)),
                            ]),
                        pw.SizedBox(height: 5),
                        pw.Row(
                            mainAxisAlignment:
                                pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text('Discount',
                                  style:
                                      pw.TextStyle(fontSize: 9, color: muted)),
                              pw.Text(money(0),
                                  style: const pw.TextStyle(fontSize: 9)),
                            ]),
                        pw.SizedBox(height: 7),
                        pw.Divider(color: PdfColor.fromHex('DCE3EB')),
                        pw.Row(
                            mainAxisAlignment:
                                pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text('TOTAL',
                                  style: pw.TextStyle(
                                      fontWeight: pw.FontWeight.bold)),
                              pw.Text(money(total),
                                  style: pw.TextStyle(
                                      fontWeight: pw.FontWeight.bold,
                                      fontSize: 13)),
                            ])
                      ]))),
              if (quote.notes?.isNotEmpty == true) ...[
                pw.SizedBox(height: 32),
                pw.Text('NOTES / TERMS',
                    style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: muted)),
                pw.SizedBox(height: 6),
                pw.Text(quote.notes!),
              ],
              if (template?.terms.isNotEmpty == true) ...[
                pw.SizedBox(height: 18),
                pw.Text('QUOTATION TERMS',
                    style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: muted)),
                pw.SizedBox(height: 6),
                pw.Text(template!.terms),
              ],
              if (template?.showSignature == true ||
                  template?.showAcceptance == true) ...[
                pw.SizedBox(height: 42),
                pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      if (template?.showSignature == true)
                        pw.Text('____________________\nAuthorized signature'),
                      if (template?.showAcceptance == true)
                        pw.Text('____________________\nCustomer acceptance'),
                    ]),
              ],
            ]));
    return document.save();
  }
}
