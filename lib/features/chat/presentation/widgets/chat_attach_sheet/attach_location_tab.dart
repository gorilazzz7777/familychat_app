import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../data/chat_location_utils.dart';
import '../chat_location_map.dart';

class AttachLocationTab extends StatefulWidget {
  const AttachLocationTab({
    super.key,
    required this.onSend,
    required this.scrollController,
  });

  final void Function(ChatLocationPoint point) onSend;
  final ScrollController scrollController;

  @override
  State<AttachLocationTab> createState() => _AttachLocationTabState();
}

class _AttachLocationTabState extends State<AttachLocationTab> {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mapHeight = MediaQuery.sizeOf(context).height * 0.28;

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Text(
          'Синяя точка — вы сейчас. Красная метка — что отправится. '
          'Нажмите на карту, чтобы сдвинуть метку.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        if (_loading)
          SizedBox(
            height: mapHeight,
            child: const Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          SizedBox(
            height: mapHeight,
            child: Center(
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
          )
        else if (_sendPoint != null)
          ChatLocationMap(
            sendPoint: _sendPoint!,
            userPoint: _userPoint,
            height: mapHeight,
            onSendPointChanged: (point) => setState(() => _sendPoint = point),
          ),
        const SizedBox(height: 16),
        ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primary,
            child: Icon(Icons.my_location, color: theme.colorScheme.onPrimary),
          ),
          title: const Text('Отправить свою геопозицию'),
          subtitle: _userPoint == null
              ? null
              : const Text('Текущее местоположение'),
          enabled: _sendPoint != null,
          onTap: _sendPoint == null ? null : () => widget.onSend(_sendPoint!),
        ),
      ],
    );
  }
}
