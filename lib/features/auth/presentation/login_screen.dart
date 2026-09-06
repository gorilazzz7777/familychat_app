import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/legal/family_chat_legal_links.dart';
import '../../../core/routing/app_uri_parser.dart';
import 'social_account_link.dart';
import 'widgets/google_registration_warning.dart';
import 'widgets/social_login_panel.dart';

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
  static const _googleRegistrationRestrictedRu = googleRegistrationRestrictedRu;

  String? _error;
  bool _loading = false;
  bool _googleRegistrationBlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _readOAuthErrorFromUrl());
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
    final result = await linkSocialAccount(ref: ref, provider: provider);
    if (!mounted) return;
    if (result.ok) {
      widget.onLoggedIn();
      return;
    }
    setState(() {
      _loading = false;
      _googleRegistrationBlocked = result.googleRegistrationBlocked;
      _error = result.error;
    });
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
            child:
                _GlowOrb(color: _brandBlue.withValues(alpha: 0.45), size: 220),
          ),
          Positioned(
            bottom: 120,
            left: -70,
            child:
                _GlowOrb(color: _brandPink.withValues(alpha: 0.42), size: 260),
          ),
          Positioned(
            top: MediaQuery.sizeOf(context).height * 0.18,
            right: 24,
            child: _GlowOrb(
                color: _brandViolet.withValues(alpha: 0.28), size: 120),
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
                      'Family Space',
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
                              const GoogleRegistrationWarning(),
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
                            SocialLoginPanel(
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
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  FamilyChatLegalLinks(enabled: !_loading),
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
