import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/call_ringtone_controller.dart';
import '../../../core/notifications/familychat_notifications.dart';
import '../../../core/providers/app_providers.dart';
import '../data/familychat_realtime.dart';
import '../data/incoming_call_coordinator.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'chat_call_screen.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.threadId,
    required this.callerUserId,
    required this.callerName,
  });

  final int callId;
  final int threadId;
  final int callerUserId;
  final String callerName;

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  Map<String, dynamic>? _profile;
  bool _busy = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    unawaited(_loadProfile());
    unawaited(CallRingtoneController.instance.startIncomingCall());
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    unawaited(CallRingtoneController.instance.stop());
    unawaited(FamilyChatNotifications.cancelCallNotification(widget.callId));
    IncomingCallCoordinator.instance.markHandled(widget.callId);
    super.dispose();
  }

  Future<void> _loadProfile() async {
    if (widget.callerUserId <= 0) return;
    try {
      final profile = await ref
          .read(familychatRepositoryProvider)
          .memberProfile(widget.callerUserId);
      if (!mounted) return;
      setState(() => _profile = profile);
    } catch (_) {}
  }

  void _onRealtime(Map<String, dynamic> event) {
    if (_closed) return;
    final eventCallId = event['session_id'] is int
        ? event['session_id'] as int
        : int.tryParse('${event['session_id']}');
    if (eventCallId != widget.callId) return;
    final ev = event['event']?.toString();
    if (ev != 'chat_call_state') return;
    final status = event['status']?.toString() ?? '';
    if (status == 'ended' ||
        status == 'declined' ||
        status == 'missed') {
      unawaited(_close());
    }
  }

  String get _displayName {
    final fromProfile = _profile?['display_name']?.toString().trim();
    if (fromProfile != null && fromProfile.isNotEmpty) return fromProfile;
    return widget.callerName;
  }

  String? get _avatarUrl {
    final url = _profile?['avatar_url']?.toString().trim();
    if (url != null && url.isNotEmpty) return url;
    return null;
  }

  String? get _kinshipLabel {
    final label = _profile?['kinship_label']?.toString().trim();
    if (label != null && label.isNotEmpty && label != 'Вы') return label;
    return null;
  }

  Future<void> _close() async {
    if (_closed || !mounted) return;
    _closed = true;
    await CallRingtoneController.instance.stop();
    await FamilyChatNotifications.cancelCallNotification(widget.callId);
    IncomingCallCoordinator.instance.markHandled(widget.callId);
    if (!mounted) return;
    setState(() {});
    Navigator.of(context).pop();
  }

  Future<void> _decline() async {
    if (_busy || _closed) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(familychatRepositoryProvider)
          .callAction(widget.callId, 'decline');
    } catch (_) {}
    await _close();
  }

  Future<void> _answer() async {
    if (_busy || _closed) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(familychatRepositoryProvider)
          .callAction(widget.callId, 'accept');
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    _closed = true;
    await CallRingtoneController.instance.stop();
    await FamilyChatNotifications.cancelCallNotification(widget.callId);
    IncomingCallCoordinator.instance.markHandled(widget.callId);
    final nav = Navigator.of(context);
    nav.pop();
    unawaited(
      nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatCallScreen(
            threadId: widget.threadId,
            title: _displayName,
            callId: widget.callId,
            isCaller: false,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: _closed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) unawaited(_decline());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F1419),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                const SizedBox(height: 24),
                Text(
                  'Входящий звонок',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                const Spacer(flex: 2),
                ChatAvatar(
                  name: _displayName,
                  avatarUrl: _avatarUrl,
                  radius: 72,
                ),
                const SizedBox(height: 24),
                Text(
                  _displayName,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_kinshipLabel != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _kinshipLabel!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white60,
                    ),
                  ),
                ],
                const Spacer(flex: 3),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallActionButton(
                      label: 'Сбросить',
                      color: Colors.red.shade600,
                      icon: Icons.call_end,
                      onPressed: _busy ? null : () => unawaited(_decline()),
                    ),
                    _CallActionButton(
                      label: 'Ответить',
                      color: Colors.green.shade600,
                      icon: Icons.call,
                      onPressed: _busy ? null : () => unawaited(_answer()),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 72,
              height: 72,
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white,
              ),
        ),
      ],
    );
  }
}
