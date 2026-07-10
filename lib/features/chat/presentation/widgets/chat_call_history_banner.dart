import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ChatCallHistoryBanner extends StatelessWidget {
  const ChatCallHistoryBanner({
    super.key,
    required this.metadata,
    required this.currentUserId,
    this.createdAt,
    this.onRedial,
  });

  final Map<String, dynamic> metadata;
  final int currentUserId;
  final DateTime? createdAt;
  final VoidCallback? onRedial;

  int? get _callerUserId => int.tryParse('${metadata['caller_user_id']}');
  int? get _calleeUserId => int.tryParse('${metadata['callee_user_id']}');
  String get _result => metadata['result']?.toString() ?? '';
  int? get _durationSeconds {
    final raw = metadata['duration_seconds'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  int? get _actorUserId => int.tryParse('${metadata['actor_user_id']}');

  bool get _isOutgoing => _callerUserId == currentUserId;
  bool get _isIncoming => _calleeUserId == currentUserId;

  bool get _canRedial {
    if (onRedial == null) return false;
    if (_result == 'missed' && _isIncoming) return true;
    if (_result == 'declined' && _isOutgoing) return true;
    return false;
  }

  String _title() {
    if (_result == 'missed' &&
        _isOutgoing &&
        _actorUserId == currentUserId) {
      return 'Исходящий отменён';
    }
    switch (_result) {
      case 'completed':
        return _isOutgoing ? 'Исходящий звонок' : 'Входящий звонок';
      case 'missed':
        return _isIncoming ? 'Пропущенный входящий' : 'Пропущенный исходящий';
      case 'declined':
        return _isOutgoing ? 'Вызов отклонён' : 'Входящий отклонён';
      case 'cancelled':
        return _isOutgoing ? 'Исходящий отменён' : 'Входящий отменён';
      default:
        return 'Звонок';
    }
  }

  String? _subtitle() {
    if (_result != 'completed') return null;
    final seconds = _durationSeconds;
    if (seconds == null) return null;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '$minutes:${secs.toString().padLeft(2, '0')}';
    }
    return '0:${secs.toString().padLeft(2, '0')}';
  }

  IconData _icon() {
    switch (_result) {
      case 'completed':
        return _isOutgoing ? Icons.call_made : Icons.call_received;
      case 'missed':
        return Icons.phone_missed;
      case 'declined':
      case 'cancelled':
        return Icons.phone_disabled_outlined;
      default:
        return Icons.call_outlined;
    }
  }

  Color _accentColor(ColorScheme cs) {
    if (_result == 'missed') return cs.error;
    if (_result == 'declined' || _result == 'cancelled') {
      return cs.onSurfaceVariant;
    }
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeFmt = DateFormat.Hm();
    final accent = _accentColor(cs);
    final subtitle = _subtitle();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.92,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon(), color: accent, size: 20),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (createdAt != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            timeFmt.format(createdAt!.toLocal()),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_canRedial) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Перезвонить',
                      visualDensity: VisualDensity.compact,
                      onPressed: onRedial,
                      icon: Icon(Icons.phone_callback, color: cs.primary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
