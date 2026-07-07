import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../members/presentation/member_profile_screen.dart';
import 'chat_avatar.dart';

class _PhotoPerson {
  const _PhotoPerson({
    required this.userId,
    required this.name,
    required this.avatarUrl,
  });

  final int userId;
  final String name;
  final String avatarUrl;
}

/// Блок «Кто на фото» внизу полноэкранного просмотра.
class PhotoPeopleOnPhotoBar extends ConsumerStatefulWidget {
  const PhotoPeopleOnPhotoBar({
    super.key,
    required this.attachmentId,
    this.profileUserId,
    this.threadId,
  });

  final int attachmentId;
  final int? profileUserId;
  final int? threadId;

  @override
  ConsumerState<PhotoPeopleOnPhotoBar> createState() => _PhotoPeopleOnPhotoBarState();
}

class _PhotoPeopleOnPhotoBarState extends ConsumerState<PhotoPeopleOnPhotoBar> {
  bool _loading = true;
  List<_PhotoPerson> _people = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoPeopleOnPhotoBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        oldWidget.profileUserId != widget.profileUserId ||
        oldWidget.threadId != widget.threadId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _people = const [];
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      late final Map<String, dynamic> data;
      if (widget.profileUserId != null) {
        data = await repo.galleryPhotoFaces(widget.profileUserId!, widget.attachmentId);
      } else if (widget.threadId != null) {
        data = await repo.chatAttachmentFaces(widget.threadId!, widget.attachmentId);
      } else {
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (!mounted) return;
      final faces = (data['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final byUserId = <int, _PhotoPerson>{};
      for (final face in faces) {
        final rawId = face['assigned_user_id'];
        final userId = rawId is int ? rawId : int.tryParse('$rawId');
        if (userId == null) continue;
        final name = (face['assigned_display_name']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        byUserId[userId] = _PhotoPerson(
          userId: userId,
          name: name,
          avatarUrl: face['assigned_avatar_url']?.toString() ?? '',
        );
      }
      final people = byUserId.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _people = people;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _people = const [];
        _loading = false;
      });
    }
  }

  void _openProfile(int userId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 72,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        ),
      );
    }
    if (_people.isEmpty) return const SizedBox.shrink();

    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Кто на фото',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _people.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final person = _people[i];
                    return Material(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(24),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _openProfile(person.userId),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ChatAvatar(
                                name: person.name,
                                avatarUrl: person.avatarUrl.isEmpty ? null : person.avatarUrl,
                                radius: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                person.name,
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
