import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/chat_network_link.dart';
import '../../../core/providers/app_providers.dart';
import '../data/services_access.dart';
import '../data/services_proxy_registrar.dart';
import 'services_webview_screen.dart';

/// Catalog of blocked-web services (promo-open or Individual Premium).
class ServicesHubScreen extends ConsumerStatefulWidget {
  const ServicesHubScreen({super.key});

  @override
  ConsumerState<ServicesHubScreen> createState() => _ServicesHubScreenState();
}

class _ServicesHubScreenState extends ConsumerState<ServicesHubScreen> {
  static const _kPromoDismissPrefix = 'services_promo_dismissed_';

  final _registrar = ServicesProxyRegistrar();
  ServicesAccess? _access;
  String? _error;
  bool _loading = true;
  bool _promoDismissed = false;
  bool _opening = false;
  String? _openingId;

  StreamSubscription<ChatNetworkLinkKind>? _netSub;
  ChatNetworkLinkKind? _lastNetKind;
  Timer? _netReregisterDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _netSub = ChatNetworkLink.watch().listen(_onNetKind);
  }

  @override
  void dispose() {
    _netReregisterDebounce?.cancel();
    unawaited(_netSub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  void _onNetKind(ChatNetworkLinkKind kind) {
    final prev = _lastNetKind;
    _lastNetKind = kind;
    if (kind == ChatNetworkLinkKind.offline) return;
    if (kind != ChatNetworkLinkKind.wifi &&
        kind != ChatNetworkLinkKind.mobile) {
      return;
    }
    // First sample after listen — not a switch.
    if (prev == null || prev == ChatNetworkLinkKind.unknown) return;
    if (prev == kind) return;
    if (_access == null) return;
    _netReregisterDebounce?.cancel();
    _netReregisterDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_reregisterOnly(why: 'hub-net:$prev→$kind'));
    });
  }

  Future<void> _reregisterOnly({required String why}) async {
    final access = _access;
    if (access == null) return;
    try {
      // Fresh token (register TTL ~10m) + current egress IP.
      final data =
          await ref.read(familychatRepositoryProvider).fetchServicesAccess();
      await _registrar.register(data.register, why: why);
      if (!mounted) return;
      setState(() => _access = data);
    } catch (e) {
      debugPrint('[services_hub] reregister fail why=$why $e');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data =
          await ref.read(familychatRepositoryProvider).fetchServicesAccess();
      // Catalog must render even if IP-register fails (iOS ATS historically
      // blocked cleartext :13129; register is retried on open).
      try {
        await _registrar.register(data.register, why: 'hub-load');
      } catch (e) {
        debugPrint('[services_hub] register fail (show catalog) $e');
      }
      final dismissed = await _isPromoDismissed(data.promo);
      if (!mounted) return;
      setState(() {
        _access = data;
        _promoDismissed = dismissed;
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

  Future<bool> _isPromoDismissed(ServicesPromo promo) async {
    if (!promo.active || promo.id.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_kPromoDismissPrefix${promo.id}') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _dismissPromo() async {
    final promo = _access?.promo;
    if (promo == null || !promo.active) return;
    setState(() => _promoDismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_kPromoDismissPrefix${promo.id}', true);
    } catch (_) {}
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
    if (_opening || item.url.isEmpty) return;
    setState(() {
      _opening = true;
      _openingId = item.id;
      _error = null;
    });
    try {
      // Always refresh allowlist for current egress IP (Wi‑Fi↔LTE / CGNAT).
      final data =
          await ref.read(familychatRepositoryProvider).fetchServicesAccess();
      await _registrar.register(data.register, why: 'open:${item.id}');
      if (!mounted) return;
      setState(() => _access = data);

      var url = item.url;
      // Prefer /foryou — bare tiktok.com often bounces into snssdk/intent schemes.
      if (item.id == 'tiktok' &&
          (url == 'https://www.tiktok.com/' ||
              url == 'https://www.tiktok.com')) {
        url = 'https://www.tiktok.com/foryou';
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ServicesWebViewScreen(
            title: item.title,
            url: url,
            proxy: data.proxy,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось подготовить доступ. Проверьте сеть и попробуйте снова.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _openingId = null;
        });
      }
    }
  }

  Widget _promoBanner(ThemeData theme, ServicesPromo promo) {
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                LucideIcons.sparkles,
                size: 18,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                promo.notice,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  height: 1.35,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Понятно',
              visualDensity: VisualDensity.compact,
              onPressed: _dismissPromo,
              icon: Icon(
                LucideIcons.x,
                size: 18,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = _access?.services ?? const <ServiceItem>[];
    final promo = _access?.promo ?? ServicesPromo.inactive;
    final showPromo = promo.active && !_promoDismissed;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        if (showPromo) ...[
          _promoBanner(theme, promo),
          const SizedBox(height: 14),
        ],
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
                enabled: !_opening,
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
                trailing: _opening && _openingId == item.id
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.chevron_right),
                onTap: _opening ? null : () => unawaited(_open(item)),
              ),
            ),
      ],
    );
  }
}
