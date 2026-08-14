import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_screen_keep_on.dart';
import 'app_settings_controller.dart';
import 'screen_timeout.dart';

/// Держит экран включённым по настройке автоугасания, пока приложение на экране.
class ScreenTimeoutGuard extends ConsumerStatefulWidget {
  const ScreenTimeoutGuard({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ScreenTimeoutGuard> createState() => _ScreenTimeoutGuardState();
}

class _ScreenTimeoutGuardState extends ConsumerState<ScreenTimeoutGuard>
    with WidgetsBindingObserver {
  Timer? _idleTimer;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onActivity());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    unawaited(AppScreenKeepOn.setAppPolicy(false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _onActivity();
    } else {
      _idleTimer?.cancel();
      unawaited(AppScreenKeepOn.setAppPolicy(false));
    }
  }

  void _onActivity() {
    if (!_resumed) return;
    _idleTimer?.cancel();
    final option = ref.read(appSettingsProvider).screenTimeout;
    if (option == ScreenTimeoutOption.system) {
      unawaited(AppScreenKeepOn.setAppPolicy(false));
      return;
    }
    if (option == ScreenTimeoutOption.never) {
      unawaited(AppScreenKeepOn.setAppPolicy(true));
      return;
    }
    unawaited(AppScreenKeepOn.setAppPolicy(true));
    final duration = option.idleDuration;
    if (duration == null) return;
    _idleTimer = Timer(duration, () {
      unawaited(AppScreenKeepOn.setAppPolicy(false));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      appSettingsProvider.select((s) => s.screenTimeout),
      (_, __) => _onActivity(),
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onActivity(),
      child: widget.child,
    );
  }
}
