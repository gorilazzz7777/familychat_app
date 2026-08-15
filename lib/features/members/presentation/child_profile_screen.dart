import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'child_milestone_detail_screen.dart';

String _childGenderLabel(String? gender) {
  return switch (gender) {
    'boy' || 'male' => 'Мальчик',
    'girl' || 'female' => 'Девочка',
    _ => '—',
  };
}

/// Профиль ребёнка в стиле Dairy: карточка + вехи + галерея.
class ChildProfileScreen extends ConsumerStatefulWidget {
  const ChildProfileScreen({
    super.key,
    required this.childId,
    this.initialMember,
    this.initialTabIndex = 0,
  });

  final int childId;
  final Map<String, dynamic>? initialMember;
  final int initialTabIndex;

  @override
  ConsumerState<ChildProfileScreen> createState() => _ChildProfileScreenState();
}

enum _MilestoneGroup { ahead, achieved }

class _ChildProfileScreenState extends ConsumerState<ChildProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic>? _child;
  Map<String, dynamic>? _baby;
  List<Map<String, dynamic>> _milestones = [];
  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _albums = [];
  String _albumId = 'all';
  bool _isCustodian = false;
  bool _loading = true;
  bool _uploading = false;
  bool _diaryUnavailable = false;
  String? _error;
  String _milestoneQuery = '';
  _MilestoneGroup _milestoneGroup = _MilestoneGroup.ahead;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTabIndex.clamp(0, 2);
    _tabs = TabController(length: 3, vsync: this, initialIndex: initial);
    _child = widget.initialMember;
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(familychatRepositoryProvider);
    try {
      final child = await repo.childDetail(widget.childId);
      Map<String, dynamic>? baby;
      var milestones = <Map<String, dynamic>>[];
      var diaryUnavailable = false;
      try {
        baby = await repo.diaryBaby();
        milestones = await repo.diaryMilestones();
        if (baby == null) diaryUnavailable = true;
      } catch (_) {
        diaryUnavailable = true;
      }
      final gallery = await repo.childGalleryPhotos(widget.childId);
      final albums = await repo.childGalleryAlbums(widget.childId);
      final photos = (gallery['photos'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _child = child;
        _baby = baby;
        _milestones = milestones;
        _photos = photos;
        _albums = albums;
        _albumId = 'all';
        _isCustodian = child['is_custodian'] == true ||
            gallery['is_custodian'] == true;
        _diaryUnavailable = diaryUnavailable;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is DioException
            ? (e.response?.data is Map
                ? (e.response!.data['detail']?.toString() ?? 'Ошибка загрузки')
                : 'Ошибка загрузки')
            : 'Ошибка загрузки';
      });
    }
  }

  Future<void> _reloadPhotosForAlbum(String albumId) async {
    final gallery = await ref
        .read(familychatRepositoryProvider)
        .childGalleryPhotos(
          widget.childId,
          albumId: albumId == 'all' ? null : albumId,
        );
    final photos =
        (gallery['photos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (!mounted) return;
    setState(() {
      _albumId = albumId;
      _photos = photos;
    });
  }

  List<Map<String, dynamic>> get _filteredMilestones {
    final q = _milestoneQuery.trim().toLowerCase();
    return _milestones.where((m) {
      final achieved = m['achieved'] == true;
      if (_milestoneGroup == _MilestoneGroup.achieved && !achieved) {
        return false;
      }
      if (_milestoneGroup == _MilestoneGroup.ahead && achieved) return false;
      if (q.isEmpty) return true;
      final title = m['title']?.toString().toLowerCase() ?? '';
      return title.contains(q);
    }).toList();
  }

  Future<void> _pickAndUpload() async {
    if (!_isCustodian || _uploading) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      await ref.read(familychatRepositoryProvider).childGalleryUpload(
            childId: widget.childId,
            bytes: Uint8List.fromList(bytes),
            filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg',
            contentType: picked.mimeType,
          );
      await _reloadPhotosForAlbum(_albumId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Фото добавлено')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить фото')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _babyTab() {
    final child = _child ?? {};
    final baby = _baby;
    final name = (baby?['first_name'] ??
            baby?['display_name'] ??
            child['display_name'] ??
            'Малыш')
        .toString();
    final avatar = (baby?['avatar_url'] ?? child['avatar_url'] ?? '').toString();
    final birth = (baby?['birth_date_display'] ??
            baby?['birth_date'] ??
            child['birth_date'] ??
            '')
        .toString();
    final age = baby?['age_label']?.toString() ?? '';
    final gender = (baby?['gender'] ?? child['gender'] ?? '').toString();
    final achieved = baby?['milestones_achieved_count'];
    final total = baby?['milestones_total_count'];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Center(
          child: ChatAvatar(
            name: name,
            avatarUrl: avatar.isEmpty ? null : avatar,
            radius: 52,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          [
            if (birth.isNotEmpty) birth,
            if (age.isNotEmpty) age,
            _childGenderLabel(gender),
          ].where((e) => e.isNotEmpty && e != '—').join(' · '),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        if (achieved != null && total != null) ...[
          const SizedBox(height: 8),
          Text(
            'Вехи: $achieved из $total',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
        if (_diaryUnavailable) ...[
          const SizedBox(height: 20),
          Text(
            'Полный профиль Dairy недоступен. Откройте Dairy под тем же аккаунтом.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
        if (_isCustodian) ...[
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Вы опекун'),
            subtitle: const Text(
              'В календаре синхронизируются события Dairy; '
              'остальным членам семьи виден день рождения',
            ),
          ),
        ],
      ],
    );
  }

  Widget _milestonesTab() {
    if (_diaryUnavailable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Вехи доступны при членстве в Dairy.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final items = _filteredMilestones;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Поиск вехи',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _milestoneQuery = v),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Впереди'),
                selected: _milestoneGroup == _MilestoneGroup.ahead,
                onSelected: (_) =>
                    setState(() => _milestoneGroup = _MilestoneGroup.ahead),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Уже умею'),
                selected: _milestoneGroup == _MilestoneGroup.achieved,
                onSelected: (_) =>
                    setState(() => _milestoneGroup = _MilestoneGroup.achieved),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Нет вех'))
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final m = items[index];
                    final title = m['title']?.toString() ?? 'Веха';
                    final achieved = m['achieved'] == true;
                    final cover = m['cover_url']?.toString() ?? '';
                    final when = m['achieved_at_display']?.toString() ??
                        m['achieved_at']?.toString() ??
                        '';
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        final code = m['code']?.toString();
                        if (code == null || code.isEmpty) return;
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => ChildMilestoneDetailScreen(
                              code: code,
                              initial: m,
                              canEdit: _isCustodian && !_diaryUnavailable,
                            ),
                          ),
                        );
                        await _load();
                      },
                      child: Ink(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.55),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: cover.isEmpty
                                    ? Center(
                                        child: Icon(
                                          achieved
                                              ? Icons.check_circle
                                              : Icons.flag_outlined,
                                          size: 36,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                      )
                                    : ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: FamilyPublicImage(
                                          url: cover,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (when.isNotEmpty)
                                Text(
                                  when,
                                  style: Theme.of(context).textTheme.bodySmall,
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
    );
  }

  Widget _galleryTab() {
    return Column(
      children: [
        if (_albums.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              scrollDirection: Axis.horizontal,
              itemCount: _albums.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final album = _albums[index];
                final id = album['id']?.toString() ?? 'all';
                final title = album['title']?.toString() ?? 'Альбом';
                final selected = id == _albumId;
                return ChoiceChip(
                  label: Text(title),
                  selected: selected,
                  onSelected: (_) => _reloadPhotosForAlbum(id),
                );
              },
            ),
          ),
        if (_isCustodian)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _uploading ? null : _pickAndUpload,
                icon: _uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_photo_alternate_outlined),
                label: Text(_uploading ? 'Загрузка…' : 'Добавить фото'),
              ),
            ),
          ),
        Expanded(
          child: _photos.isEmpty
              ? const Center(child: Text('Галерея пока пуста'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: _photos.length,
                  itemBuilder: (context, index) {
                    final photo = _photos[index];
                    final url =
                        (photo['file_url'] ?? photo['url'] ?? '').toString();
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: url.isEmpty
                          ? ColoredBox(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            )
                          : FamilyPublicImage(url: url, fit: BoxFit.cover),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = (_baby?['display_name'] ??
            _child?['display_name'] ??
            'Ребёнок')
        .toString();
    final tabBar = FamilyTabBar.build(
      controller: _tabs,
      tabs: const [
        Tab(text: 'Профиль'),
        Tab(text: 'Вехи'),
        Tab(text: 'Галерея'),
      ],
    );

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: name,
        bottom: tabBar,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _babyTab(),
                    _milestonesTab(),
                    _galleryTab(),
                  ],
                ),
    );
  }
}
