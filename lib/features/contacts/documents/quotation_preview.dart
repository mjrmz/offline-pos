import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'dart:math' as math;

/// A document workspace for the exact bytes used by print, save and share.
class QuotationPreview extends StatefulWidget {
  final Uint8List bytes;
  final String reference;
  final VoidCallback onPrint;
  final VoidCallback onSave;
  final VoidCallback onShare;

  const QuotationPreview(
      {super.key,
      required this.bytes,
      required this.reference,
      required this.onPrint,
      required this.onSave,
      required this.onShare});

  @override
  State<QuotationPreview> createState() => _QuotationPreviewState();
}

class _QuotationPreviewState extends State<QuotationPreview> {
  final _scroll = ScrollController();
  final List<Uint8List> _pages = [];
  double _zoom = 1;
  double _gestureStartZoom = 1;
  String _fit = 'page';
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await for (final page in Printing.raster(widget.bytes, dpi: 110)) {
        final png = await page.toPng();
        if (!mounted) return;
        setState(() => _pages.add(png));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.reference), actions: [
          IconButton(
              tooltip: 'Print',
              onPressed: widget.onPrint,
              icon: const Icon(Icons.print_outlined)),
          IconButton(
              tooltip: 'Save PDF',
              onPressed: widget.onSave,
              icon: const Icon(Icons.download_outlined)),
          IconButton(
              tooltip: 'Share',
              onPressed: widget.onShare,
              icon: const Icon(Icons.share_outlined)),
        ]),
        body: LayoutBuilder(builder: (context, viewport) {
          final pageWidth = viewport.maxWidth - 56;
          final pageHeight = viewport.maxHeight - 104;
          final fitPage = (pageWidth / 595.3).clamp(0.1, 3.0) <
                  (pageHeight / 841.9).clamp(0.1, 3.0)
              ? (pageWidth / 595.3).clamp(0.1, 3.0)
              : (pageHeight / 841.9).clamp(0.1, 3.0);
          final fitWidth = (pageWidth / 595.3).clamp(0.1, 3.0);
          final scale = _fit == 'page'
              ? fitPage
              : _fit == 'width'
                  ? fitWidth
                  : _zoom;
          final width = 595.3 * scale;
          final height = 841.9 * scale;
          return Column(children: [
            Material(
                elevation: 1,
                child: SizedBox(
                    height: 56,
                    child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          const SizedBox(width: 16),
                          Text('Page $_page / ${_pages.length}',
                              key: const Key('quotePreviewPages')),
                          const SizedBox(width: 20),
                          IconButton(
                              tooltip: 'Zoom out',
                              onPressed: () => setState(() {
                                    _fit = 'custom';
                                    _zoom = (scale - .1).clamp(.2, 3);
                                  }),
                              icon: const Icon(Icons.remove)),
                          Text('${(scale * 100).round()}%',
                              key: const Key('quotePreviewZoom')),
                          IconButton(
                              tooltip: 'Zoom in',
                              onPressed: () => setState(() {
                                    _fit = 'custom';
                                    _zoom = (scale + .1).clamp(.2, 3);
                                  }),
                              icon: const Icon(Icons.add)),
                          const SizedBox(width: 12),
                          TextButton(
                              onPressed: () => setState(() => _fit = 'page'),
                              child: const Text('Fit page')),
                          TextButton(
                              onPressed: () => setState(() => _fit = 'width'),
                              child: const Text('Fit width')),
                        ])))),
            Expanded(
                child: Container(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF202630)
                        : const Color(0xFFE9EDF2),
                    child: _error != null
                        ? Center(child: Text(_error!))
                        : _pages.isEmpty
                            ? const Center(child: CircularProgressIndicator())
                            : NotificationListener<ScrollNotification>(
                                onNotification: (notification) {
                                  if (notification
                                      is ScrollUpdateNotification) {
                                    final next =
                                        ((_scroll.offset / (height + 24))
                                                    .round() +
                                                1)
                                            .clamp(1, _pages.length);
                                    if (next != _page) {
                                      setState(() => _page = next);
                                    }
                                  }
                                  return false;
                                },
                                child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                        width: math.max(
                                            width + 48, viewport.maxWidth),
                                        height: viewport.maxHeight - 56,
                                        child: ListView.builder(
                                          controller: _scroll,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 24),
                                          itemCount: _pages.length,
                                          itemBuilder: (context, index) =>
                                              Center(
                                                  child: Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 24),
                                            child: GestureDetector(
                                                onScaleStart: (_) =>
                                                    _gestureStartZoom = scale,
                                                onScaleUpdate: (details) {
                                                  if (details.pointerCount >
                                                      1) {
                                                    setState(() {
                                                      _fit = 'custom';
                                                      _zoom =
                                                          (_gestureStartZoom *
                                                                  details.scale)
                                                              .clamp(.2, 3);
                                                    });
                                                  }
                                                },
                                                child: Container(
                                                    width: width,
                                                    height: height,
                                                    decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        boxShadow: [
                                                          BoxShadow(
                                                              color: Colors
                                                                  .black
                                                                  .withValues(
                                                                      alpha:
                                                                          .18),
                                                              blurRadius: 18,
                                                              offset:
                                                                  const Offset(
                                                                      0, 5))
                                                        ]),
                                                    child: Image.memory(
                                                        _pages[index],
                                                        fit: BoxFit.fill,
                                                        filterQuality:
                                                            FilterQuality
                                                                .high))),
                                          )),
                                        )))))),
          ]);
        }),
      );
}
