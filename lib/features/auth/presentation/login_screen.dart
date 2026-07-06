import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_error_messages.dart';
import '../../../core/providers/app_providers.dart';
import '../data/oauth_login_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  String? _error;
  bool _loading = false;

  Future<void> _login(String provider) async {
    setState(() {
      _error = null;
      _loading = true;
    });
    final auth = ref.read(authRepositoryProvider);
    final startUri = auth.oauthStartUri(provider);
    final oauth = OAuthLoginService();
    try {
      final result = await oauth.run(provider: provider, startUri: startUri);
      if (result['status'] != 'ok') {
        if (!mounted) return;
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
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text(
                'Family Chat',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Семейный мессенджер',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const Spacer(),
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _loading ? null : () => _login('google'),
                child: const Text('Войти через Google'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _loading ? null : () => _login('vk'),
                child: const Text('Войти через VK'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _loading ? null : () => _login('yandex'),
                child: const Text('Войти через Яндекс'),
              ),
              if (_loading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
