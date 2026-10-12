import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';

void main() {
  test('receipt extras retain invoice and total fields', () {
    final document = ReceiptDocument(
      'sale-1',
      DateTime(2026, 10, 2),
      'Owner',
      'Store A',
      [const ReceiptLine('Item', 1, 50000, 50000)],
      50000,
      'cash',
      50000,
      123,
      'Main Street',
      '0917',
      'Welcome',
      'Thank you',
    );
    final encoded = String.fromCharCodes(EscPosEncoder().encode(document, 80));
    expect(encoded, contains('Store A'));
    expect(encoded, contains('Main Street'));
    expect(encoded, contains('Welcome'));
    expect(encoded, contains('Invoice #: 123'));
    expect(encoded, contains('Total'));
    expect(encoded, contains('Thank you'));
  });
}
