import 'package:flutter/material.dart';

/// Меню «Ещё» над нижней навигацией.
class MoreMenuPanel extends StatelessWidget {
  const MoreMenuPanel({
    super.key,
    required this.onClose,
    required this.onOpenGallery,
    required this.onOpenCalendar,
    required this.onOpenProfile,
  });

  final VoidCallback onClose;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenProfile;

  void _pick(BuildContext context, VoidCallback action) {
    onClose();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.photo_library_outlined,
                color: theme.colorScheme.primary),
            title: const Text('Галерея'),
            onTap: () => _pick(context, onOpenGallery),
          ),
          ListTile(
            leading: Icon(Icons.calendar_month_outlined,
                color: theme.colorScheme.primary),
            title: const Text('Календарь'),
            onTap: () => _pick(context, onOpenCalendar),
          ),
          ListTile(
            leading:
                Icon(Icons.person_outline, color: theme.colorScheme.primary),
            title: const Text('Профиль'),
            onTap: () => _pick(context, onOpenProfile),
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom + 8),
        ],
      ),
    );
  }
}
