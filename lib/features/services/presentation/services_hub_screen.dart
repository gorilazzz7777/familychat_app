import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../data/services_access.dart';
import '../data/services_proxy_registrar.dart';
import 'services_webview_screen.dart';

/// Catalog of blocked-web services (Individual Premium).
class ServicesHubScreen extends ConsumerStatefulWidget {
  const ServicesHubScreen({super.key});

  @override
  ConsumerState<ServicesHubScreen> createState() => _ServicesHubScreenState();
}

class _ServicesHubScreenState extends ConsumerState<ServicesHubScreen> {
  ServicesAccess? _access;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data =
          await ref.read(familychatRepositoryProvider).fetchServicesAccess();
      // Whitelist this phone's real IP (direct to VPS, not via :443 mux).
      await ServicesProxyRegistrar().register(data.register);
      if (!mounted) return;
      setState(() {
        _access = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось открыть сервисы';
      });
    }
  }

  String? _logoAssetFor(String id) {
    return switch (id) {
      'youtube' => 'assets/logo/youtube.png',
      'tiktok' => 'assets/logo/tiktok.png',
      'instagram' => 'assets/logo/instagram.png',
      _ => null,
    };
  }

  Widget _leadingFor(String id) {
    final asset = _logoAssetFor(id);
    if (asset != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset(
          asset,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, __, ___) => CircleAvatar(
            child: Icon(_fallbackIconFor(id)),
          ),
        ),
      );
    }
    return CircleAvatar(child: Icon(_fallbackIconFor(id)));
  }

  IconData _fallbackIconFor(String id) {
    return switch (id) {
      'youtube' => LucideIcons.play,
      'tiktok' => LucideIcons.music_2,
      'instagram' => LucideIcons.camera,
      _ => LucideIcons.globe,
    };
  }

  Future<void> _open(ServiceItem item) async {
    final access = _access;
    if (access == null || item.url.isEmpty) return;
    var url = item.url;
    // Prefer /foryou — bare tiktok.com often bounces into snssdk/intent schemes.
    if (item.id == 'tiktok' &&
        (url == 'https://www.tiktok.com/' || url == 'https://www.tiktok.com')) {
      url = 'https://www.tiktok.com/foryou';
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServicesWebViewScreen(
          title: item.title,
          url: url,
          proxy: access.proxy,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = _access?.services ?? const <ServiceItem>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        Text(
          'Открываются внутри приложения. Вход в аккаунт сохраняется.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Column(
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _load,
                  child: const Text('Повторить'),
                ),
              ],
            ),
          )
        else
          for (final item in services)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                leading: _leadingFor(item.id),
                title: Text(item.title),
                subtitle: Text(
                  item.url.replaceFirst(RegExp(r'^https?://'), ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(LucideIcons.chevron_right),
                onTap: () => _open(item),
              ),
            ),
      ],
    );
  }
}
