import 'package:flutter/material.dart';

class CustomerProfileKpis extends StatelessWidget {
  const CustomerProfileKpis(this.values, {super.key});
  final List<(String, String)> values;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 650
            ? 3
            : box.maxWidth >= 400
                ? 2
                : 1;
        final gap = 10.0;
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        final scheme = Theme.of(context).colorScheme;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final (label, value) in values)
            SizedBox(
                width: width,
                height: 83,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        border: Border.all(color: scheme.outlineVariant),
                        borderRadius: BorderRadius.circular(10)),
                    child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 5),
                              Text(value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                            ]))))
        ]);
      });
}

class CustomerProfilePanel extends StatelessWidget {
  const CustomerProfilePanel(
      {super.key,
      required this.title,
      required this.child,
      this.action,
      this.count});
  final String title;
  final Widget child;
  final Widget? action;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
        decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(10)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
              child: Row(children: [
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium)),
                if (count != null)
                  Text('$count ${count == 1 ? 'result' : 'results'}',
                      style: Theme.of(context).textTheme.bodySmall),
                if (action != null) action!,
              ])),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(padding: const EdgeInsets.all(12), child: child),
        ]));
  }
}

class CustomerProfileEmpty extends StatelessWidget {
  const CustomerProfileEmpty(this.title, this.message, {super.key});
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]));
}
