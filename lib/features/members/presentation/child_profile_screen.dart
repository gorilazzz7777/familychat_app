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

String _childGenderLabel(String? gender) {
  return switch (gender) {
    'boy' => 'Мальчик',
    'girl' => 'Девочка',
    'male' => 'Мальчик',
    'female' => 'Девочка',
    _ => '—',
  };
}

/// Профиль ребёнка: карточка Dairy + вехи + галерея FC.
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

class _ChildProfileScreenState extends ConsumerState<ChildProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic>? _child;
  Map<String, dynamic>? _baby;
  List<Map<String, dynamic>> _milestones = [];
  List<Map<String, dynamic>> _photos = [];
  bool _isCustodian = false;
  bool _loading = true;
  bool _uploading = false;
  bool _diaryUnavailable = false;
  String? _error;

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
      final photos = (gallery['photos'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _child = child;
        _baby = baby;
        _milestones = milestones;
        _photos = photos;
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
      final repo = ref.read(familychatRepositoryProvider);
      await repo.childGalleryUpload(
        childId: widget.childId,
        bytes: Uint8List.fromList(bytes),
        filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg',
        contentType: picked.mimeType,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Фото добавлено в галерею ребёнка')),
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

  Future<void> _deletePhoto(Map<String, dynamic> photo) async {
    final id = photo['id'] as int? ?? photo['attachment_id'] as int?;
    if (id == null || !_isCustodian) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фото?'),
        content: const Text(
          'Фото будет удалено и в FamilyChat, и в Dairy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(familychatRepositoryProvider).deleteChildGalleryPhoto(
            childId: widget.childId,
            attachmentId: id,
          );
      setState(() {
        _photos = _photos
            .where((p) => (p['id'] ?? p['attachment_id']) != id)
            .toList();
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось удалить')),
        );
      }
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
    final birth = (baby?['birth_date'] ?? child['birth_date'] ?? '').toString();
    final gender = (baby?['gender'] ?? child['gender'] ?? '').toString();

    if (_diaryUnavailable) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ChatAvatar(name: name, avatarUrl: avatar.isEmpty ? null : avatar, radius: 48),
          const SizedBox(height: 16),
          Text(name, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Полный профиль Dairy недоступен. Откройте приложение Dairy '
            'под тем же аккаунтом, чтобы видеть вехи и дневник.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (birth.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Дата рождения: $birth'),
          ],
          Text('Пол: ${_childGenderLabel(gender)}'),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
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
        const SizedBox(height: 8),
        Text(
          'Ребёнок семьи',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cake_outlined),
          title: const Text('Дата рождения'),
          subtitle: Text(birth.isEmpty ? '—' : birth),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.wc_outlined),
          title: const Text('Пол'),
          subtitle: Text(_childGenderLabel(gender)),
        ),
        if (_isCustodian)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Вы опекун'),
            subtitle: const Text('Можете добавлять фото в галерею ребёнка'),
          ),
      ],
    );
  }

  Widget _milestonesTab() {
    if (_diaryUnavailable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Вехи доступны при членстве в Dairy. Откройте Dairy с этим аккаунтом.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_milestones.isEmpty) {
      return const Center(child: Text('Вех пока нет'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _milestones.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final m = _milestones[index];
        final title = m['title']?.toString() ?? m['code']?.toString() ?? 'Веха';
        final achieved = m['achieved'] == true;
        final achievedAt = m['achieved_at']?.toString() ?? '';
        return ListTile(
          leading: Icon(
            achieved ? Icons.check_circle : Icons.radio_button_unchecked,
            color: achieved
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          title: Text(title),
          subtitle: achievedAt.isNotEmpty
              ? Text(achievedAt)
              : (achieved ? const Text('Достигнуто') : const Text('Ещё впереди')),
          onTap: () {
            final code = m['code']?.toString();
            if (code == null || code.isEmpty) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _MilestoneDetailPage(code: code, title: title),
              ),
            );
          },
        );
      },
    );
  }

  Widget _galleryTab() {
    return Column(
      children: [
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
                    final url = (photo['file_url'] ?? photo['url'] ?? '')
                        .toString();
                    return GestureDetector(
                      onLongPress:
                          _isCustodian ? () => _deletePhoto(photo) : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: url.isEmpty
                            ? ColoredBox(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              )
                            : FamilyPublicImage(
                                url: url,
                                fit: BoxFit.cover,
                              ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = (_child?['display_name'] ?? 'Ребёнок').toString();
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

class _MilestoneDetailPage extends ConsumerStatefulWidget {
  const _MilestoneDetailPage({required this.code, required this.title});

  final String code;
  final String title;

  @override
  ConsumerState<_MilestoneDetailPage> createState() =>
      _MilestoneDetailPageState();
}

class _MilestoneDetailPageState extends ConsumerState<_MilestoneDetailPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .diaryMilestoneDetail(widget.code);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _data?['note']?.toString() ?? '';
    final achieved = _data?['achieved'] == true;
    final achievedAt = _data?['achieved_at']?.toString() ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    achieved ? Icons.check_circle : Icons.radio_button_unchecked,
                  ),
                  title: Text(achieved ? 'Достигнуто' : 'Ещё не отмечено'),
                  subtitle: achievedAt.isNotEmpty ? Text(achievedAt) : null,
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Заметка', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(note),
                ],
              ],
            ),
    );
  }
}
