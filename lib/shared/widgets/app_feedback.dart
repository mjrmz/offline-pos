import 'package:flutter/material.dart';

/// Shows one short, non-blocking message in the current workspace.
void showAppFeedback(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ));
}
