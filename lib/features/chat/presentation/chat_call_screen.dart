import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/providers/app_providers.dart';
import '../data/familychat_realtime.dart';

class ChatCallScreen extends ConsumerStatefulWidget {
  const ChatCallScreen({
    super.key,
    required this.threadId,
    required this.title,
    this.callId,
    this.isCaller = false,
    this.autoAccept = false,
  });

  final int threadId;
  final String title;
  final int? callId;
  final bool isCaller;
  final bool autoAccept;

  @override
  ConsumerState<ChatCallScreen> createState() => _ChatCallScreenState();
}

class _ChatCallScreenState extends ConsumerState<ChatCallScreen> {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  int? _callId;
  String _stateText = 'Подключение...';
  bool _busy = true;
  bool _ended = false;
  final Set<String> _sentIce = <String>{};

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    unawaited(_initCall());
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _initCall() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final ice = await repo.threadCallIceServers(widget.threadId);
      _peer = await createPeerConnection({'iceServers': ice});
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getAudioTracks()) {
        await _peer!.addTrack(track, _localStream!);
      }
      _peer!.onIceCandidate = (candidate) {
        final cid = _callId;
        if (cid == null) return;
        final payload = {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        };
        final key =
            '${payload['candidate']}:${payload['sdpMid']}:${payload['sdpMLineIndex']}';
        if (_sentIce.contains(key)) return;
        _sentIce.add(key);
        unawaited(
            repo.sendCallSignal(cid, signalType: 'ice', payload: payload));
      };

      if (widget.isCaller) {
        final started = await repo.startThreadCall(widget.threadId);
        _callId = started['id'] as int?;
        final offer = await _peer!.createOffer();
        await _peer!.setLocalDescription(offer);
        await repo.sendCallSignal(
          _callId!,
          signalType: 'offer',
          payload: {'sdp': offer.sdp, 'type': offer.type},
        );
        setState(() {
          _stateText = 'Звоним...';
          _busy = false;
        });
      } else {
        _callId = widget.callId;
        if (_callId == null) {
          throw StateError('Не передан callId');
        }
        if (widget.autoAccept) {
          await repo.callAction(_callId!, 'accept');
        }
        setState(() {
          _stateText = 'Ожидание соединения...';
          _busy = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stateText = 'Ошибка звонка: $e';
        _busy = false;
      });
    }
  }

  Future<void> _cleanup() async {
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await _peer?.close();
    } catch (_) {}
    _peer = null;
  }

  void _onRealtime(Map<String, dynamic> event) {
    final cid = _callId;
    if (cid == null) return;
    final eventCallId = event['session_id'] is int
        ? event['session_id'] as int
        : int.tryParse('${event['session_id']}');
    if (eventCallId != cid) return;
    final ev = event['event']?.toString();
    if (ev == 'chat_call_state') {
      final status = event['status']?.toString() ?? '';
      if (!mounted) return;
      if (status == 'active') {
        setState(() => _stateText = 'Разговор идет');
      } else if (status == 'declined') {
        setState(() => _stateText = 'Звонок отклонен');
        unawaited(_hangup(localOnly: true));
      } else if (status == 'ended' || status == 'missed') {
        setState(() => _stateText = 'Звонок завершен');
        unawaited(_hangup(localOnly: true));
      }
      return;
    }
    if (ev != 'chat_call_signal') return;
    final type = event['signal_type']?.toString() ?? '';
    final payload = event['payload'] as Map<String, dynamic>? ?? const {};
    if (type == 'offer') {
      unawaited(_handleOffer(payload));
    } else if (type == 'answer') {
      unawaited(_handleAnswer(payload));
    } else if (type == 'ice') {
      unawaited(_handleIce(payload));
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    if (_peer == null || _callId == null) return;
    final sdp = payload['sdp']?.toString();
    final type = payload['type']?.toString() ?? 'offer';
    if (sdp == null || sdp.isEmpty) return;
    await _peer!.setRemoteDescription(RTCSessionDescription(sdp, type));
    final answer = await _peer!.createAnswer();
    await _peer!.setLocalDescription(answer);
    await ref.read(familychatRepositoryProvider).sendCallSignal(
      _callId!,
      signalType: 'answer',
      payload: {'sdp': answer.sdp, 'type': answer.type},
    );
    if (!mounted) return;
    setState(() => _stateText = 'Разговор идет');
  }

  Future<void> _handleAnswer(Map<String, dynamic> payload) async {
    if (_peer == null) return;
    final sdp = payload['sdp']?.toString();
    final type = payload['type']?.toString() ?? 'answer';
    if (sdp == null || sdp.isEmpty) return;
    await _peer!.setRemoteDescription(RTCSessionDescription(sdp, type));
    if (!mounted) return;
    setState(() => _stateText = 'Разговор идет');
  }

  Future<void> _handleIce(Map<String, dynamic> payload) async {
    if (_peer == null) return;
    final candidate = payload['candidate']?.toString();
    if (candidate == null || candidate.isEmpty) return;
    final sdpMid = payload['sdpMid']?.toString();
    final sdpMLineIndex = payload['sdpMLineIndex'] is int
        ? payload['sdpMLineIndex'] as int
        : int.tryParse('${payload['sdpMLineIndex']}');
    await _peer!.addCandidate(
      RTCIceCandidate(candidate, sdpMid, sdpMLineIndex),
    );
  }

  Future<void> _hangup({bool localOnly = false}) async {
    if (_ended) return;
    _ended = true;
    final cid = _callId;
    if (!localOnly && cid != null) {
      try {
        await ref.read(familychatRepositoryProvider).callAction(cid, 'end');
      } catch (_) {}
    }
    await _cleanup();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_hangup());
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Звонок: ${widget.title}')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.call, size: 56),
                const SizedBox(height: 16),
                Text(
                  _stateText,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _busy ? null : () => unawaited(_hangup()),
                  icon: const Icon(Icons.call_end),
                  label: const Text('Завершить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
