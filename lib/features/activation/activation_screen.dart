// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/material.dart';
import '../../licensing/activation_client.dart';

class ActivationScreen extends StatefulWidget {
  final String deviceId;
  final ActivationClient client;
  final VoidCallback onActivated;
  final String? reason;
  const ActivationScreen(
      {super.key,
      required this.deviceId,
      required this.client,
      required this.onActivated,
      this.reason});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final keyController = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    keyController.dispose();
    super.dispose();
  }

  Future<void> submitActivation() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.client.activate(keyController.text, widget.deviceId);
      widget.onActivated();
    } catch (e) {
      if (mounted)
        setState(() => message = e is ActivationException
            ? e.message
            : 'Activation could not be completed.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Activate POS')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (widget.reason != null) Text(widget.reason!),
                    TextField(
                        controller: keyController,
                        decoration:
                            const InputDecoration(labelText: 'Activation Key')),
                    if (message != null) Text(message!),
                    const SizedBox(height: 16),
                    FilledButton(
                        onPressed: busy ? null : submitActivation,
                        child: const Text('Activate')),
                  ])))));
}
