import '../../data/daos/sales_repository.dart';

class ReceiptDocument {
  final String reference;
  final DateTime timestamp;
  final String cashier;
  final String storeName;
  final List<ReceiptLine> lines;
  final int totalCents;
  final String paymentMethod;
  final int appliedCents;
  final int? birInvoiceNumber;

  const ReceiptDocument(
      this.reference,
      this.timestamp,
      this.cashier,
      this.storeName,
      this.lines,
      this.totalCents,
      this.paymentMethod,
      this.appliedCents,
      [this.birInvoiceNumber]);

  factory ReceiptDocument.fromDetail(SaleDetail detail, String storeName) =>
      ReceiptDocument(
        detail.summary.sale.id,
        detail.summary.sale.createdAt,
        detail.summary.cashierName,
        storeName,
        [
          for (var i = 0; i < detail.items.length; i++)
            ReceiptLine(detail.productNames[i], detail.items[i].quantity,
                detail.items[i].unitPriceCents, detail.items[i].lineTotalCents)
        ],
        detail.summary.sale.totalCents,
        detail.summary.paymentMethod,
        detail.paymentAmountCents,
        detail.summary.sale.birInvoiceNumber,
      );
}

class ReceiptLine {
  final String name;
  final int quantity;
  final int unitCents;
  final int totalCents;
  const ReceiptLine(this.name, this.quantity, this.unitCents, this.totalCents);
}

String receiptMoney(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

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
    line('Sale: ${receipt.reference}');
    if (receipt.birInvoiceNumber != null) {
      line('BIR invoice: ${receipt.birInvoiceNumber}');
    }
    line('Date: ${receipt.timestamp.toLocal()}');
    line('Cashier: ${receipt.cashier}');
    line('-' * columns);
    for (final item in receipt.lines) {
      line(item.name.length > columns
          ? item.name.substring(0, columns)
          : item.name);
      pair('${item.quantity} x ${receiptMoney(item.unitCents)}',
          receiptMoney(item.totalCents));
    }
    line('-' * columns);
    pair('Subtotal', receiptMoney(receipt.totalCents));
    pair('Total', receiptMoney(receipt.totalCents));
    pair('Payment: ${receipt.paymentMethod}',
        receiptMoney(receipt.appliedCents));
    b.addAll([10, 10, 10, 29, 86, 0]);
    return b;
  }
}
