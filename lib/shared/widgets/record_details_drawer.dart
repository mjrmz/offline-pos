import 'package:flutter/material.dart';

/// A compact record preview that keeps its source list visible behind it.
Future<T?> showRecordDetailsDrawer<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close details',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, __) => builder(context),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );

class RecordDetailsDrawer extends StatelessWidget {
  const RecordDetailsDrawer({
    super.key,
    required this.title,
    required this.content,
    this.subtitle,
    this.badges = const [],
    this.actions = const [],
    this.primaryAction,
    this.secondaryActions = const [],
    this.tertiaryAction,
    this.width = 560,
  });

  final Widget title;
  final Widget? subtitle;
  final List<Widget> badges;
  final Widget content;
  final List<Widget> actions;
  final Widget? primaryAction;
  final List<Widget> secondaryActions;
  final Widget? tertiaryAction;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = MediaQuery.sizeOf(context).width;
    final hasFooter = actions.isNotEmpty ||
        primaryAction != null ||
        secondaryActions.isNotEmpty ||
        tertiaryAction != null;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        key: const Key('record-details-drawer'),
        color: scheme.surface,
        elevation: 16,
        child: SizedBox(
          width: available < width ? available : width,
          height: double.infinity,
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            child: title,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close details',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        DefaultTextStyle.merge(
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          child: subtitle!,
                        ),
                      ],
                      if (badges.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(spacing: 6, runSpacing: 6, children: badges),
                      ],
                    ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: Scrollbar(
                    child: SingleChildScrollView(
                  key: const Key('record-details-scroll'),
                  padding: const EdgeInsets.all(24),
                  child: content,
                )),
              ),
              if (hasFooter) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Column(
                    key: const Key('record-details-actions'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (primaryAction != null)
                        SizedBox(height: 42, child: primaryAction!),
                      if (secondaryActions.isNotEmpty) ...[
                        if (primaryAction != null) const SizedBox(height: 8),
                        LayoutBuilder(builder: (context, constraints) {
                          final cellWidth = constraints.maxWidth < 360
                              ? constraints.maxWidth
                              : (constraints.maxWidth - 8) / 2;
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final action in secondaryActions)
                                SizedBox(
                                    width: cellWidth, height: 40, child: action)
                            ],
                          );
                        }),
                      ],
                      if (tertiaryAction != null) ...[
                        const SizedBox(height: 4),
                        Align(
                            alignment: Alignment.centerRight,
                            child: tertiaryAction!),
                      ],
                      if (actions.isNotEmpty)
                        Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: actions),
                    ],
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class DrawerStatusBadge extends StatelessWidget {
  const DrawerStatusBadge(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .10),
        border: Border.all(color: tone.withValues(alpha: .28)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: tone, fontWeight: FontWeight.w700)),
    );
  }
}

class DrawerSection extends StatelessWidget {
  const DrawerSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
        ]),
      );
}

class DrawerMetric extends StatelessWidget {
  const DrawerMetric(
      {super.key, required this.label, required this.value, this.detail});
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 82),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 7),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700, fontFeatures: [
              const FontFeature.tabularFigures(),
            ])),
        if (detail != null)
          Text(detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class DrawerMetricGrid extends StatelessWidget {
  const DrawerMetricGrid({super.key, required this.metrics});
  final List<Widget> metrics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 600 ? 3 : 2;
          final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final metric in metrics)
                SizedBox(width: width, child: metric)
            ],
          );
        },
      );
}

class DrawerLabelValue extends StatelessWidget {
  const DrawerLabelValue({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant))),
        const SizedBox(width: 12),
        Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: [const FontFeature.tabularFigures()],
                ))),
      ]),
    );
  }
}

class DrawerProgressSummary extends StatelessWidget {
  const DrawerProgressSummary(
      {super.key,
      required this.value,
      required this.label,
      this.detail,
      this.showPercent = true});
  final double? value;
  final String label;
  final String? detail;
  final bool showPercent;

  @override
  Widget build(BuildContext context) {
    final safe = value?.clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        if (showPercent)
          Text(safe == null ? '—' : '${(safe * 100).round()}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontFeatures: [const FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 8),
      if (safe == null)
        Container(
            height: 8,
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8)))
      else
        LinearProgressIndicator(
            value: safe,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
            backgroundColor: scheme.surfaceContainerHighest),
      if (detail != null) ...[
        const SizedBox(height: 6),
        Text(detail!,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    ]);
  }
}

class DrawerStockDonut extends StatelessWidget {
  const DrawerStockDonut(
      {super.key,
      required this.available,
      required this.reserved,
      required this.availableLabel,
      required this.reservedLabel});
  final int available;
  final int reserved;
  final String availableLabel;
  final String reservedLabel;

  @override
  Widget build(BuildContext context) {
    final total = available + reserved;
    if (total <= 0) return const Text('No physical stock to chart.');
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      SizedBox(
          width: 76,
          height: 76,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
                width: 76,
                height: 76,
                child: CircularProgressIndicator(
                    value: available / total,
                    strokeWidth: 9,
                    strokeCap: StrokeCap.round,
                    color: scheme.primary,
                    backgroundColor: scheme.tertiary.withValues(alpha: .45))),
            Text('${(available * 100 / total).round()}%',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ])),
      const SizedBox(width: 16),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Available: $availableLabel'),
        Text('Reserved: $reservedLabel'),
        Text('Share of physical stock',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ])),
    ]);
  }
}
