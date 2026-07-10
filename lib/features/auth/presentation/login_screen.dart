import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_error_messages.dart';
import '../../../core/legal/legal_page_launcher.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/routing/app_uri_parser.dart';
import '../data/oauth_login_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const _brandBlue = Color(0xFF7EC8F0);
  static const _brandPink = Color(0xFFF2A6C4);
  static const _brandViolet = Color(0xFFB8A6F0);
  static const _googleRegistrationRestrictedRu =
      'google_registration_restricted_ru';

  String? _error;
  bool _loading = false;
  bool _googleRegistrationBlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readOAuthErrorFromUrl());
  }

  void _readOAuthErrorFromUrl() {
    if (!kIsWeb) return;
    final oauth = parseOAuthCallback(Uri.base);
    if (oauth == null || oauth.isOk) return;
    if (!mounted) return;
    if (oauth.errorCode == _googleRegistrationRestrictedRu) {
      setState(() {
        _googleRegistrationBlocked = true;
        _error = null;
      });
      return;
    }
    if (oauth.error != null && oauth.error!.isNotEmpty) {
      setState(() => _error = oauth.error);
    }
  }

  Future<void> _login(String provider) async {
    setState(() {
      _error = null;
      _googleRegistrationBlocked = false;
      _loading = true;
    });
    final auth = ref.read(authRepositoryProvider);
    final startUri = auth.oauthStartUri(provider);
    final oauth = OAuthLoginService();
    try {
      final result = await oauth.run(provider: provider, startUri: startUri);
      if (result['status'] != 'ok') {
        if (!mounted) return;
        final errorCode = result['error_code'] ?? '';
        if (errorCode == _googleRegistrationRestrictedRu) {
          setState(() {
            _loading = false;
            _googleRegistrationBlocked = true;
            _error = null;
          });
          return;
        }
        setState(() {
          _loading = false;
          _error = result['error'] ?? 'Вход отменён';
        });
        return;
      }
      await auth.consumeSession(
        provider: provider,
        sessionCode: result['session_code']!,
      );
      widget.onLoggedIn();
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
    final theme = Theme.of(context);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFDDF0FF),
                  Color(0xFFF8E4F0),
                  Color(0xFFE8E0FF),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          Positioned(
            top: -80,
            right: -60,
            child: _GlowOrb(color: _brandBlue.withValues(alpha: 0.45), size: 220),
          ),
          Positioned(
            bottom: 120,
            left: -70,
            child: _GlowOrb(color: _brandPink.withValues(alpha: 0.42), size: 260),
          ),
          Positioned(
            top: MediaQuery.sizeOf(context).height * 0.18,
            right: 24,
            child: _GlowOrb(color: _brandViolet.withValues(alpha: 0.28), size: 120),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  _LogoBadge(),
                  const SizedBox(height: 24),
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF4A9FD4), Color(0xFFD46A9A)],
                    ).createShader(bounds),
                    child: Text(
                      'Family Chat',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Семейный мессенджер',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF5A6478),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Общайтесь, делитесь моментами\nи оставайтесь на связи',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF7A8498),
                      height: 1.45,
                    ),
                  ),
                  const Spacer(flex: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          color: Colors.white.withValues(alpha: 0.62),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _brandPink.withValues(alpha: 0.12),
                              blurRadius: 32,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Войти в аккаунт',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF2D3442),
                              ),
                            ),
                            const SizedBox(height: 18),
                            if (_googleRegistrationBlocked) ...[
                              const _GoogleRegistrationWarning(),
                              const SizedBox(height: 14),
                            ],
                            if (_error != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.errorContainer
                                      .withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            _SocialLoginPanel(
                              loading: _loading,
                              onGoogle: () => _login('google'),
                              onVk: () => _login('vk'),
                              onYandex: () => _login('yandex'),
                            ),
                            if (_loading) ...[
                              const SizedBox(height: 18),
                              const Center(
                                child: SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _loading
                            ? null
                            : () => openFamilyChatPrivacyPolicy(context),
                        child: Text(
                          'Политика конфиденциальности',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF4A9FD4),
                            decoration: TextDecoration.underline,
                            decorationColor: const Color(0xFF4A9FD4),
                          ),
                        ),
                      ),
                      Text(
                        '·',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF7A8498),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _loading
                            ? null
                            : () => openFamilyChatUserAgreement(context),
                        child: Text(
                          'Пользовательское соглашение',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF4A9FD4),
                            decoration: TextDecoration.underline,
                            decorationColor: const Color(0xFF4A9FD4),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleRegistrationWarning extends StatelessWidget {
  const _GoogleRegistrationWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFB300), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFE65100),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Регистрация через Google недоступна',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF5D4037),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Согласно российскому законодательству, регистрация новых '
            'пользователей через иностранные сервисы (Google, Apple ID) '
            'ограничена. Пожалуйста, выберите другой способ входа.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF6D4C41),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.72),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7EC8F0).withValues(alpha: 0.35),
            blurRadius: 28,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: const Color(0xFFF2A6C4).withValues(alpha: 0.25),
            blurRadius: 36,
            spreadRadius: -4,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/logo/logo.png',
          width: 128,
          height: 128,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

class _SocialLoginPanel extends StatelessWidget {
  const _SocialLoginPanel({
    required this.loading,
    required this.onGoogle,
    required this.onVk,
    required this.onYandex,
  });

  final bool loading;
  final VoidCallback onGoogle;
  final VoidCallback onVk;
  final VoidCallback onYandex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.75),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _SocialLoginIcon(
            assetPath: 'assets/logo/vk.png',
            semanticLabel: 'Вход через ВК',
            onTap: loading ? null : onVk,
          ),
          _SocialLoginIcon(
            assetPath: 'assets/logo/ya.png',
            semanticLabel: 'Вход через Яндекс',
            onTap: loading ? null : onYandex,
          ),
          _SocialLoginIcon(
            assetPath: 'assets/logo/google.png',
            semanticLabel: 'Вход через Google',
            onTap: loading ? null : onGoogle,
          ),
        ],
      ),
    );
  }
}

class _SocialLoginIcon extends StatelessWidget {
  const _SocialLoginIcon({
    required this.assetPath,
    required this.semanticLabel,
    required this.onTap,
  });

  final String assetPath;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 68,
          height: 68,
          child: Center(
            child: Image.asset(
              assetPath,
              width: 52,
              height: 52,
              fit: BoxFit.contain,
              semanticLabel: semanticLabel,
            ),
          ),
        ),
      ),
    );
  }
}
