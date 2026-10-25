import '../../data/daos/sales_repository.dart';
import '../../shared/utils/money.dart';
import '../../core/models/quantity.dart';
import '../../core/models/sale_line_format.dart';
import '../../core/models/printer_settings.dart';

class ReceiptDocument {
  final String reference;
  final DateTime timestamp;
  final String cashier;
  final String storeName;
  final String storeAddress;
  final String storeContact;
  final String customHeader;
  final String customFooter;
  final List<ReceiptLine> lines;
  final int totalCents;
  final String paymentMethod;
  final int appliedCents;
  final int? birInvoiceNumber;
  final String? walkInName;
  final String? walkInContact;
  final List<(String, int)> promotionDiscounts;

  const ReceiptDocument(
      this.reference,
      this.timestamp,
      this.cashier,
      this.storeName,
      this.lines,
      this.totalCents,
      this.paymentMethod,
      this.appliedCents,
      [this.birInvoiceNumber,
      this.storeAddress = '',
      this.storeContact = '',
      this.customHeader = '',
      this.customFooter = '',
      this.walkInName,
      this.walkInContact,
      this.promotionDiscounts = const []]);

  factory ReceiptDocument.fromDetail(SaleDetail detail, String storeName,
          [PrinterSettings? settings]) =>
      ReceiptDocument(
        detail.summary.sale.receiptNumber ?? 'Legacy sale',
        detail.summary.sale.createdAt,
        detail.summary.cashierName,
        storeName,
        [
          for (var i = 0; i < detail.items.length; i++)
            ReceiptLine(detail.productNames[i], detail.items[i].quantity,
                detail.items[i].unitPriceCents,
                detail.items[i].lineTotalCents +
                    detail.items[i].manualDiscountCents +
                    detail.items[i].promotionDiscountCents,
                quantityMilli: detail.items[i].quantityMilli,
                unit: detail.items[i].saleUnit,
                mode: detail.items[i].saleMode,
                batchNumber: detail.items[i].batchNumber,
                extraCents: detail.items[i].extraCents,
                manualDiscountCents: detail.items[i].manualDiscountCents,
                serialNumbers:
                    detail.serialNumbersByItem[detail.items[i].id] ?? const [])
        ],
        detail.summary.sale.totalCents,
        detail.summary.paymentMethod,
        detail.paymentAmountCents,
        detail.summary.sale.birInvoiceNumber,
        settings?.storeAddress ?? '',
        settings?.storeContact ?? '',
        settings?.receiptHeader ?? '',
        settings?.receiptFooter ?? '',
        detail.summary.sale.walkInName,
        detail.summary.sale.walkInContact,
        [for (final application in detail.promotionApplications)
          (application.promotionName, application.discountCents)],
      );
}

class ReceiptLine {
  final String name;
  final int quantity;
  final int unitCents;
  final int totalCents;
  final int quantityMilli;
  final String unit;
  final String mode;
  final String? batchNumber;
  final int extraCents;
  final int manualDiscountCents;
  final List<String> serialNumbers;
  const ReceiptLine(this.name, this.quantity, this.unitCents, this.totalCents,
      {this.quantityMilli = 0,
      this.unit = 'pcs',
      this.mode = 'ordinary',
      this.batchNumber,
      this.extraCents = 0,
      this.manualDiscountCents = 0,
      this.serialNumbers = const []});
}

String receiptMoney(int cents) => formatPeso(cents).replaceFirst('₱', 'PHP ');

class EscPosEncoder {
  List<int> encode(ReceiptDocument receipt, int widthMm) {
    if (widthMm != 58 && widthMm != 80) {
      throw ArgumentError('Unsupported paper width');
    }
    final columns = widthMm == 58 ? 32 : 48;
    final b = <int>[27, 64];
    void line(String value) {
      b.addAll(value.replaceAll(RegExp(r'[^\x20-\x7E]'), '?').codeUnits);
      b.add(10);
    }

    void pair(String left, String right) {
      final room = columns - right.length - 1;
      final clipped = left.length > room ? left.substring(0, room) : left;
      line(clipped.padRight(columns - right.length) + right);
    }

    line(receipt.storeName.isEmpty ? 'MASD POS' : receipt.storeName);
    if (receipt.storeAddress.isNotEmpty) line(receipt.storeAddress);
    if (receipt.storeContact.isNotEmpty) line(receipt.storeContact);
    if (receipt.customHeader.isNotEmpty) line(receipt.customHeader);
    line(receipt.reference.startsWith('RET-')
        ? 'Return / Exchange #: ${receipt.reference}'
        : 'Receipt #: ${receipt.reference}');
    if (receipt.birInvoiceNumber != null) {
      line('Invoice #: ${receipt.birInvoiceNumber}');
    }
    line('Date: ${receipt.timestamp.toLocal()}');
    line('Cashier: ${receipt.cashier}');
    if (receipt.walkInName?.isNotEmpty == true) {
      line('Customer: ${receipt.walkInName}');
    }
    if (receipt.walkInContact?.isNotEmpty == true) {
      line('Contact: ${receipt.walkInContact}');
    }
    line('-' * columns);
    for (final item in receipt.lines) {
      line(item.name.length > columns
          ? item.name.substring(0, columns)
          : item.name);
      final quantity = item.quantityMilli == 0
          ? item.quantity * Quantity.scale
          : item.quantityMilli;
      pair(
          '${saleQuantityLabel(quantity, item.unit)} x ${receiptMoney(item.unitCents)}',
          receiptMoney(item.totalCents));
      final detail = saleModeLabel(item.mode, batchNumber: item.batchNumber);
      if (detail.isNotEmpty) line(detail);
      for (final serial in item.serialNumbers) {
        line('Serial: $serial');
      }
      if (item.extraCents > 0) {
        line('Extra: ${receiptMoney(item.extraCents)} per ${item.unit}');
      }
      if (item.manualDiscountCents > 0) {
        line('Manual discount: -${receiptMoney(item.manualDiscountCents)}');
      }
    }
    line('-' * columns);
    pair('Subtotal', receiptMoney(receipt.lines.fold<int>(0,
        (sum, item) => sum + item.totalCents)));
    for (final promotion in receipt.promotionDiscounts) {
      pair('Promo: ${promotion.$1}', '-${receiptMoney(promotion.$2)}');
    }
    pair('Total', receiptMoney(receipt.totalCents));
    pair('Payment: ${receipt.paymentMethod}',
        receiptMoney(receipt.appliedCents));
    if (receipt.customFooter.isNotEmpty) line(receipt.customFooter);
    b.addAll([10, 10, 10, 29, 86, 0]);
    return b;
  }
}
