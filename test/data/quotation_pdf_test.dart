import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/features/contacts/documents/quotation_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('long saved quotation renders as a multi-page A4 PDF', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final pos = PosRepository(db);
      final lines = <QuoteLineRequest>[];
      for (var index = 0; index < 65; index++) {
        final product = await pos.saveProduct(
            name: 'Customer item ${index.toString().padLeft(2, '0')}',
            priceCents: 1000 + index,
            costCents: 0,
            startingStock: 1);
        lines.add(QuoteLineRequest(product, 1000));
      }
      final quote = await QuotationRepository(db, pos)
          .create(auth.current!, lines, notes: 'Quoted terms');
      final bytes = await QuotationPdf(db).render(quote.id);
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      final pdf = latin1.decode(bytes);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(pdf).length, greaterThan(1));
    } finally {
      await db.close();
    }
  });
}
