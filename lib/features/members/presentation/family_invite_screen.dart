import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers/app_providers.dart';
import '../family_invite_share.dart';

/// Экран приглашения: QR со ссылкой, короткий код, шаринг в мессенджер.
class FamilyInviteScreen extends ConsumerStatefulWidget {
  const FamilyInviteScreen({
    super.key,
    required this.relationshipCode,
  });

  final String relationshipCode;

  @override
  ConsumerState<FamilyInviteScreen> createState() => _FamilyInviteScreenState();
}

class _FamilyInviteScreenState extends ConsumerState<FamilyInviteScreen> {
  bool _loading = true;
  String? _error;
  String? _inviteUrl;
  String? _joinCode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadInvite());
    });
  }

  Future<void> _loadInvite({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inv = await ref.read(familychatRepositoryProvider).createInvite(
            widget.relationshipCode,
            force: force,
          );
      final url = FamilyInviteShare.inviteUrlFromResponse(inv);
      final code = (inv['join_code']?.toString() ?? '').trim();
      if (!mounted) return;
      setState(() {
        _inviteUrl = url;
        _joinCode = code.isEmpty ? null : code;
        _loading = false;
      });
      if (force && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Создана новая ссылка и код')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить приглашение';
      });
    }
  }

  Future<void> _share() async {
    final url = _inviteUrl;
    if (url == null || url.isEmpty) return;
    final code = _joinCode;
    final formatted =
        code == null ? null : FamilyInviteShare.formatJoinCode(code);
    final buffer = StringBuffer('Присоединяйся к нашей семье в Family Space.');
    if (formatted != null) {
      buffer.writeln();
      buffer.writeln();
      buffer.writeln('Код: $formatted');
    }
    buffer.writeln();
    buffer.write('Или по ссылке: $url');
    await SharePlus.instance.share(ShareParams(text: buffer.toString()));
  }

  Future<void> _copyCode() async {
    final code = _joinCode;
    if (code == null || code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Код скопирован')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Пригласить в семью'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorBody(
                    message: _error!,
                    onRetry: () => unawaited(_loadInvite()),
                  )
                : _InviteBody(
                    inviteUrl: _inviteUrl!,
                    joinCode: _joinCode,
                    scheme: scheme,
                    onShare: () => unawaited(_share()),
                    onCopyCode: () => unawaited(_copyCode()),
                    onRegenerate: () => unawaited(_loadInvite(force: true)),
                  ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InviteBody extends StatelessWidget {
  const _InviteBody({
    required this.inviteUrl,
    required this.joinCode,
    required this.scheme,
    required this.onShare,
    required this.onCopyCode,
    required this.onRegenerate,
  });

  final String inviteUrl;
  final String? joinCode;
  final ColorScheme scheme;
  final VoidCallback onShare;
  final VoidCallback onCopyCode;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final formatted = joinCode == null
        ? null
        : FamilyInviteShare.formatJoinCode(joinCode!);
    final secondary = scheme.onSurfaceVariant;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        Text(
          'Пусть близкий наведёт камеру на QR-код '
          'или введёт код в приложении.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            height: 1.45,
            color: secondary,
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: QrImageView(
              data: inviteUrl,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              eyeStyle: QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: scheme.onSurface,
              ),
              dataModuleStyle: QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
        if (formatted != null) ...[
          const SizedBox(height: 28),
          Text(
            'Код присоединения',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: secondary,
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onCopyCode,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: Column(
                children: [
                  Text(
                    formatted,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Нажмите, чтобы скопировать',
                    style: TextStyle(
                      fontSize: 13,
                      color: secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.ios_share_rounded),
          label: const Text('Отправить в мессенджер'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: onRegenerate,
          child: const Text('Создать новую ссылку'),
        ),
        const SizedBox(height: 4),
        Text(
          'Ссылка и код действуют 24 часа и рассчитаны на одного человека.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: secondary,
          ),
        ),
      ],
    );
  }
}
