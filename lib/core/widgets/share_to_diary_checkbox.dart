import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../share/share_to_diary_prefs.dart';

/// Checkbox shown only when the user has an active LittleOne Diary family.
class ShareToDiaryCheckbox extends ConsumerWidget {
  const ShareToDiaryCheckbox({super.key, this.dense = false});

  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(diaryShareAvailableProvider).valueOrNull ?? false;
    if (!available) return const SizedBox.shrink();

    final enabled = ref.watch(shareToDiaryPrefsProvider);
    return CheckboxListTile(
      dense: dense,
      contentPadding: dense ? EdgeInsets.zero : null,
      controlAffinity: ListTileControlAffinity.leading,
      value: enabled,
      onChanged: (v) {
        if (v == null) return;
        ref.read(shareToDiaryPrefsProvider.notifier).setEnabled(v);
      },
      title: const Text('Отправить в LittleOne Diary'),
      subtitle: dense
          ? null
          : const Text('Фото появится в дневнике без повторной загрузки'),
    );
  }
}
