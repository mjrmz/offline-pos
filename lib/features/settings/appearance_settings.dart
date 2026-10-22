import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/services/business_logo_store.dart';
import '../../shared/theme/theme_mode_controller.dart';

class SidebarColorTile extends StatelessWidget {
  const SidebarColorTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeController.maybeOf(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          const Icon(Icons.palette_outlined),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Sidebar color'),
                Text('Choose the sidebar background.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ])),
          const SizedBox(width: 12),
          DropdownButton<SidebarColorPreset>(
            key: const Key('sidebar-color-selector'),
            value: controller?.effectiveSidebarColor ?? SidebarColorPreset.navy,
            onChanged: controller == null
                ? null
                : (value) {
                    if (value != null) controller.setSidebarColor(value);
                  },
            items: [
              for (final color in SidebarColorPreset.values)
                DropdownMenuItem(
                    value: color,
                    child: Text(
                        '${color.name[0].toUpperCase()}${color.name.substring(1)}'))
            ],
          ),
        ]),
      ),
    );
  }
}

class SidebarLogoTile extends StatefulWidget {
  const SidebarLogoTile({super.key});

  @override
  State<SidebarLogoTile> createState() => _SidebarLogoTileState();
}

class _SidebarLogoTileState extends State<SidebarLogoTile> {
  String? error;

  Future<void> choose() async {
    final controller = AppThemeController.maybeOf(context);
    final result = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
    final path = result.isEmpty ? null : result.single.path;
    if (path == null) return;
    try {
      final oldPath = controller?.logoPath;
      if (oldPath != null) {
        await ResizeImage(FileImage(File(oldPath)), width: 256).evict();
      }
      final file = await BusinessLogoStore().save(path);
      if (!mounted) return;
      controller?.setLogoPath(file.path);
      setState(() => error = null);
    } catch (_) {
      if (mounted) setState(() => error = 'Unable to use this image.');
    }
  }

  Future<void> remove() async {
    final controller = AppThemeController.maybeOf(context);
    await BusinessLogoStore().remove();
    if (!mounted) return;
    controller?.setLogoPath(null);
    setState(() => error = null);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeController.maybeOf(context);
    final path = controller?.logoPath;
    final scheme = Theme.of(context).colorScheme;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(
                    width: 48,
                    height: 48,
                    child: path == null
                        ? const Icon(Icons.point_of_sale, size: 32)
                        : Image.file(File(path),
                            fit: BoxFit.contain,
                            cacheWidth: 256,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.point_of_sale))),
                const SizedBox(width: 16),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Sidebar logo'),
                      Text(
                          'Choose the logo or business image shown at the top of the sidebar.',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ])),
                TextButton(
                    onPressed: choose, child: const Text('Choose image')),
                if (path != null)
                  TextButton(onPressed: remove, child: const Text('Remove')),
              ]),
              if (error != null)
                Text(error!, style: TextStyle(color: scheme.error)),
            ])));
  }
}

class ResetAppearanceTile extends StatelessWidget {
  const ResetAppearanceTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeController.maybeOf(context);
    return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: controller?.resetAppearance,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset appearance'),
        ));
  }
}
