import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings_controller.dart';
import '../../../core/settings/media_storage_options.dart';
import '../../../core/widgets/family_app_bar.dart';

class MediaStorageSettingsScreen extends ConsumerWidget {
  const MediaStorageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Фото и кэш'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _SettingsCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Сохранять входящие в Галерею',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _HelpButton(
                  title: 'Сохранять входящие в Галерею',
                  body:
                      'Чужие фото и видео копируются в альбом FamilyChat. '
                      'Свои с этого телефона не дублируются. '
                      '«Скачать» на полном экране работает всегда.',
                ),
                Switch.adaptive(
                  value: settings.autoSaveIncomingToGallery,
                  onChanged: (value) {
                    ref
                        .read(appSettingsProvider.notifier)
                        .setAutoSaveIncomingToGallery(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            title: 'Автозагрузка в чате',
            help:
                'Когда выключено — в чате показывается превью и кнопка «Загрузить». '
                'По умолчанию всё загружается автоматически.',
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            title: 'Фото',
            wifiValue: settings.chatAutoDownloadPhotosWifi,
            mobileValue: settings.chatAutoDownloadPhotosMobile,
            onWifiChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    photosWifi: value,
                  );
            },
            onMobileChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    photosMobile: value,
                  );
            },
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            title: 'Видео',
            wifiValue: settings.chatAutoDownloadVideosWifi,
            mobileValue: settings.chatAutoDownloadVideosMobile,
            onWifiChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    videosWifi: value,
                  );
            },
            onMobileChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    videosMobile: value,
                  );
            },
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            title: 'Файлы',
            wifiValue: settings.chatAutoDownloadFilesWifi,
            mobileValue: settings.chatAutoDownloadFilesMobile,
            onWifiChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    filesWifi: value,
                  );
            },
            onMobileChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    filesMobile: value,
                  );
            },
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            title: 'Голосовые',
            wifiValue: settings.chatAutoDownloadVoiceWifi,
            mobileValue: settings.chatAutoDownloadVoiceMobile,
            onWifiChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    voiceWifi: value,
                  );
            },
            onMobileChanged: (value) {
              ref.read(appSettingsProvider.notifier).setChatAutoDownload(
                    voiceMobile: value,
                  );
            },
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            title: 'Срок кэша',
            help:
                'Превью в чате и альбомах. После срока файл удаляется, '
                'пока снова не откроете фото.',
          ),
          const SizedBox(height: 8),
          _OptionSelect<MediaCacheStaleOption>(
            value: settings.mediaCacheStale,
            options: MediaCacheStaleOption.values,
            labelOf: (option) => option.label,
            sheetTitle: 'Срок кэша',
            onChanged: (next) {
              ref.read(appSettingsProvider.notifier).setMediaCacheStale(next);
            },
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            title: 'Размер кэша',
            help:
                'Когда место кончится, сначала уйдут давно не открывавшиеся файлы.',
          ),
          const SizedBox(height: 8),
          _OptionSelect<MediaCacheSizeOption>(
            value: settings.mediaCacheSize,
            options: MediaCacheSizeOption.values,
            labelOf: (option) => option.label,
            sheetTitle: 'Размер кэша',
            onChanged: (next) {
              ref.read(appSettingsProvider.notifier).setMediaCacheSize(next);
            },
          ),
        ],
      ),
    );
  }
}

class _AutoDownloadGroup extends StatelessWidget {
  const _AutoDownloadGroup({
    required this.title,
    required this.wifiValue,
    required this.mobileValue,
    required this.onWifiChanged,
    required this.onMobileChanged,
  });

  final String title;
  final bool wifiValue;
  final bool mobileValue;
  final ValueChanged<bool> onWifiChanged;
  final ValueChanged<bool> onMobileChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium,
            ),
            _AutoDownloadToggle(
              label: 'Wi‑Fi',
              value: wifiValue,
              onChanged: onWifiChanged,
            ),
            _AutoDownloadToggle(
              label: 'Мобильная сеть',
              value: mobileValue,
              onChanged: onMobileChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoDownloadToggle extends StatelessWidget {
  const _AutoDownloadToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Switch.adaptive(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: child,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.help});

  final String title;
  final String help;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _HelpButton(title: title, body: help),
        ],
      ),
    );
  }
}

class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'Справка',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        Icons.help_outline_rounded,
        size: 22,
        color: scheme.onSurfaceVariant,
      ),
      onPressed: () => _showHelp(context, title: title, body: body),
    );
  }
}

Future<void> _showHelp(
  BuildContext context, {
  required String title,
  required String body,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        icon: const Icon(Icons.help_outline_rounded),
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Понятно'),
          ),
        ],
      );
    },
  );
}

class _OptionSelect<T> extends StatelessWidget {
  const _OptionSelect({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.sheetTitle,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final String sheetTitle;
  final ValueChanged<T> onChanged;

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final scheme = theme.colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    sheetTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final option in options)
                  _SelectOptionTile(
                    label: labelOf(option),
                    selected: option == value,
                    onTap: () => Navigator.of(ctx).pop(option),
                    scheme: scheme,
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && picked != value) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  labelOf(value),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.expand_more_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectOptionTile extends StatelessWidget {
  const _SelectOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.7)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
