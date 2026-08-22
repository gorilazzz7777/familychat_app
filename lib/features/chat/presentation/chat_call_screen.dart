import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/call/call_lock_screen.dart';
import '../../../core/call/call_proximity_controller.dart';
import '../../../core/widgets/family_app_bar.dart';
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
    this.isVideo = false,
  });

  final int threadId;
  final String title;
  final int? callId;
  final bool isCaller;
  final bool autoAccept;
  /// Стартовый режим: видеозвонок (камера сразу) или аудио (камера выкл.).
  final bool isVideo;

  @override
  ConsumerState<ChatCallScreen> createState() => _ChatCallScreenState();
}

class _ChatCallScreenState extends ConsumerState<ChatCallScreen>
    with WidgetsBindingObserver {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  RTCSessionDescription? _localOffer;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  int? _callId;
  String _stateText = 'Подключение...';
  bool _busy = true;
  bool _ended = false;
  bool _remoteDescriptionSet = false;
  bool _processingSignals = false;
  bool _renegotiating = false;
  int _lastPersistedSignalId = 0;
  final Set<String> _sentIce = <String>{};
  final List<Map<String, dynamic>> _pendingSignals = [];
  final List<Map<String, dynamic>> _pendingIce = [];
  int? _myUserId;
  bool _speakerOn = false;
  bool _micMuted = false;
  bool _localVideoEnabled = false;
  bool _usingFrontCamera = true;
  bool _remoteHasVideo = false;
  bool _renderersReady = false;

  bool _showingMicHint = false;
  bool _showingCamHint = false;

  bool _shouldAcceptSignal(String type, {int? fromUserId}) {
    if (fromUserId != null && _myUserId != null && fromUserId == _myUserId) {
      return false;
    }
    // offer+answer: initial + mid-call renegotiation from either side
    return type == 'ice' || type == 'offer' || type == 'answer';
  }

  int? _parseUserId(Object? raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  int? _parseCallId(Object? raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String _friendlyCallError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 500) {
        return 'Ошибка сервера при звонке. Убедитесь, что сервер обновлён и миграции применены.';
      }
      if (status != null) {
        return 'Ошибка сети при звонке (код $status). Попробуйте ещё раз.';
      }
    }
    final text = '$error';
    if (text.contains('NotAllowedError') || text.contains('PermissionDenied')) {
      return 'Нет доступа к микрофону или камере. Разрешите в настройках и попробуйте снова.';
    }
    if (text.contains('NotFoundError') || text.contains('DevicesNotFoundError')) {
      return 'Микрофон или камера не найдены на устройстве.';
    }
    if (text.contains('NotReadableError')) {
      return 'Не удалось получить доступ к устройству. Возможно, оно занято другим приложением.';
    }
    return 'Не удалось начать звонок. Попробуйте еще раз.';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _localVideoEnabled = widget.isVideo;
    unawaited(CallLockScreen.acquire());
    if (!widget.isCaller && widget.callId != null) {
      _callId = widget.callId;
    }
    FamilyChatRealtime.instance.addListener(_onRealtime);
    unawaited(_initCall());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    unawaited(CallLockScreen.release());
    unawaited(_cleanup());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncProximity());
    } else {
      unawaited(CallProximityController.disable());
    }
  }

  Future<void> _initRenderers() async {
    if (_renderersReady) return;
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _renderersReady = true;
  }

  Map<String, dynamic> _videoConstraints() {
    // Prefer ideal size (no hard crop). Fixed 640x480 made many phone cameras
    // look digitally zoomed when shown with objectFit Cover.
    return {
      'facingMode': _usingFrontCamera ? 'user' : 'environment',
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
    };
  }

  Future<void> _initCall() async {
    try {
      await _initRenderers();
      final status = await ref.read(familychatRepositoryProvider).status();
      _myUserId = _parseUserId(status['user_id']);
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
      if (_localVideoEnabled) {
        final cam = await _ensureCameraPermission();
        if (!cam.granted) {
          if (!mounted) return;
          setState(() {
            _stateText = 'Нет доступа к камере';
            _busy = false;
            _localVideoEnabled = false;
          });
          if (cam.shouldOpenSettingsHint) {
            await _showCameraPermissionHint();
          }
          return;
        }
      }
      final repo = ref.read(familychatRepositoryProvider);
      final ice = await repo.threadCallIceServers(widget.threadId);
      _peer = await createPeerConnection({'iceServers': ice});
      _peer!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams[0];
        } else if (event.track.kind == 'video') {
          // Some platforms deliver track without stream list.
          final stream = _remoteRenderer.srcObject;
          if (stream != null) {
            unawaited(stream.addTrack(event.track));
          }
        }
        final hasVideo = event.track.kind == 'video' && event.track.enabled;
        if (mounted) {
          setState(() {
            if (event.track.kind == 'video') {
              _remoteHasVideo = hasVideo;
            }
            if (_remoteDescriptionSet) {
              _stateText = 'Разговор идет';
            }
          });
        }
        event.track.onEnded = () {
          if (!mounted) return;
          if (event.track.kind == 'video') {
            setState(() => _remoteHasVideo = false);
          }
        };
      };
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _localVideoEnabled ? _videoConstraints() : false,
      });
      _localRenderer.srcObject = _localStream;
      for (final track in _localStream!.getTracks()) {
        await _peer!.addTrack(track, _localStream!);
      }
      final preferSpeaker = _localVideoEnabled;
      await _setSpeakerphone(preferSpeaker);
      await _syncProximity();
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
        final started = await repo.startThreadCall(
          widget.threadId,
          isVideo: widget.isVideo,
        );
        _callId = _parseCallId(started['id']);
        if (_callId == null) {
          throw StateError('Сервер не вернул id звонка');
        }
        final offer = await _peer!.createOffer();
        await _peer!.setLocalDescription(offer);
        _localOffer = offer;
        await repo.sendCallSignal(
          _callId!,
          signalType: 'offer',
          payload: {'sdp': offer.sdp, 'type': offer.type},
        );
        if (!mounted) return;
        setState(() {
          _stateText = widget.isVideo ? 'Видеозвонок...' : 'Звоним...';
          _busy = false;
        });
      } else {
        _callId ??= widget.callId;
        if (_callId == null) {
          throw StateError('Не передан callId');
        }
        if (widget.autoAccept) {
          await repo.callAction(_callId!, 'accept');
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
      if ('$e'.contains('NotAllowedError') && kIsWeb) {
        await _showMicPermissionHint();
      }
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

  Future<({bool granted, bool shouldOpenSettingsHint})>
      _ensureCameraPermission() async {
    if (kIsWeb) {
      try {
        final testStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': true,
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
    final status = await Permission.camera.request();
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
          'Для звонка разрешите доступ к микрофону. После этого нажмите "Повторить".',
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

  Future<void> _showCameraPermissionHint() async {
    if (!mounted || _showingCamHint) return;
    _showingCamHint = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Нужен доступ к камере'),
        content: const Text(
          'Для видеозвонка разрешите доступ к камере в настройках.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () async {
              await openAppSettings();
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Настройки'),
          ),
        ],
      ),
    );
    _showingCamHint = false;
  }

  Future<void> _setSpeakerphone(bool enabled) async {
    if (kIsWeb) {
      if (mounted) setState(() => _speakerOn = enabled);
      return;
    }
    try {
      await Helper.setSpeakerphoneOn(enabled);
      if (mounted) setState(() => _speakerOn = enabled);
      await _syncProximity();
    } catch (e) {
      debugPrint('speaker toggle failed: $e');
    }
  }

  Future<void> _syncProximity() async {
    if (kIsWeb || _ended) return;
    // Proximity sensor only when earpiece + no local video.
    final useProximity = !_speakerOn && !_localVideoEnabled;
    await CallProximityController.setEnabled(useProximity);
  }

  Future<void> _toggleSpeaker() async {
    await _setSpeakerphone(!_speakerOn);
  }

  void _toggleMic() {
    final stream = _localStream;
    if (stream == null || _busy) return;
    final nextMuted = !_micMuted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !nextMuted;
    }
    setState(() => _micMuted = nextMuted);
  }

  Future<void> _renegotiateAsOfferer() async {
    if (_peer == null || _callId == null || _renegotiating) return;
    _renegotiating = true;
    try {
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      _localOffer = offer;
      await ref.read(familychatRepositoryProvider).sendCallSignal(
            _callId!,
            signalType: 'offer',
            payload: {'sdp': offer.sdp, 'type': offer.type},
          );
    } finally {
      _renegotiating = false;
    }
  }

  Future<void> _toggleLocalVideo() async {
    if (_busy || _peer == null || _localStream == null) return;
    if (_localVideoEnabled) {
      await _disableLocalVideo(renegotiate: true);
      return;
    }
    final cam = await _ensureCameraPermission();
    if (!cam.granted) {
      if (cam.shouldOpenSettingsHint) {
        await _showCameraPermissionHint();
      }
      return;
    }
    try {
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': _videoConstraints(),
      });
      final videoTracks = videoStream.getVideoTracks();
      if (videoTracks.isEmpty) {
        await videoStream.dispose();
        return;
      }
      final videoTrack = videoTracks.first;
      await _localStream!.addTrack(videoTrack);
      await _peer!.addTrack(videoTrack, _localStream!);
      _localRenderer.srcObject = _localStream;
      if (mounted) {
        setState(() => _localVideoEnabled = true);
      }
      if (!_speakerOn) {
        await _setSpeakerphone(true);
      }
      await _syncProximity();
      await _renegotiateAsOfferer();
    } catch (e) {
      debugPrint('enable local video failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyCallError(e))),
        );
      }
    }
  }

  Future<void> _disableLocalVideo({required bool renegotiate}) async {
    if (_peer == null || _localStream == null) return;
    final videoTracks = List<MediaStreamTrack>.from(
      _localStream!.getVideoTracks(),
    );
    final senders = await _peer!.getSenders();
    for (final track in videoTracks) {
      for (final sender in senders) {
        if (sender.track?.id == track.id) {
          try {
            await _peer!.removeTrack(sender);
          } catch (_) {}
        }
      }
      try {
        await _localStream!.removeTrack(track);
      } catch (_) {}
      try {
        await track.stop();
      } catch (_) {}
    }
    _localRenderer.srcObject = _localStream;
    if (mounted) {
      setState(() => _localVideoEnabled = false);
    }
    await _syncProximity();
    if (renegotiate) {
      await _renegotiateAsOfferer();
    }
  }

  Future<void> _flipCamera() async {
    if (!_localVideoEnabled || _localStream == null) return;
    final tracks = _localStream!.getVideoTracks();
    if (tracks.isEmpty) return;
    try {
      if (!kIsWeb) {
        await Helper.switchCamera(tracks.first);
        if (mounted) {
          setState(() => _usingFrontCamera = !_usingFrontCamera);
        }
        return;
      }
      // Web: recreate video track with opposite facingMode.
      _usingFrontCamera = !_usingFrontCamera;
      await _disableLocalVideo(renegotiate: false);
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': _videoConstraints(),
      });
      final videoTrack = videoStream.getVideoTracks().first;
      await _localStream!.addTrack(videoTrack);
      await _peer!.addTrack(videoTrack, _localStream!);
      _localRenderer.srcObject = _localStream;
      if (mounted) setState(() => _localVideoEnabled = true);
      await _renegotiateAsOfferer();
    } catch (e) {
      debugPrint('flip camera failed: $e');
    }
  }

  bool _cleaned = false;

  Future<void> _cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    await CallProximityController.disable();
    if (!kIsWeb) {
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (_) {}
    }
    try {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
    } catch (_) {}
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await _peer?.close();
    } catch (_) {}
    _peer = null;
    if (_renderersReady) {
      try {
        await _localRenderer.dispose();
      } catch (_) {}
      try {
        await _remoteRenderer.dispose();
      } catch (_) {}
      _renderersReady = false;
    }
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
      final stored = await ref
          .read(familychatRepositoryProvider)
          .callSignals(_callId!, afterId: _lastPersistedSignalId);
      for (final item in stored) {
        final signalId = _parseCallId(item['id']);
        if (signalId != null && signalId > _lastPersistedSignalId) {
          _lastPersistedSignalId = signalId;
        }
        final type = item['signal_type']?.toString() ?? '';
        final payload = item['payload'];
        final fromUserId = _parseUserId(item['from_user_id']);
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
    await ref.read(familychatRepositoryProvider).sendCallSignal(
          _callId!,
          signalType: 'offer',
          payload: {'sdp': _localOffer!.sdp, 'type': _localOffer!.type},
        );
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
        if (widget.isCaller) {
          unawaited(_maybeResendOffer());
        }
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
    final payload = event['payload'] as Map<String, dynamic>? ?? const {};
    final fromUserId = _parseUserId(event['from_user_id']);
    _enqueueSignal(type, payload, fromUserId: fromUserId);
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
    await ref.read(familychatRepositoryProvider).sendCallSignal(
          _callId!,
          signalType: 'answer',
          payload: {'sdp': answer.sdp, 'type': answer.type},
        );
    _refreshRemoteVideoFlag();
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
    _refreshRemoteVideoFlag();
    if (!mounted) return;
    setState(() => _stateText = 'Разговор идет');
    await _flushPendingIce();
  }

  void _refreshRemoteVideoFlag() {
    final stream = _remoteRenderer.srcObject;
    if (stream == null) {
      _remoteHasVideo = false;
      return;
    }
    _remoteHasVideo = stream.getVideoTracks().any((t) => t.enabled);
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
        await ref.read(familychatRepositoryProvider).callAction(cid, 'end');
      } catch (_) {}
    }
    await _cleanup();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Widget _buildVideoStage(BuildContext context) {
    final showRemote = _remoteHasVideo && _remoteRenderer.srcObject != null;
    final showLocal = _localVideoEnabled && _localRenderer.srcObject != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xFF0F1419),
          child: showRemote
              ? RTCVideoView(
                  _remoteRenderer,
                  // Contain = full frame (no crop/"zoom"). Cover fills screen by cropping.
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isVideo || _localVideoEnabled
                            ? Icons.videocam_outlined
                            : Icons.call,
                        size: 64,
                        color: Colors.white54,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _stateText,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                            ),
                      ),
                    ],
                  ),
                ),
        ),
        if (showRemote)
          Positioned(
            left: 16,
            right: 16,
            top: 12,
            child: Text(
              _stateText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        if (showLocal)
          Positioned(
            right: 16,
            top: 48,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 110,
                height: 160,
                child: RTCVideoView(
                  _localRenderer,
                  mirror: _usingFrontCamera,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _circleControl({
    required IconData icon,
    required VoidCallback? onPressed,
    Color background = const Color(0xFF2A2F36),
    Color foreground = Colors.white,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: foreground),
        iconSize: 28,
        padding: const EdgeInsets.all(14),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titlePrefix = widget.isVideo || _localVideoEnabled
        ? 'Видеозвонок'
        : 'Звонок';
    final stage = Column(
      children: [
        Expanded(child: _buildVideoStage(context)),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _circleControl(
                  icon: _micMuted ? Icons.mic_off : Icons.mic,
                  background: _micMuted
                      ? const Color(0xFF5A2A2A)
                      : const Color(0xFF2A2F36),
                  onPressed: _busy ? null : _toggleMic,
                ),
                if (!kIsWeb)
                  _circleControl(
                    icon: _speakerOn
                        ? Icons.volume_up
                        : Icons.phone_in_talk,
                    onPressed:
                        _busy ? null : () => unawaited(_toggleSpeaker()),
                  ),
                _circleControl(
                  icon: _localVideoEnabled
                      ? Icons.videocam
                      : Icons.videocam_off,
                  onPressed:
                      _busy ? null : () => unawaited(_toggleLocalVideo()),
                ),
                if (_localVideoEnabled)
                  _circleControl(
                    icon: Icons.cameraswitch,
                    onPressed:
                        _busy ? null : () => unawaited(_flipCamera()),
                  ),
                _circleControl(
                  icon: Icons.call_end,
                  background: Colors.red,
                  onPressed: _busy ? null : () => unawaited(_hangup()),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_hangup());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F1419),
        appBar: FamilyAppBar.build(
          title: '$titlePrefix: ${widget.title}',
        ),
        body: stage,
      ),
    );
  }
}
