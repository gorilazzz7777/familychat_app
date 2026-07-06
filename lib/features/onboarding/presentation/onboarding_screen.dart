import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/api_error_messages.dart';
import '../../../core/providers/app_providers.dart';

enum _OnboardingStep { choose, profile, createFamily, inviteKinship, questions }

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onComplete,
    required this.onLogout,
    this.pendingInviteToken,
  });

  final VoidCallback onComplete;
  final VoidCallback onLogout;
  final String? pendingInviteToken;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _OnboardingStep _step = _OnboardingStep.choose;
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  String _gender = 'male';
  String? _error;
  bool _loading = false;

  List<Map<String, dynamic>> _kinshipOptions = [];
  String? _selectedKinship;
  int? _sessionId;
  List<Map<String, dynamic>> _questions = [];
  final Map<String, String> _answers = {};

  @override
  void initState() {
    super.initState();
    if (widget.pendingInviteToken != null) {
      _step = _OnboardingStep.profile;
    }
    _loadKinship();
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _loadKinship() async {
    try {
      final opts = await ref.read(familychatRepositoryProvider).kinshipOptions();
      if (!mounted) return;
      setState(() => _kinshipOptions = opts);
    } catch (_) {}
  }

  Future<void> _saveProfile() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      await ref.read(familychatRepositoryProvider).saveProfile(
            firstName: _firstName.text.trim(),
            lastName: _lastName.text.trim(),
            gender: _gender,
          );
      if (!mounted) return;
      if (widget.pendingInviteToken != null) {
        await _continueInviteFlow();
      } else {
        setState(() {
          _loading = false;
          _step = _OnboardingStep.createFamily;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  Future<void> _continueInviteFlow() async {
    final token = widget.pendingInviteToken!;
    try {
      final accept = await ref.read(familychatRepositoryProvider).acceptInvite(token);
      if (accept['needs_profile'] == true) {
        final q = await ref.read(familychatRepositoryProvider).startOnboardingQuestions(token);
        _sessionId = q['onboarding_session_id'] as int?;
        _questions = (q['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      } else {
        _sessionId = accept['onboarding_session_id'] as int?;
        _questions = (accept['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      }
      if (!mounted) return;
      if (_questions.isEmpty) {
        await _completeOnboarding([]);
      } else {
        setState(() {
          _loading = false;
          _step = _OnboardingStep.questions;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  Future<void> _createFamily() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final name = 'Семья ${_lastName.text.trim()}'.trim();
      await ref.read(familychatRepositoryProvider).createFamily(name: name);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _step = _OnboardingStep.inviteKinship;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  Future<void> _shareInvite() async {
    if (_selectedKinship == null) {
      setState(() => _error = 'Выберите степень родства');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final inv = await ref.read(familychatRepositoryProvider).createInvite(_selectedKinship!);
      final url = inv['invite_url'] as String? ??
          '${Env.inviteBaseUrl}${inv['invite_url_path']}';
      await Share.share('Приглашение в Family Chat: $url');
      if (!mounted) return;
      setState(() => _loading = false);
      widget.onComplete();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  Future<void> _completeOnboarding(List<Map<String, dynamic>> answers) async {
    if (_sessionId == null) {
      widget.onComplete();
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      await ref.read(familychatRepositoryProvider).completeOnboarding(
            sessionId: _sessionId!,
            answers: answers,
          );
      widget.onComplete();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Добро пожаловать'),
        actions: [
          TextButton(onPressed: widget.onLogout, child: const Text('Выйти')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 16),
          ],
          if (_step == _OnboardingStep.choose) ...[
            const Text('У вас есть ссылка-приглашение в семью?'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => setState(() => _step = _OnboardingStep.profile),
              child: Text(widget.pendingInviteToken != null
                  ? 'Да, перейти к регистрации'
                  : 'Нет, создать свою семью'),
            ),
            if (widget.pendingInviteToken == null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => setState(() => _step = _OnboardingStep.profile),
                child: const Text('Да, у меня есть приглашение'),
              ),
            ],
          ],
          if (_step == _OnboardingStep.profile) ...[
            TextField(
              controller: _firstName,
              decoration: const InputDecoration(labelText: 'Имя'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lastName,
              decoration: const InputDecoration(labelText: 'Фамилия'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _gender,
              decoration: const InputDecoration(labelText: 'Пол'),
              items: const [
                DropdownMenuItem(value: 'male', child: Text('Мужской')),
                DropdownMenuItem(value: 'female', child: Text('Женский')),
              ],
              onChanged: (v) => setState(() => _gender = v ?? 'male'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _saveProfile,
              child: const Text('Продолжить'),
            ),
          ],
          if (_step == _OnboardingStep.createFamily) ...[
            const Text('Создайте семью и пригласите близких по ссылке.'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _createFamily,
              child: const Text('Создать семью'),
            ),
          ],
          if (_step == _OnboardingStep.inviteKinship) ...[
            const Text('Кого вы приглашаете? Укажите степень родства.'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedKinship,
              decoration: const InputDecoration(labelText: 'Родство'),
              items: _kinshipOptions
                  .map(
                    (o) => DropdownMenuItem(
                      value: o['code'] as String,
                      child: Text(o['label'] as String? ?? o['code'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _selectedKinship = v),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _shareInvite,
              child: const Text('Пригласить'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: widget.onComplete,
              child: const Text('Пропустить и войти в чат'),
            ),
          ],
          if (_step == _OnboardingStep.questions) ...[
            const Text('Уточним ваше место в семье:'),
            const SizedBox(height: 16),
            ..._questions.map((q) {
              final id = q['id']?.toString() ?? '';
              final options = (q['options'] as List?)?.cast<String>() ?? [];
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(q['text']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (options.isNotEmpty)
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(border: OutlineInputBorder()),
                        items: options
                            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                            .toList(),
                        onChanged: (v) => setState(() => _answers[id] = v ?? ''),
                      )
                    else
                      TextField(
                        decoration: const InputDecoration(border: OutlineInputBorder()),
                        onChanged: (v) => _answers[id] = v,
                      ),
                  ],
                ),
              );
            }),
            FilledButton(
              onPressed: _loading
                  ? null
                  : () {
                      final answers = _answers.entries
                          .map((e) => {'question_id': e.key, 'answer': e.value})
                          .toList();
                      _completeOnboarding(answers);
                    },
              child: const Text('Завершить'),
            ),
          ],
          if (_loading) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
