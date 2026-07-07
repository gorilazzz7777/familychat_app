import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';

/// Окно «Кто на этом фото?» с рамками лиц и выбором участника семьи.
class FaceTaggingSheet extends ConsumerStatefulWidget {
  const FaceTaggingSheet({
    super.key,
    required this.threadId,
    required this.attachmentId,
    required this.imageChild,
    this.profileUserId,
    this.promptMode = false,
  });

  final int threadId;
  final int attachmentId;
  final Widget imageChild;
  final int? profileUserId;
  final bool promptMode;

  static Future<void> show(
    BuildContext context, {
    required int threadId,
    required int attachmentId,
    required Widget imageChild,
    int? profileUserId,
    bool promptMode = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: !promptMode,
      enableDrag: !promptMode,
      backgroundColor: Colors.black,
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: FaceTaggingSheet(
          threadId: threadId,
          attachmentId: attachmentId,
          imageChild: imageChild,
          profileUserId: profileUserId,
          promptMode: promptMode,
        ),
      ),
    );
  }

  @override
  ConsumerState<FaceTaggingSheet> createState() => _FaceTaggingSheetState();
}

class _FaceTaggingSheetState extends ConsumerState<FaceTaggingSheet> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _faces = [];
  List<Map<String, dynamic>> _members = [];
  int? _selectedFaceIndex;
  bool _manualMarkMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final facesFuture = widget.profileUserId != null
          ? repo.galleryPhotoFaces(widget.profileUserId!, widget.attachmentId)
          : repo.chatAttachmentFaces(widget.threadId, widget.attachmentId);
      final results = await Future.wait([
        facesFuture,
        repo.members(),
      ]);
      if (!mounted) return;
      final faceData = results[0] as Map<String, dynamic>;
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      setState(() {
        _faces = (faceData['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _members = members;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _assignFace(int faceIndex, int userId) async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final data = widget.profileUserId != null
          ? await repo.assignGalleryPhotoFace(
              widget.profileUserId!,
              widget.attachmentId,
              faceIndex,
              userId,
            )
          : await repo.assignChatAttachmentFace(
              widget.threadId,
              widget.attachmentId,
              faceIndex,
              userId,
            );
      if (!mounted) return;
      setState(() {
        _faces = (data['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _selectedFaceIndex = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    }
  }

  Future<void> _createManualFace(Map<String, double> bbox) async {
    final picked = await _pickMemberFromAll();
    if (picked == null) return;
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final data = widget.profileUserId != null
          ? await repo.createGalleryPhotoManualFace(
              widget.profileUserId!,
              widget.attachmentId,
              userId: picked,
              bbox: bbox,
            )
          : await repo.createChatAttachmentManualFace(
              widget.threadId,
              widget.attachmentId,
              userId: picked,
              bbox: bbox,
            );
      if (!mounted) return;
      setState(() {
        _faces = (data['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _manualMarkMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать рамку: $e')),
      );
    }
  }

  Future<int?> _pickMemberFromAll() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Кто на фото?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final m in _members)
                    ListTile(
                      leading: ChatAvatar(
                        name: m['display_name']?.toString() ?? '',
                        avatarUrl: m['avatar_url']?.toString(),
                        radius: 20,
                      ),
                      title: Text(m['display_name']?.toString() ?? ''),
                      onTap: () {
                        final id = m['user_id'];
                        if (id is int) {
                          Navigator.pop(ctx, id);
                        } else {
                          Navigator.pop(ctx, int.tryParse(id?.toString() ?? ''));
                        }
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return picked;
  }

  Future<void> _pickMember(int faceIndex) async {
    Map<String, dynamic>? face;
    for (final f in _faces) {
      if (f['face_index'] == faceIndex) {
        face = f;
        break;
      }
    }
    final suggestions = (face?['suggestions'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final suggestedIds = suggestions
        .map((s) => s['user_id'])
        .whereType<int>()
        .toSet();
    final otherMembers = _members.where((m) {
      final id = m['user_id'];
      final userId = id is int ? id : int.tryParse(id?.toString() ?? '');
      return userId != null && !suggestedIds.contains(userId);
    }).toList();

    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Кто на этом фото?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (suggestions.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Возможно',
                        style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                      ),
                    ),
                    for (final s in suggestions)
                      _SuggestionTile(
                        suggestion: s,
                        onTap: () {
                          final id = s['user_id'];
                          if (id is int) {
                            Navigator.pop(ctx, id);
                          } else {
                            Navigator.pop(ctx, int.tryParse(id?.toString() ?? ''));
                          }
                        },
                      ),
                    if (otherMembers.isNotEmpty) const Divider(height: 24),
                  ],
                  if (otherMembers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        suggestions.isEmpty ? 'Участники семьи' : 'Все участники',
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                    ),
                  for (final m in otherMembers)
                    ListTile(
                      leading: ChatAvatar(
                        name: m['display_name']?.toString() ?? '',
                        avatarUrl: m['avatar_url']?.toString(),
                        radius: 20,
                      ),
                      title: Text(m['display_name']?.toString() ?? ''),
                      onTap: () {
                        final id = m['user_id'];
                        if (id is int) {
                          Navigator.pop(ctx, id);
                        } else {
                          final parsed = int.tryParse(id?.toString() ?? '');
                          Navigator.pop(ctx, parsed);
                        }
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await _assignFace(faceIndex, picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.9;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                if (!widget.promptMode)
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                Expanded(
                  child: Text(
                    _manualMarkMode
                        ? 'Нарисуйте рамку лица'
                        : (widget.promptMode ? 'Кто на этом фото?' : 'Указать лица'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.promptMode)
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Пропустить'),
                  )
                else
                  IconButton(
                    tooltip: _manualMarkMode ? 'Отменить рамку' : 'Нарисовать рамку',
                    onPressed: () => setState(() => _manualMarkMode = !_manualMarkMode),
                    icon: Icon(
                      _manualMarkMode ? Icons.close : Icons.crop_free_outlined,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
          if (widget.promptMode)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Нажмите на рамку и выберите участника семьи',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : _error != null
                    ? Center(
                        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: _FaceOverlay(
                          faces: _faces,
                          selectedFaceIndex: _selectedFaceIndex,
                          onFaceTap: (idx) {
                            if (_manualMarkMode) return;
                            setState(() => _selectedFaceIndex = idx);
                            _pickMember(idx);
                          },
                          manualMarkMode: _manualMarkMode,
                          onManualFaceCreated: _createManualFace,
                          child: widget.imageChild,
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.suggestion,
    required this.onTap,
  });

  final Map<String, dynamic> suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = suggestion['display_name']?.toString() ?? '';
    final scoreRaw = suggestion['score'];
    final score = scoreRaw is num ? scoreRaw.toDouble() : double.tryParse('$scoreRaw');
    final scoreLabel = score != null ? '${(score * 100).round()}% совпадение' : null;

    return ListTile(
      leading: ChatAvatar(
        name: name,
        avatarUrl: suggestion['avatar_url']?.toString(),
        radius: 20,
      ),
      title: Text(name),
      subtitle: scoreLabel != null ? Text(scoreLabel) : null,
      trailing: Icon(Icons.auto_awesome, color: theme.colorScheme.primary, size: 20),
      onTap: onTap,
    );
  }
}

class _FaceOverlay extends StatelessWidget {
  const _FaceOverlay({
    required this.faces,
    required this.child,
    required this.onFaceTap,
    required this.onManualFaceCreated,
    this.manualMarkMode = false,
    this.selectedFaceIndex,
  });

  final List<Map<String, dynamic>> faces;
  final Widget child;
  final void Function(int faceIndex) onFaceTap;
  final Future<void> Function(Map<String, double> bbox) onManualFaceCreated;
  final bool manualMarkMode;
  final int? selectedFaceIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final boxH = constraints.maxHeight;
        Offset? startPoint;
        Offset? endPoint;
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (manualMarkMode)
                child
              else
                InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 3,
                  child: child,
                ),
              if (manualMarkMode)
                StatefulBuilder(
                  builder: (context, setLocalState) {
                    return GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanStart: (d) => setLocalState(() {
                        startPoint = d.localPosition;
                        endPoint = d.localPosition;
                      }),
                      onPanUpdate: (d) => setLocalState(() => endPoint = d.localPosition),
                      onPanEnd: (_) async {
                        final s = startPoint;
                        final e = endPoint;
                        if (s == null || e == null) return;
                        final left = (s.dx < e.dx ? s.dx : e.dx).clamp(0.0, boxW);
                        final top = (s.dy < e.dy ? s.dy : e.dy).clamp(0.0, boxH);
                        final right = (s.dx > e.dx ? s.dx : e.dx).clamp(0.0, boxW);
                        final bottom = (s.dy > e.dy ? s.dy : e.dy).clamp(0.0, boxH);
                        final w = right - left;
                        final h = bottom - top;
                        if (w < 12 || h < 12) return;
                        await onManualFaceCreated({
                          'x': left / boxW,
                          'y': top / boxH,
                          'w': w / boxW,
                          'h': h / boxH,
                        });
                        setLocalState(() {
                          startPoint = null;
                          endPoint = null;
                        });
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (startPoint != null && endPoint != null)
                            Positioned(
                              left: (startPoint!.dx < endPoint!.dx ? startPoint!.dx : endPoint!.dx)
                                  .clamp(0.0, boxW),
                              top: (startPoint!.dy < endPoint!.dy ? startPoint!.dy : endPoint!.dy)
                                  .clamp(0.0, boxH),
                              width: (startPoint!.dx - endPoint!.dx).abs(),
                              height: (startPoint!.dy - endPoint!.dy).abs(),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.amberAccent, width: 2),
                                  color: Colors.amberAccent.withValues(alpha: 0.12),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ...faces.map((face) {
                final idx = face['face_index'];
                if (idx is! int) return const SizedBox.shrink();
                final bbox = face['bbox'];
                if (bbox is! Map) return const SizedBox.shrink();
                final x = (bbox['x'] as num?)?.toDouble() ?? 0;
                final y = (bbox['y'] as num?)?.toDouble() ?? 0;
                final w = (bbox['w'] as num?)?.toDouble() ?? 0;
                final h = (bbox['h'] as num?)?.toDouble() ?? 0;
                final assigned = face['assigned_user_id'];
                final name = face['assigned_display_name']?.toString() ?? '';
                final selected = selectedFaceIndex == idx;
                final matched = assigned != null;
                return Positioned(
                  left: x * boxW,
                  top: y * boxH,
                  width: w * boxW,
                  height: h * boxH,
                  child: GestureDetector(
                    onTap: () => onFaceTap(idx),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected
                              ? Colors.amberAccent
                              : matched
                                  ? Colors.lightGreenAccent
                                  : Colors.white,
                          width: selected ? 3 : 2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.bottomCenter,
                      child: name.isNotEmpty
                          ? Container(
                              width: double.infinity,
                              color: Colors.black54,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontSize: 11),
                              ),
                            )
                          : null,
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

/// Хелпер для построения превью изображения вложения.
Widget faceTaggingAttachmentPreview({
  required int threadId,
  required Map<String, dynamic> attachment,
  Uint8List? localBytes,
}) {
  if (localBytes != null) {
    return Image.memory(localBytes, fit: BoxFit.contain);
  }
  return ChatNetworkImage(
    threadId: threadId,
    attachment: attachment,
    fit: BoxFit.contain,
  );
}
