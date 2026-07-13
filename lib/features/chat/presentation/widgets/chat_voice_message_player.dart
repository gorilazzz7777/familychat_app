import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_voice_utils.dart';
import 'chat_network_image.dart';

class ChatVoiceMessagePlayer extends ConsumerStatefulWidget {
  const ChatVoiceMessagePlayer({
    super.key,
    required this.threadId,
    required this.attachment,
    required this.isMine,
    this.durationMs,
    this.textColor,
    this.metaColor,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final bool isMine;
  final int? durationMs;
  final Color? textColor;
  final Color? metaColor;

  @override
  ConsumerState<ChatVoiceMessagePlayer> createState() =>
      _ChatVoiceMessagePlayerState();
}

class _ChatVoiceMessagePlayerState extends ConsumerState<ChatVoiceMessagePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    final durationMs = widget.durationMs;
    if (durationMs != null && durationMs > 0) {
      _total = Duration(milliseconds: durationMs);
    }
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _total = duration);
    });
    _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _player.pause();
      return;
    }

    final localBytes = widget.attachment['local_bytes'];
    if (localBytes is Uint8List && localBytes.isNotEmpty) {
      await _player.play(BytesSource(localBytes));
      return;
    }

    final repo = ref.read(familychatRepositoryProvider);
    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: widget.threadId,
      attachment: widget.attachment,
    );
    if (url.isEmpty) return;
    await _player.play(UrlSource(url));
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor ?? Theme.of(context).colorScheme.onSurface;
    final metaColor = widget.metaColor ?? textColor.withValues(alpha: 0.75);
    final totalMs = _total.inMilliseconds > 0
        ? _total.inMilliseconds
        : (widget.durationMs ?? 0);
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final label = _playing || _position.inMilliseconds > 0
        ? formatVoiceDuration(_position.inMilliseconds)
        : formatVoiceDuration(totalMs);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: _togglePlayback,
          icon: Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: textColor,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 120,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 3,
                  backgroundColor: metaColor.withValues(alpha: 0.25),
                  color: textColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: metaColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
