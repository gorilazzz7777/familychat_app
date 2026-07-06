import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/platform/browser_info.dart';

/// Подсказка для iPhone: как добавить веб-приложение на главный экран через Safari.
class IosSafariInstallHint extends StatefulWidget {
  const IosSafariInstallHint({super.key});

  @override
  State<IosSafariInstallHint> createState() => _IosSafariInstallHintState();
}

class _IosSafariInstallHintState extends State<IosSafariInstallHint> {
  static const _prefKey = 'familychat_ios_install_hint_dismissed';
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      unawaited(_maybeShow());
    }
  }

  Future<void> _maybeShow() async {
    if (!isIosBrowser || isStandalonePwa) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefKey) == true) return;
    if (!mounted) return;
    setState(() => _visible = true);
  }

  Future<void> _dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
    if (mounted) setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.phone_iphone, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Установите Family Chat на главный экран',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Чтобы приложение открывалось как обычное и работали уведомления:',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 12),
            _Step(
              number: '1',
              text: 'Внизу Safari нажмите «Поделиться» (квадрат со стрелкой вверх).',
            ),
            const SizedBox(height: 8),
            _Step(
              number: '2',
              text: 'Пролистайте меню и выберите «На экран Домой».',
            ),
            const SizedBox(height: 8),
            _Step(
              number: '3',
              text: 'Нажмите «Добавить» — иконка появится на рабочем столе.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _dismiss,
                child: const Text('Понятно'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            number,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ],
    );
  }
}
