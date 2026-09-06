import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/legal/legal_page_launcher.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';

/// Форма жалобы по безопасности детей (сохраняется через `POST feedback/`).
class ChildSafetyReportScreen extends ConsumerStatefulWidget {
  const ChildSafetyReportScreen({super.key});

  @override
  ConsumerState<ChildSafetyReportScreen> createState() =>
      _ChildSafetyReportScreenState();
}

class _ChildSafetyReportScreenState
    extends ConsumerState<ChildSafetyReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _sending = true);
    try {
      await ref.read(familychatRepositoryProvider).submitFeedback(
            email: _emailCtrl.text.trim(),
            message: _messageCtrl.text.trim(),
            category: 'child_safety',
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Сообщение отправлено. Мы рассмотрим его в приоритетном порядке.',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      var detail = '$e';
      if (e is DioException) {
        final data = e.response?.data;
        if (data is Map && data['detail'] != null) {
          detail = data['detail'].toString();
        } else {
          detail = e.message ?? detail;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: $detail')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Безопасность детей'),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              'Если вы заметили контент или поведение, связанное с сексуальным '
              'насилием или эксплуатацией детей, сообщите нам. '
              'Обращения рассматриваются в приоритетном порядке.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _sending
                    ? null
                    : () => openFamilyChatChildSafetyStandards(context),
                child: const Text('Открыть стандарты безопасности'),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _emailCtrl,
              enabled: !_sending,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email для ответа',
              ),
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return 'Укажите email';
                if (!s.contains('@') || !s.contains('.')) {
                  return 'Некорректный email';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _messageCtrl,
              enabled: !_sending,
              minLines: 6,
              maxLines: 12,
              maxLength: 10000,
              decoration: const InputDecoration(
                labelText: 'Описание проблемы',
                alignLabelWithHint: true,
              ),
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return 'Опишите проблему';
                if (s.length < 10) return 'Слишком короткое описание';
                return null;
              },
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _sending ? null : () => unawaited(_submit()),
              child: _sending
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Отправить'),
            ),
          ],
        ),
      ),
    );
  }
}
