import 'package:flutter/material.dart';

import '../theme/app_layout.dart';

/// A focused confirmation that states the effect of an irreversible action.
Future<bool> showAppDestructiveConfirmDialog({
  required BuildContext context,
  required String title,
  required String impact,
  required String confirmLabel,
  String cancelLabel = 'Keep record',
  bool reversible = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(impact),
              if (!reversible) ...[
                const SizedBox(height: AppLayout.space12),
                Text('This action cannot be undone.',
                    style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;
