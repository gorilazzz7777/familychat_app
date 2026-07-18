import 'dart:async';

import 'package:flutter/material.dart';

import '../../contract/chat_call_repository.dart';
import '../../realtime/gorila_chat_realtime.dart';
import '../widgets/chat_avatar.dart';
import 'chat_call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.threadId,
    required this.callerUserId,
    required this.callerName,
    required this.callRepository,
    required this.realtime,
    this.myUserId,
    this.callerAvatarUrl,
    this.onHandled,
  });

  final int callId;
  final int threadId;
  final int callerUserId;
  final String callerName;
  final ChatCallRepository callRepository;
  final GorilaChatRealtime realtime;
  final int? myUserId;
  final String? callerAvatarUrl;
  final VoidCallback? onHandled;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool _busy = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.realtime.addListener(_onRealtime);
  }

  @override
  void dispose() {
    widget.realtime.removeListener(_onRealtime);
    widget.onHandled?.call();
    super.dispose();
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
    if (status == 'ended' || status == 'declined' || status == 'missed') {
      unawaited(_close());
    }
  }

  Future<void> _close() async {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.callRepository.callAction(widget.callId, 'decline');
    } catch (_) {}
    await _close();
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    nav.pop();
    await nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatCallScreen(
          threadId: widget.threadId,
          title: widget.callerName,
          callId: widget.callId,
          isCaller: false,
          autoAccept: true,
          callRepository: widget.callRepository,
          realtime: widget.realtime,
          myUserId: widget.myUserId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              ChatAvatar(
                name: widget.callerName,
                avatarUrl: widget.callerAvatarUrl,
                radius: 48,
              ),
              const SizedBox(height: 20),
              Text(
                widget.callerName,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Входящий звонок',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundAction(
                    color: Colors.red,
                    icon: Icons.call_end,
                    label: 'Отклонить',
                    onTap: _busy ? null : () => unawaited(_decline()),
                  ),
                  _RoundAction(
                    color: Colors.green,
                    icon: Icons.call,
                    label: 'Ответить',
                    onTap: _busy ? null : () => unawaited(_accept()),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 72,
              height: 72,
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label),
      ],
    );
  }
}
