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
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Фото и кэш'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
        children: [
          SwitchListTile(
            value: settings.autoSaveIncomingToGallery,
            title: const Text('Сохранять входящие в Галерею'),
            subtitle: const Text(
              'Чужие фото и видео копируются в альбом FamilyChat. '
              'Свои с этого телефона не дублируются. '
              '«Скачать» на полном экране работает всегда.',
            ),
            onChanged: (value) {
              ref
                  .read(appSettingsProvider.notifier)
                  .setAutoSaveIncomingToGallery(value);
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Срок кэша', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Превью в чате и альбомах. После срока файл удаляется, '
              'пока снова не откроете фото.',
              style: muted,
            ),
          ),
          RadioGroup<MediaCacheStaleOption>(
            groupValue: settings.mediaCacheStale,
            onChanged: (next) {
              if (next == null) return;
              ref.read(appSettingsProvider.notifier).setMediaCacheStale(next);
            },
            child: Column(
              children: [
                for (final option in MediaCacheStaleOption.values)
                  RadioListTile<MediaCacheStaleOption>(
                    value: option,
                    title: Text(option.label),
                  ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Размер кэша', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Когда место кончится, сначала уйдут давно не открывавшиеся файлы.',
              style: muted,
            ),
          ),
          RadioGroup<MediaCacheSizeOption>(
            groupValue: settings.mediaCacheSize,
            onChanged: (next) {
              if (next == null) return;
              ref.read(appSettingsProvider.notifier).setMediaCacheSize(next);
            },
            child: Column(
              children: [
                for (final option in MediaCacheSizeOption.values)
                  RadioListTile<MediaCacheSizeOption>(
                    value: option,
                    title: Text(option.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
