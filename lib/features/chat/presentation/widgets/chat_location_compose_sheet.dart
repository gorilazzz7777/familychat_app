import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/chat_location_utils.dart';
import 'chat_location_map.dart';

/// Окно выбора геолокации перед отправкой (как в Telegram).
class ChatLocationComposeSheet extends StatefulWidget {
  const ChatLocationComposeSheet({super.key});

  static Future<ChatLocationPoint?> show(BuildContext context) {
    return showModalBottomSheet<ChatLocationPoint>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ChatLocationComposeSheet(),
    );
  }

  @override
  State<ChatLocationComposeSheet> createState() => _ChatLocationComposeSheetState();
}

class _ChatLocationComposeSheetState extends State<ChatLocationComposeSheet> {
  ChatLocationPoint? _userPoint;
  ChatLocationPoint? _sendPoint;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  Future<void> _loadCurrentLocation() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw StateError('Включите геолокацию на устройстве');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Нет доступа к геолокации');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final point = ChatLocationPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (!mounted) return;
      setState(() {
        _userPoint = point;
        _sendPoint ??= point;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('StateError: ', '');
      });
    }
  }

  void _send() {
    final point = _sendPoint;
    if (point == null) return;
    Navigator.of(context).pop(point);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final mapHeight = MediaQuery.sizeOf(context).height * 0.42;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    'Отправить геолокацию',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
                TextButton(
                  onPressed: _sendPoint == null ? null : _send,
                  child: const Text('Отправить'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Синяя точка — вы сейчас. Красная метка — что отправится. '
              'Нажмите на карту, чтобы сдвинуть метку.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (_loading)
            SizedBox(
              height: mapHeight,
              child: const Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SizedBox(
              height: mapHeight,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _loadCurrentLocation,
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_sendPoint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ChatLocationMap(
                sendPoint: _sendPoint!,
                userPoint: _userPoint,
                height: mapHeight,
                onSendPointChanged: (point) => setState(() => _sendPoint = point),
              ),
            ),
        ],
      ),
    );
  }
}
