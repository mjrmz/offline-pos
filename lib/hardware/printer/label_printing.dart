import '../../core/models/product.dart';
import '../../core/models/printer_settings.dart';
import '../../shared/utils/money.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'receipt_printer.dart';

class LabelTemplate {
  final String name;
  final bool price, barcode, barcodeText, sku, batch, expiry, businessName;
  const LabelTemplate(this.name,
      {this.price = true, this.barcode = true, this.barcodeText = true,
      this.sku = true, this.batch = false, this.expiry = false,
      this.businessName = false});

  static const defaults = [
    LabelTemplate('Product Barcode'),
    LabelTemplate('Shelf Label', barcode: false),
    LabelTemplate('Batch / Expiry', batch: true, expiry: true),
  ];

  Map<String, dynamic> toJson() => {
    'name': name, 'price': price, 'barcode': barcode,
    'barcodeText': barcodeText, 'sku': sku, 'batch': batch,
    'expiry': expiry, 'businessName': businessName,
  };
  factory LabelTemplate.fromJson(Map<String, dynamic> json) => LabelTemplate(
    json['name'] as String? ?? 'Label',
    price: json['price'] as bool? ?? true,
    barcode: json['barcode'] as bool? ?? true,
    barcodeText: json['barcodeText'] as bool? ?? true,
    sku: json['sku'] as bool? ?? true,
    batch: json['batch'] as bool? ?? false,
    expiry: json['expiry'] as bool? ?? false,
    businessName: json['businessName'] as bool? ?? false,
  );
}

class LabelTemplateStore {
  static const key = 'label.templates.v1';
  Future<List<LabelTemplate>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(key);
    if (value == null) return LabelTemplate.defaults;
    try {
      final templates = (jsonDecode(value) as List)
          .map((row) => LabelTemplate.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();
      return templates.isEmpty ? LabelTemplate.defaults : templates;
    } catch (_) {
      return LabelTemplate.defaults;
    }
  }
  Future<void> save(List<LabelTemplate> templates) async {
    if (templates.isEmpty) throw ArgumentError('Keep at least one template.');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(templates.map((t) => t.toJson()).toList()));
  }
}

class LabelPrintingPreferences {
  static const widthKey = 'label.paper_width.v1';
  Future<int> loadWidth() async {
    final value = (await SharedPreferences.getInstance()).getInt(widthKey);
    return value == 58 || value == 80 ? value! : 80;
  }
  Future<void> saveWidth(int width) async {
    if (width != 58 && width != 80) throw ArgumentError('Unsupported paper width');
    await (await SharedPreferences.getInstance()).setInt(widthKey, width);
  }
}

class LabelItem {
  final PosProduct product;
  final int quantity;
  final String? batchNumber, serialNumber;
  final DateTime? expiryDate;
  final int? receivingPriceCents;
  const LabelItem(this.product, this.quantity,
      {this.batchNumber, this.expiryDate, this.serialNumber,
      this.receivingPriceCents});
}

class LabelJob {
  final List<LabelItem> items;
  final LabelTemplate template;
  const LabelJob(this.items, this.template);
  int get total => items.fold(0, (sum, item) => sum + item.quantity);
  void validate() {
    if (items.isEmpty || total < 1 || total > 10000 ||
        items.any((item) => item.quantity < 1 || item.quantity > 10000 ||
            (item.serialNumber != null && item.quantity != 1))) {
      throw ArgumentError('Enter 1 to 10,000 labels per job.');
    }
    for (final item in items) {
      final code = item.product.barcode?.trim() ?? '';
      if (template.barcode && code.isNotEmpty &&
          (code128Payload(code).length > 255 ||
              !RegExp(r'^[\x20-\x7E]+$').hasMatch(code))) {
        throw ArgumentError('Barcode for ${item.product.name} contains unsupported CODE128 characters.');
      }
    }
  }
}

List<int> code128Payload(String value) =>
    [123, 66, ...value.replaceAll('{', '{{').codeUnits];

int suggestedReceivingLabels(int quantityMilli, {required bool weight}) =>
    !weight && quantityMilli > 0 && quantityMilli % 1000 == 0
        ? quantityMilli ~/ 1000 : 1;

class LabelRenderer {
  List<String> lines(LabelItem item, LabelTemplate template,
      {String storeName = ''}) {
    final product = item.product;
    return [
      if (template.businessName && storeName.trim().isNotEmpty) storeName.trim(),
      product.name,
      if (template.price && (product.pricingPolicy != 'layer' ||
          item.receivingPriceCents != null))
        formatPeso(item.receivingPriceCents ?? product.priceCents),
      if (template.batch && item.batchNumber?.trim().isNotEmpty == true)
        'Batch: ${item.batchNumber!.trim()}',
      if (template.expiry && item.expiryDate != null)
        'Exp: ${item.expiryDate!.year}-${item.expiryDate!.month.toString().padLeft(2, '0')}-${item.expiryDate!.day.toString().padLeft(2, '0')}',
      if (item.serialNumber?.isNotEmpty == true) 'Serial: ${item.serialNumber}',
      if (template.barcodeText && product.barcode?.trim().isNotEmpty == true)
        product.barcode!.trim(),
      if (template.sku && product.sku?.trim().isNotEmpty == true)
        'SKU: ${product.sku!.trim()}',
    ];
  }

  List<int> encode(LabelJob job, PrinterSettings settings) {
    job.validate();
    if (settings.widthMm != 58 && settings.widthMm != 80) {
      throw ArgumentError('Unsupported continuous paper width.');
    }
    final width = settings.widthMm == 58 ? 32 : 48;
    final out = <int>[27, 64];
    void write(String value) {
      final ascii = value.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
      for (var start = 0; start < ascii.length; start += width) {
        out.addAll(ascii.substring(start,
            start + width > ascii.length ? ascii.length : start + width).codeUnits);
        out.add(10);
      }
    }
    for (final item in job.items) {
      for (var copy = 0; copy < item.quantity; copy++) {
        for (final line in lines(item, job.template, storeName: settings.storeName)) {
          write(line);
        }
        final code = item.product.barcode?.trim() ?? '';
        if (job.template.barcode && code.isNotEmpty) {
          final payload = code128Payload(code);
          // GS k, CODE128 subset B. This is ESC/POS continuous paper output.
          out.addAll([29, 72, 0, 29, 104, 55, 29, 119, 2,
            29, 107, 73, payload.length, ...payload, 10]);
        }
        out.addAll([10, 10]);
      }
    }
    return out;
  }
}

class LabelPrintService {
  final PrinterTransport transport;
  final LabelRenderer renderer;
  final Future<void> Function(LabelJob, PrinterSettings)? onPrinted;
  LabelPrintService(this.transport, [LabelRenderer? renderer, this.onPrinted])
      : renderer = renderer ?? LabelRenderer();
  Future<void> print(LabelJob job, PrinterSettings settings) async {
    if (!settings.configured) {
      throw const HardwareException('Configure an ESC/POS printer first.');
    }
    await transport.send(renderer.encode(job, settings), settings);
    try {
      await onPrinted?.call(job, settings);
    } catch (error) {
      throw LabelAuditException(error);
    }
  }
}

class LabelAuditException implements Exception {
  final Object cause;
  const LabelAuditException(this.cause);
  @override
  String toString() => 'Labels were sent, but the print audit could not be saved.';
}
