import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/widgets/family_app_bar.dart';

import '../data/calendar_photo_sync_service.dart';

class CalendarPhotoPickConfirmScreen extends StatefulWidget {
  const CalendarPhotoPickConfirmScreen({
    super.key,
    required this.info,
    required this.photos,
  });

  final CalendarPhotoSyncInfo info;
  final List<CalendarDevicePhoto> photos;

  @override
  State<CalendarPhotoPickConfirmScreen> createState() =>
      _CalendarPhotoPickConfirmScreenState();
}

class _CalendarPhotoPickConfirmScreenState extends State<CalendarPhotoPickConfirmScreen> {
  static final _dateFmt = DateFormat('d MMM yyyy', 'ru');
  late final Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    _selectedIds = {};
    for (final photo in widget.photos) {
      if (_matchesEventDates(photo)) {
        _selectedIds.add(photo.deviceAssetId);
      }
    }
  }

  bool _matchesEventDates(CalendarDevicePhoto photo) {
    final taken = photo.takenAt;
    if (taken == null) return false;
    return widget.info.containsDate(taken);
  }

  @override
  Widget build(BuildContext context) {
    final period =
        '${_dateFmt.format(widget.info.startDate)} – ${_dateFmt.format(widget.info.syncUntil)}';
    final matching = widget.photos.where(_matchesEventDates).length;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Загрузка фото'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Период события: $period\n'
              'Подходят по дате: $matching из ${widget.photos.length}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.photos.length,
              itemBuilder: (context, i) {
                final photo = widget.photos[i];
                final matches = _matchesEventDates(photo);
                final dateLabel = photo.takenAt != null
                    ? _dateFmt.format(photo.takenAt!)
                    : 'Дата неизвестна';
                return CheckboxListTile(
                  value: _selectedIds.contains(photo.deviceAssetId),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedIds.add(photo.deviceAssetId);
                      } else {
                        _selectedIds.remove(photo.deviceAssetId);
                      }
                    });
                  },
                  title: Text(photo.filename),
                  subtitle: Text(
                    matches ? dateLabel : '$dateLabel · вне периода',
                  ),
                  secondary: Icon(
                    matches ? Icons.check_circle_outline : Icons.help_outline,
                    color: matches
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () {
                        final selected = widget.photos
                            .where((p) => _selectedIds.contains(p.deviceAssetId))
                            .toList();
                        Navigator.pop(context, selected);
                      },
                child: Text('Загрузить (${_selectedIds.length})'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
