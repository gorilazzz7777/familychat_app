import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../core/config/env.dart';
import '../../../core/providers/app_providers.dart';
import '../data/youtube_audio_handler.dart';
import '../data/youtube_links.dart';

/// Fullscreen YouTube proxy player with background audio + media notification.
class YoutubeProxyPlayerScreen extends ConsumerStatefulWidget {
  const YoutubeProxyPlayerScreen({super.key, required this.url});

  final String url;

  static Future<void> open(BuildContext context, String url) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => YoutubeProxyPlayerScreen(url: url),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  ConsumerState<YoutubeProxyPlayerScreen> createState() =>
      _YoutubeProxyPlayerScreenState();
}

class _YoutubeProxyPlayerScreenState extends ConsumerState<YoutubeProxyPlayerScreen>
    with WidgetsBindingObserver {
  String? _playbackUrl;
  String? _error;
  bool _loading = true;
  String _title = 'YouTube';
  YoutubeAudioHandler? _audio;
  VideoPlayerController? _video;
  StreamSubscription<Duration>? _posSub;
  bool _backgroundAudio = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Orientation? _lastOrientation;

  String? get _thumbUrl => YoutubeLinks.proxiedThumbUrl(widget.url);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_resolveAndPlay());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Restore system bars if we left while in immersive landscape.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_tearDown());
    super.dispose();
  }

  void _syncSystemUiForOrientation(Orientation orientation) {
    if (_lastOrientation == orientation) return;
    _lastOrientation = orientation;
    if (orientation == Orientation.landscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _tearDown() async {
    await _posSub?.cancel();
    _posSub = null;
    final video = _video;
    _video = null;
    await video?.dispose();
    final audio = _audio;
    _audio = null;
    try {
      await audio?.stop();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_playbackUrl == null || _audio == null) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_enterForeground());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Skip `inactive` — it fires for the notification shade / system UI
      // without leaving the player, which would briefly steal audio.
      unawaited(_enterBackground());
    }
  }

  Future<void> _enterBackground() async {
    if (_backgroundAudio) return;
    final audio = _audio;
    final video = _video;
    if (audio == null) return;
    _backgroundAudio = true;
    Duration pos = _position;
    if (video != null && video.value.isInitialized) {
      pos = video.value.position;
      try {
        await video.pause();
        await video.setVolume(0);
      } catch (_) {}
    }
    try {
      await audio.seek(pos);
      await audio.play();
    } catch (_) {}
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _enterForeground() async {
    if (!_backgroundAudio) return;
    final audio = _audio;
    final video = _video;
    if (audio == null) return;
    _backgroundAudio = false;
    final pos = audio.player.position;
    final wasPlaying = audio.player.playing;
    try {
      await audio.pause();
    } catch (_) {}
    if (video != null && video.value.isInitialized) {
      try {
        await video.seekTo(pos);
        await video.setVolume(1);
        if (wasPlaying) await video.play();
      } catch (_) {}
    } else if (wasPlaying) {
      try {
        await audio.seek(pos);
        await audio.play();
        _backgroundAudio = true; // no video — keep audio engine
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _position = pos;
        _playing = wasPlaying;
      });
    }
  }

  Future<void> _resolveAndPlay() async {
    final id = YoutubeLinks.videoId(widget.url);
    if (id == null) {
      setState(() {
        _loading = false;
        _error = 'Некорректная ссылка YouTube';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(familychatRepositoryProvider);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (mounted && DateTime.now().isBefore(deadline)) {
      try {
        final data = await repo.resolveYoutubePlayback(widget.url);
        final status = data['status']?.toString() ?? '';
        if (status == 'ready') {
          final path = data['playback_path']?.toString() ?? '';
          if (path.isEmpty) {
            setState(() {
              _loading = false;
              _error = 'Сервер не вернул поток';
            });
            return;
          }
          final origin = Uri.parse(Env.apiBaseUrl).origin;
          final play = path.startsWith('http') ? path : '$origin$path';
          _title = 'YouTube · $id';
          setState(() {
            _playbackUrl = play;
            _loading = false;
          });
          await _startPlayback(play, id);
          return;
        }
        if (status == 'error') {
          setState(() {
            _loading = false;
            _error = _friendlyError(data['error']?.toString());
          });
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      } catch (e) {
        setState(() {
          _loading = false;
          _error = 'Не удалось открыть видео';
        });
        return;
      }
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _error = 'Не удалось открыть видео. Попробуйте позже';
      });
    }
  }

  Future<void> _startPlayback(String url, String videoId) async {
    try {
      final handler = await ensureYoutubeAudioHandler();
      _audio = handler;
      final art = _thumbUrl;
      final item = MediaItem(
        id: videoId,
        title: _title,
        album: 'YouTube',
        artUri: art != null ? Uri.tryParse(art) : null,
      );
      // Foreground: video with sound. Background handler primed but paused.
      final video = VideoPlayerController.networkUrl(Uri.parse(url));
      _video = video;
      await video.initialize();
      if (!mounted) return;
      await video.setLooping(false);
      await video.setVolume(1);
      await video.play();
      _duration = video.value.duration;
      _playing = true;
      video.addListener(_onVideoTick);
      // Prime audio engine for lock-screen / notification; stay paused while
      // the in-app video player owns sound.
      await handler.prepareUrl(url: url, item: item, position: Duration.zero);
      await _posSub?.cancel();
      _posSub = handler.player.positionStream.listen((pos) {
        if (!mounted || !_backgroundAudio) return;
        setState(() {
          _position = pos;
          final d = handler.player.duration;
          if (d != null) _duration = d;
          _playing = handler.player.playing;
        });
      });
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось начать воспроизведение');
    }
  }

  void _onVideoTick() {
    final video = _video;
    if (!mounted || video == null || !video.value.isInitialized) return;
    if (_backgroundAudio) return;
    setState(() {
      _position = video.value.position;
      _duration = video.value.duration;
      _playing = video.value.isPlaying;
    });
  }

  Future<void> _togglePlay() async {
    if (_backgroundAudio) {
      final audio = _audio;
      if (audio == null) return;
      if (audio.player.playing) {
        await audio.pause();
      } else {
        await audio.play();
      }
      if (mounted) setState(() => _playing = audio.player.playing);
      return;
    }
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (video.value.isPlaying) {
      await video.pause();
    } else {
      await video.play();
    }
    if (mounted) setState(() => _playing = video.value.isPlaying);
  }

  Future<void> _seek(Duration pos) async {
    if (_backgroundAudio) {
      await _audio?.seek(pos);
    } else {
      await _video?.seekTo(pos);
    }
    if (mounted) setState(() => _position = pos);
  }

  Future<void> _openInYoutube() async {
    var raw = widget.url.trim();
    if (!raw.contains('://')) {
      final id = YoutubeLinks.videoId(raw);
      if (id == null) return;
      raw = 'https://www.youtube.com/watch?v=$id';
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _friendlyError(String? code) {
    switch (code) {
      case 'video too long':
      case 'invalid_youtube_url':
        return 'Это видео недоступно для просмотра в приложении';
      case 'relay_not_configured':
      case 'relay_unreachable':
        return 'Прокси YouTube временно недоступен';
      default:
        if (code != null && code.contains('too long')) {
          return 'Видео слишком длинное для просмотра в приложении';
        }
        return 'Не удалось открыть YouTube';
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 86400);
    final m = s ~/ 60;
    final r = s % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = m % 60;
      return '$h:${mm.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Widget _videoSurface({required bool fillScreen}) {
    final video = _video;
    final hasVideo = video != null && video.value.isInitialized;
    if (hasVideo && !_backgroundAudio) {
      final player = VideoPlayer(video);
      if (fillScreen) {
        // Maximize within the viewport while keeping aspect ratio.
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: video.value.size.width == 0 ? 16 : video.value.size.width,
              height:
                  video.value.size.height == 0 ? 9 : video.value.size.height,
              child: player,
            ),
          ),
        );
      }
      return AspectRatio(
        aspectRatio:
            video.value.aspectRatio == 0 ? 16 / 9 : video.value.aspectRatio,
        child: player,
      );
    }
    if (_thumbUrl != null) {
      return CachedNetworkImage(
        imageUrl: _thumbUrl!,
        fit: fillScreen ? BoxFit.contain : BoxFit.contain,
      );
    }
    return const Icon(
      Icons.play_circle_outline,
      color: Colors.white54,
      size: 96,
    );
  }

  Widget _controlsBar({required double progress, required int totalMs}) {
    return Material(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_backgroundAudio)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Играет в фоне · управление в шторке',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
              Row(
                children: [
                  Text(
                    _fmt(_position),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: totalMs <= 0
                          ? null
                          : (v) {
                              setState(() {
                                _position = Duration(
                                  milliseconds: (v * totalMs).round(),
                                );
                              });
                            },
                      onChangeEnd: totalMs <= 0
                          ? null
                          : (v) => unawaited(
                                _seek(
                                  Duration(
                                    milliseconds: (v * totalMs).round(),
                                  ),
                                ),
                              ),
                    ),
                  ),
                  Text(
                    _fmt(_duration),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              IconButton(
                iconSize: 48,
                color: Colors.white,
                onPressed: () => unawaited(_togglePlay()),
                icon: Icon(
                  _playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orientation = MediaQuery.orientationOf(context);
    final landscape = orientation == Orientation.landscape;
    _syncSystemUiForOrientation(orientation);

    final totalMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);
    final progress = totalMs <= 0 ? 0.0 : posMs / totalMs;

    final body = _loading
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Открываем поток…',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          )
        : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => unawaited(_resolveAndPlay()),
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                ),
              )
            : landscape
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: _videoSurface(fillScreen: true),
                      ),
                      // Compact overlays so video keeps the full viewport.
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Row(
                            children: [
                              IconButton(
                                color: Colors.white,
                                onPressed: () => Navigator.of(context).maybePop(),
                                icon: const Icon(Icons.arrow_back),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Открыть в YouTube',
                                onPressed: () => unawaited(_openInYoutube()),
                                icon: const _YoutubeAppBarIcon(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: _controlsBar(
                          progress: progress,
                          totalMs: totalMs,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: _videoSurface(fillScreen: false),
                        ),
                      ),
                      _controlsBar(progress: progress, totalMs: totalMs),
                    ],
                  );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: landscape
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Открыть в YouTube',
                  onPressed: () => unawaited(_openInYoutube()),
                  icon: const _YoutubeAppBarIcon(),
                ),
              ],
            ),
      body: body,
    );
  }
}

/// Compact YouTube mark for the player AppBar.
class _YoutubeAppBarIcon extends StatelessWidget {
  const _YoutubeAppBarIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFF0000),
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
    );
  }
}
