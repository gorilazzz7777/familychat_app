import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../contract/chat_call_repository.dart';
import '../../realtime/gorila_chat_realtime.dart';

/// Shared audio call screen (Family Chat reference behaviour + remote onTrack).
class ChatCallScreen extends StatefulWidget {
  const ChatCallScreen({
    super.key,
    required this.threadId,
    required this.title,
    required this.callRepository,
    required this.realtime,
    required this.myUserId,
    this.callId,
    this.isCaller = false,
    this.autoAccept = false,
  });

  final int threadId;
  final String title;
  final ChatCallRepository callRepository;
  final GorilaChatRealtime realtime;
  final int? myUserId;
  final int? callId;
  final bool isCaller;
  final bool autoAccept;

  @override
  State<ChatCallScreen> createState() => _ChatCallScreenState();
}

class _ChatCallScreenState extends State<ChatCallScreen> {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  RTCSessionDescription? _localOffer;
  int? _callId;
  String _stateText = 'Подключение...';
  bool _busy = true;
  bool _ended = false;
  bool _remoteDescriptionSet = false;
  bool _processingSignals = false;
  int _lastPersistedSignalId = 0;
  final Set<String> _sentIce = <String>{};
  final List<Map<String, dynamic>> _pendingSignals = [];
  final List<Map<String, dynamic>> _pendingIce = [];
  bool _speakerOn = false;
  bool _showingMicHint = false;
  Timer? _signalPollTimer;

  ChatCallRepository get _repo => widget.callRepository;

  bool _shouldAcceptSignal(String type, {int? fromUserId}) {
    if (fromUserId != null &&
        widget.myUserId != null &&
        fromUserId == widget.myUserId) {
      return false;
    }
    if (type == 'ice') return true;
    if (widget.isCaller) return type == 'answer';
    return type == 'offer';
  }

