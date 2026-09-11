import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/api_error_messages.dart';
import '../../../core/invite/deferred_invite_recovery.dart';
import '../../../core/legal/family_chat_legal_links.dart';
import '../../../core/providers/app_providers.dart';
import '../../auth/presentation/social_account_link.dart';
import '../../auth/presentation/widgets/google_registration_warning.dart';
import '../../auth/presentation/widgets/social_login_panel.dart';
import '../../auth/utils/guest_status.dart';
import '../../members/family_invite_share.dart';
import '../../members/presentation/family_join_code_dialog.dart';
import '../../profile/presentation/birthday_format.dart';
import '../../profile/presentation/birthday_picker.dart';
import 'ios_safari_install_hint.dart';

String _cleanOnboardingOptionLabel(String option) {
  return option.replaceAll(RegExp(r'\s*\([^)]*\d+[^)]*\)\s*$'), '').trim();
}

enum _OnboardingStep { choose, profile, createFamily, inviteKinship, questions }

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onComplete,
    required this.onLogout,
    this.pendingInviteToken,
    this.pendingFriendInviteToken,
    this.onPendingInviteCleared,
    this.transferSession,
  });

  final VoidCallback onComplete;
  final VoidCallback onLogout;
  final String? pendingInviteToken;
  final String? pendingFriendInviteToken;
  final VoidCallback? onPendingInviteCleared;

  /// После перехода в другую семью — только вопросы родства (без профиля).
  final Map<String, dynamic>? transferSession;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _OnboardingStep _step = _OnboardingStep.choose;
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  String _gender = 'male';
  DateTime? _birthDate;
  bool _birthdayShowYear = true;
  bool _prefillLoaded = false;
  String? _error;
  bool _loading = false;

  List<Map<String, dynamic>> _kinshipOptions = [];
  String? _selectedKinship;
  int? _sessionId;
  List<Map<String, dynamic>> _questions = [];
  final Map<String, String> _answers = {};
  int _questionRound = 1;
  String? _inviteToken;
  bool _joinByInvite = false;
  bool _fromFriendInvite = false;
  bool _isGuest = true;
  bool _linkingSocial = false;
  bool _googleBlocked = false;

  @override
  void initState() {
    super.initState();
    _inviteToken = widget.pendingInviteToken;
    final friendToken = widget.pendingFriendInviteToken?.trim();
    _fromFriendInvite = friendToken != null && friendToken.isNotEmpty;
    final transfer = widget.transferSession;
    if (transfer != null) {
      _joinByInvite = true;
      _sessionId = transfer['onboarding_session_id'] as int?;
      _questions =
          (transfer['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _step = _OnboardingStep.questions;
      if (_questions.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _completeOnboarding([]);
        });
      }
    } else if (_inviteToken != null && _inviteToken!.isNotEmpty) {
      // Пришли по invite-ссылке — пропускаем экран «Как начать?».
      _joinByInvite = true;
      _step = _OnboardingStep.profile;
    } else if (_fromFriendInvite) {
      _joinByInvite = false;
      _step = _OnboardingStep.profile;
    }
    _loadKinship();
    _loadPrefill();
    _loadGuestFlag();
  }

  Future<void> _loadGuestFlag() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      if (!mounted) return;
      setState(() => _isGuest = GuestStatus.fromStatusMap(st));
    } catch (_) {}
  }

  Future<void> _linkSocial(String provider) async {
    if (_linkingSocial || _loading) return;
    setState(() {
      _linkingSocial = true;
      _googleBlocked = false;
      _error = null;
    });
    final result = await linkSocialAccount(ref: ref, provider: provider);
    if (!mounted) return;
    if (result.ok) {
      widget.onComplete();
      return;
    }
    setState(() {
      _linkingSocial = false;
      _googleBlocked = result.googleRegistrationBlocked;
      _error = result.error;
    });
  }

  Widget _existingAccountBlock(ThemeData theme) {
    if (!_isGuest) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 32),
          Text(
            'Вы вошли через соцсеть',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Продолжите регистрацию — аккаунт уже привязан.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        Text(
          'Уже есть аккаунт?',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Войдите через соцсеть, если у вас уже есть аккаунт.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        if (_googleBlocked) ...[
          const GoogleRegistrationWarning(),
          const SizedBox(height: 12),
        ],
        SocialLoginPanel(
          loading: _loading || _linkingSocial,
          onVk: () => _linkSocial('vk'),
          onYandex: () => _linkSocial('yandex'),
          onGoogle: () => _linkSocial('google'),
        ),
      ],
    );
  }

  Future<void> _clearInviteIntent() async {
    _inviteToken = null;
    _joinByInvite = false;
    widget.onPendingInviteCleared?.call();
  }

  bool _isInviteNotFound(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode != 404) return false;
    final path = error.requestOptions.path;
    return path.contains('/invite/') && path.contains('/accept');
  }

  Future<void> _loadPrefill() async {
    if (_prefillLoaded) return;
    try {
      final hints =
          await ref.read(familychatRepositoryProvider).onboardingPrefill();
      if (!mounted) return;
      setState(() {
        _prefillLoaded = true;
        if (_firstName.text.trim().isEmpty) {
          _firstName.text = hints['first_name']?.toString() ?? '';
        }
        if (_lastName.text.trim().isEmpty) {
          _lastName.text = hints['last_name']?.toString() ?? '';
        }
        final g = hints['gender']?.toString() ?? '';
        if (g == 'male' || g == 'female') _gender = g;
        _birthDate ??= parseBirthDate(hints['birth_date']?.toString());
      });
    } catch (_) {
      if (mounted) setState(() => _prefillLoaded = true);
    }
  }

  Future<void> _pickBirthDate() async {
    final picked = await showBirthDatePicker(
      context,
      initial: _birthDate,
    );
    if (picked != null) {
      setState(() => _birthDate = picked.date);
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _loadKinship() async {
    try {
      final opts =
          await ref.read(familychatRepositoryProvider).kinshipOptions();
      if (!mounted) return;
      setState(() => _kinshipOptions = opts);
    } catch (_) {}
  }

  Future<void> _saveProfile() async {
    if (_firstName.text.trim().isEmpty) {
      setState(() => _error = 'Укажите имя');
      return;
    }
    if (_birthDate == null) {
      setState(() => _error = 'Укажите день рождения');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      await ref.read(familychatRepositoryProvider).saveProfile(
            firstName: _firstName.text.trim(),
            lastName: _lastName.text.trim(),
            gender: _gender,
            birthDate: formatBirthDateForApi(_birthDate!),
            birthdayShowYear: _birthdayShowYear,
          );
      if (!mounted) return;
      if (_joinByInvite && _inviteToken != null) {
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
    final token = _inviteToken!;
    try {
      var accept =
          await ref.read(familychatRepositoryProvider).acceptInvite(token);
      if (!mounted) return;
      if (accept['needs_transfer_confirm'] == true) {
        final current =
            accept['current_family_name']?.toString() ?? 'текущей семьи';
        final target =
            accept['target_family_name']?.toString() ?? 'новой семьи';
        final sole = accept['sole_member'] == true;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Переход в другую семью'),
            content: Text(
              sole
                  ? 'Вы единственный участник «$current». Семья будет удалена.\n\n'
                      'Перейти в «$target»?'
                  : 'Покинуть «$current» и перейти в «$target»?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Перейти'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) {
          setState(() => _loading = false);
          return;
        }
        accept = await ref
            .read(familychatRepositoryProvider)
            .acceptInvite(token, confirmTransfer: true);
        if (!mounted) return;
      }
      if (accept['needs_profile'] == true) {
        final q = await ref
            .read(familychatRepositoryProvider)
            .startOnboardingQuestions(token);
        _sessionId = q['onboarding_session_id'] as int?;
        _questions =
            (q['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      } else {
        _sessionId = accept['onboarding_session_id'] as int?;
        _questions =
            (accept['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
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
      if (_isInviteNotFound(e)) {
        await _clearInviteIntent();
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error =
              'Приглашение не найдено или истекло. Продолжите создание своей семьи.';
          _step = _OnboardingStep.createFamily;
        });
        return;
      }
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
      if (_fromFriendInvite) {
        // Пришли по ссылке «друг» — семья создана, дальше диалог контакта.
        setState(() => _loading = false);
        widget.onComplete();
        return;
      }
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
      if (!mounted) return;
      await FamilyInviteShare.openScreen(
        context,
        relationshipCode: _selectedKinship!,
      );
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingErrorMessage(e);
      });
    }
  }

  Future<void> _joinWithInviteCode() async {
    if (_loading) return;
    final code = await showFamilyJoinCodeDialog(context);
    if (code == null || !mounted) return;

    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final resolved =
          await ref.read(familychatRepositoryProvider).resolveInviteCode(code);
      if (!mounted) return;
      if (resolved['valid'] != true) {
        setState(() {
          _loading = false;
          _error = 'Код не найден или уже не действует';
        });
        return;
      }
      final token = (resolved['token']?.toString() ?? '').trim();
      if (token.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Не удалось принять приглашение';
        });
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(DeferredInviteRecovery.pendingInviteKey, token);
      if (!mounted) return;
      setState(() {
        _inviteToken = token;
        _joinByInvite = true;
        _loading = false;
        _error = null;
        _step = _OnboardingStep.profile;
      });
      _loadPrefill();
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
      final result =
          await ref.read(familychatRepositoryProvider).completeOnboarding(
                sessionId: _sessionId!,
                answers: answers,
              );
      if (!mounted) return;
      if (result['needs_more_answers'] == true) {
        final nextQuestions =
            (result['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        setState(() {
          _loading = false;
          _questions = nextQuestions;
          _answers.clear();
          _questionRound += 1;
          _step = _OnboardingStep.questions;
        });
        return;
      }
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
        title: Text(
          widget.transferSession != null ? 'Новая семья' : 'Добро пожаловать',
        ),
        leading: BackButton(
          onPressed: _loading || _linkingSocial ? null : widget.onLogout,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const IosSafariInstallHint(),
          if (_error != null) ...[
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 16),
          ],
          if (_step == _OnboardingStep.choose) ...[
            const Text('Как вы хотите начать?'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loading || _linkingSocial
                  ? null
                  : () async {
                      await _clearInviteIntent();
                      if (!mounted) return;
                      setState(() {
                        _error = null;
                        _step = _OnboardingStep.profile;
                      });
                      _loadPrefill();
                    },
              child: const Text('Создать свою семью'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed:
                  _loading || _linkingSocial ? null : _joinWithInviteCode,
              child: const Text('У меня есть приглашение'),
            ),
            _existingAccountBlock(Theme.of(context)),
            const SizedBox(height: 24),
            FamilyChatLegalLinks(enabled: !_loading && !_linkingSocial),
          ],
          if (_step == _OnboardingStep.profile) ...[
            TextField(
              controller: _firstName,
              decoration: const InputDecoration(labelText: 'Имя'),
              textCapitalization: TextCapitalization.words,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lastName,
              decoration: const InputDecoration(labelText: 'Фамилия'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _gender,
              decoration: const InputDecoration(labelText: 'Пол'),
              items: const [
                DropdownMenuItem(value: 'male', child: Text('Мужской')),
                DropdownMenuItem(value: 'female', child: Text('Женский')),
              ],
              onChanged: (v) => setState(() => _gender = v ?? 'male'),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cake_outlined),
              title: const Text('День рождения'),
              subtitle: Text(
                _birthDate == null
                    ? 'Не указан'
                    : formatBirthDateDisplay(_birthDate!, showYear: true),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickBirthDate,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _birthdayShowYear,
              onChanged: (v) => setState(() => _birthdayShowYear = v ?? true),
              title: const Text('Показывать год'),
              subtitle: const Text(
                  'Другим участникам будет виден полный год рождения'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading || _firstName.text.trim().isEmpty
                  ? null
                  : _saveProfile,
              child: const Text('Продолжить'),
            ),
          ],
          if (_step == _OnboardingStep.createFamily) ...[
            const Text(
                'Создайте семью и пригласите близких по QR-коду или цифровому коду.'),
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
            Text(
              widget.transferSession != null
                  ? (_questionRound == 1
                      ? 'Уточним ваше место в новой семье:'
                      : 'Нужно уточнить ещё несколько деталей:')
                  : (_questionRound == 1
                      ? 'Уточним ваше место в семье:'
                      : 'Нужно уточнить ещё несколько деталей:'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            ..._questions.map((q) {
              final id = q['id']?.toString() ?? '';
              final options = (q['options'] as List?)?.cast<String>() ?? [];
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(q['text']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (options.isNotEmpty)
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(),
                        items: options
                            .map(
                              (o) => DropdownMenuItem(
                                value: o,
                                child: Text(_cleanOnboardingOptionLabel(o)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _answers[id] = v ?? ''),
                      )
                    else
                      TextField(
                        decoration: const InputDecoration(),
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
                          .map(
                            (e) => {
                              'question_id': e.key,
                              'answer': _cleanOnboardingOptionLabel(e.value),
                            },
                          )
                          .toList();
                      _completeOnboarding(answers);
                    },
              child: const Text('Завершить'),
            ),
          ],
          if (_loading || _linkingSocial) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
