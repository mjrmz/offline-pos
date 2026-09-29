import '../../core/models/printer_settings.dart';
import '../printer/receipt_printer.dart';

abstract interface class CashDrawer {
  Future<void> open(PrinterSettings settings);
}

class EscPosCashDrawer implements CashDrawer {
  final PrinterTransport transport;
  EscPosCashDrawer(this.transport);
  @override
  Future<void> open(PrinterSettings settings) =>
      transport.send([27, 112, 0, 25, 250], settings);
}
