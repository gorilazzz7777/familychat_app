import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../impersonation/admin_enter.dart';
import '../impersonation/impersonation_storage.dart';

class ImpersonationBannerStrip extends ConsumerStatefulWidget {
  const ImpersonationBannerStrip({super.key, this.onSessionChanged});

  final VoidCallback? onSessionChanged;

  @override
  ConsumerState<ImpersonationBannerStrip> createState() =>
      _ImpersonationBannerStripState();
}

class _ImpersonationBannerStripState extends ConsumerState<ImpersonationBannerStrip> {
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final active = await ImpersonationStorage().isActive();
    if (mounted) setState(() => _active = active);
  }

  Future<void> _exit() async {
    await exitImpersonation(ref);
    widget.onSessionChanged?.call();
    if (mounted) setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    return Material(
      color: Colors.orange.shade100,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Режим просмотра (platform admin)',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: _exit,
                child: const Text('Выйти'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