  int? _parseId(Object? raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String _friendlyCallError(Object error) {
    final text = '$error';
    if (text.contains('500')) {
      return 'Ошибка сервера при звонке. Убедитесь, что сервер обновлён.';
    }
    if (text.contains('NotAllowedError') || text.contains('PermissionDenied')) {
      return 'Доступ к микрофону не разрешен. Разрешите его в настройках.';
    }
    return 'Не удалось начать звонок. Попробуйте еще раз.';
  }

  @override
  void initState() {
    super.initState();
    if (!widget.isCaller && widget.callId != null) {
      _callId = widget.callId;
    }
    widget.realtime.addListener(_onRealtime);
    _signalPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_callId != null && !_ended) unawaited(_syncCallSignals());
    });
    unawaited(_initCall());
  }

  @override
  void dispose() {
    _signalPollTimer?.cancel();
    widget.realtime.removeListener(_onRealtime);
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _initCall() async {
    try {
      final micPermission = await _ensureMicrophonePermission();
      if (!micPermission.granted) {
        if (!mounted) return;
        setState(() {
          _stateText = 'Нет доступа к микрофону';
          _busy = false;
        });
        if (micPermission.shouldOpenSettingsHint) {
          await _showMicPermissionHint();
        }
        return;
      }
      final ice = await _repo.iceServers(widget.threadId);
      _peer = await createPeerConnection({'iceServers': ice});
      _peer!.onTrack = (event) {
        // Ensure remote audio track is enabled (iOS/Android).
        try {
          event.track.enabled = true;
        } catch (_) {}
        if (mounted) setState(() => _stateText = 'Разговор идет');
      };
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in _localStream!.getAudioTracks()) {
        await _peer!.addTrack(track, _localStream!);
      }
      await _setSpeakerphone(false);
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
          _repo.sendSignal(cid, signalType: 'ice', payload: payload),
        );
      };

      if (widget.isCaller) {
        final started = await _repo.startCall(widget.threadId);
        _callId = _parseId(started['id']);
        if (_callId == null) {
          throw StateError('Сервер не вернул id звонка');
        }
        final offer = await _peer!.createOffer();
        await _peer!.setLocalDescription(offer);
        _localOffer = offer;
        await _repo.sendSignal(
          _callId!,
          signalType: 'offer',
          payload: {'sdp': offer.sdp, 'type': offer.type},
        );
        if (!mounted) return;
        setState(() {
          _stateText = 'Звоним...';
          _busy = false;
        });
      } else {
        _callId ??= widget.callId;
        if (_callId == null) throw StateError('Не передан callId');
        if (widget.autoAccept) {
          await _repo.callAction(_callId!, 'accept');
        }
        if (!mounted) return;
        setState(() {
          _stateText = 'Ожидание соединения...';
          _busy = false;
        });
      }
      await _syncCallSignals();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stateText = _friendlyCallError(e);
        _busy = false;
      });
    }
  }

  Future<({bool granted, bool shouldOpenSettingsHint})>
      _ensureMicrophonePermission() async {
    if (kIsWeb) {
      try {
        final testStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        for (final track in testStream.getTracks()) {
          track.stop();
        }
        await testStream.dispose();
        return (granted: true, shouldOpenSettingsHint: false);
      } catch (_) {
        return (granted: false, shouldOpenSettingsHint: true);
      }
    }
    final status = await Permission.microphone.request();
    if (status.isGranted) {
      return (granted: true, shouldOpenSettingsHint: false);
    }
    final needsSettings = status.isPermanentlyDenied || status.isRestricted;
    return (granted: false, shouldOpenSettingsHint: needsSettings);
  }

  Future<void> _showMicPermissionHint() async {
    if (!mounted || _showingMicHint) return;
    _showingMicHint = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Нужен доступ к микрофону'),
        content: const Text(
          'Для звонка разрешите доступ к микрофону. После этого нажмите «Повторить».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
          TextButton(
            onPressed: () async {
              await openAppSettings();
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Настройки'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() {
                _busy = true;
                _stateText = 'Повторный запрос микрофона...';
              });
              await _initCall();
            },
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
    _showingMicHint = false;
  }

  Future<void> _setSpeakerphone(bool enabled) async {
    if (kIsWeb) return;
    try {
      await Helper.setSpeakerphoneOn(enabled);
      if (mounted) setState(() => _speakerOn = enabled);
    } catch (e) {
      debugPrint('speaker toggle failed: $e');
    }
  }

  Future<void> _cleanup() async {
    if (!kIsWeb) {
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (_) {}
    }
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await _peer?.close();
    } catch (_) {}
    _peer = null;
  }

  void _enqueueSignal(
    String type,
    Map<String, dynamic> payload, {
    int? fromUserId,
  }) {
    if (!_shouldAcceptSignal(type, fromUserId: fromUserId)) return;
    _pendingSignals.add({'signal_type': type, 'payload': payload});
    unawaited(_processPendingSignals());
  }

  Future<void> _syncCallSignals() async {
    try {
      await _loadPersistedSignals();
      await _processPendingSignals();
    } catch (e, st) {
      debugPrint('call signal sync warning: $e\n$st');
    }
  }

  Future<void> _loadPersistedSignals() async {
    if (_callId == null) return;
    try {
      final stored =
          await _repo.listSignals(_callId!, afterId: _lastPersistedSignalId);
      for (final item in stored) {
        final signalId = _parseId(item['id']);
        if (signalId != null && signalId > _lastPersistedSignalId) {
          _lastPersistedSignalId = signalId;
        }
        final type = item['signal_type']?.toString() ?? '';
        final payload = item['payload'];
        final fromUserId = _parseId(item['from_user_id']);
        if (!_shouldAcceptSignal(type, fromUserId: fromUserId)) continue;
        _pendingSignals.add({
          'signal_type': type,
          'payload': payload is Map
              ? Map<String, dynamic>.from(payload)
              : <String, dynamic>{},
        });
      }
    } catch (e, st) {
      debugPrint('call persisted signals load failed: $e\n$st');
    }
  }

  Future<void> _processPendingSignals() async {
    if (_peer == null || _processingSignals) return;
    _processingSignals = true;
    try {
      while (_pendingSignals.isNotEmpty && _peer != null) {
        final item = _pendingSignals.removeAt(0);
        try {
          await _applySignal(
            item['signal_type']?.toString() ?? '',
            item['payload'] as Map<String, dynamic>? ?? const {},
          );
        } catch (e, st) {
          debugPrint('call signal apply failed: $e\n$st');
        }
      }
      await _flushPendingIce();
    } finally {
      _processingSignals = false;
    }
  }

  Future<void> _maybeResendOffer() async {
    if (!widget.isCaller || _callId == null || _localOffer == null) return;
    await _repo.sendSignal(
      _callId!,
      signalType: 'offer',
      payload: {'sdp': _localOffer!.sdp, 'type': _localOffer!.type},
    );
  }

  void _onRealtime(Map<String, dynamic> event) {
    final cid = _callId;
    if (cid == null) return;
    final eventCallId = _parseId(event['session_id']);
    if (eventCallId != cid) return;
    final ev = event['event']?.toString();
    if (ev == 'chat_call_state') {
      final status = event['status']?.toString() ?? '';
      if (!mounted) return;
      if (status == 'active') {
        if (widget.isCaller) unawaited(_maybeResendOffer());
        unawaited(_syncCallSignals());
        if (_remoteDescriptionSet) {
          setState(() => _stateText = 'Разговор идет');
        }
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
    final payload = event['payload'] is Map
        ? Map<String, dynamic>.from(event['payload'] as Map)
        : <String, dynamic>{};
    _enqueueSignal(type, payload, fromUserId: _parseId(event['from_user_id']));
  }

  Future<void> _applySignal(String type, Map<String, dynamic> payload) async {
    if (_peer == null) {
      _pendingSignals.insert(0, {'signal_type': type, 'payload': payload});
      return;
    }
    if (type == 'offer') {
      await _applyOffer(payload);
    } else if (type == 'answer') {
      await _applyAnswer(payload);
    } else if (type == 'ice') {
      await _applyIce(payload);
    }
  }

  Future<void> _applyOffer(Map<String, dynamic> payload) async {
    if (_peer == null || _callId == null) return;
    final sdp = payload['sdp']?.toString();
    final type = payload['type']?.toString() ?? 'offer';
    if (sdp == null || sdp.isEmpty) return;
    await _peer!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionSet = true;
    final answer = await _peer!.createAnswer();
    await _peer!.setLocalDescription(answer);
    await _repo.sendSignal(
      _callId!,
      signalType: 'answer',
      payload: {'sdp': answer.sdp, 'type': answer.type},
    );
    if (!mounted) return;
    setState(() => _stateText = 'Разговор идет');
    await _flushPendingIce();
  }

  Future<void> _applyAnswer(Map<String, dynamic> payload) async {
    if (_peer == null) return;
    final sdp = payload['sdp']?.toString();
    final type = payload['type']?.toString() ?? 'answer';
    if (sdp == null || sdp.isEmpty) return;
    await _peer!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionSet = true;
    if (!mounted) return;
    setState(() => _stateText = 'Разговор идет');
    await _flushPendingIce();
  }

  Future<void> _applyIce(Map<String, dynamic> payload) async {
    if (!_remoteDescriptionSet) {
      _pendingIce.add(payload);
      return;
    }
    await _addIceCandidate(payload);
  }

  Future<void> _flushPendingIce() async {
    if (!_remoteDescriptionSet || _peer == null) return;
    final queue = List<Map<String, dynamic>>.from(_pendingIce);
    _pendingIce.clear();
    for (final payload in queue) {
      await _addIceCandidate(payload);
    }
  }

  Future<void> _addIceCandidate(Map<String, dynamic> payload) async {
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
        await _repo.callAction(cid, 'end');
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
                if (!kIsWeb) ...[
                  const SizedBox(height: 20),
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_setSpeakerphone(!_speakerOn)),
                    icon: Icon(
                      _speakerOn ? Icons.volume_up : Icons.phone_in_talk,
                    ),
                    label: Text(
                      _speakerOn ? 'Громкая связь вкл.' : 'Громкая связь',
                    ),
                  ),
                ],
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
