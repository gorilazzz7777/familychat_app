import 'dart:async';
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

/// Профиль ребёнка в вёрстке Dairy: Профиль (карточка + вехи) и Галерея (альбомы).
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

enum _GallerySection { albums, places, years }

class _ChildProfileScreenState extends ConsumerState<ChildProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _milestoneSearchCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _birthCtrl = TextEditingController();

  Map<String, dynamic>? _child;
  Map<String, dynamic>? _baby;
  List<Map<String, dynamic>> _milestones = [];
  List<Map<String, dynamic>> _albums = [];
  bool _isCustodian = false;
  bool _loading = true;
  bool _savingBaby = false;
  bool _diaryUnavailable = false;
  String? _error;
  String _milestoneQuery = '';
  _MilestoneGroup _milestoneGroup = _MilestoneGroup.ahead;
  _GallerySection _gallerySection = _GallerySection.albums;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTabIndex.clamp(0, 1);
    _tabs = TabController(length: 2, vsync: this, initialIndex: initial);
    _child = widget.initialMember;
    _syncHeaderFields();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _milestoneSearchCtrl.dispose();
    _nameCtrl.dispose();
    _birthCtrl.dispose();
    super.dispose();
  }

  void _syncHeaderFields() {
    final baby = _baby;
    final child = _child ?? {};
    final name = (baby?['first_name'] ??
            baby?['display_name'] ??
            child['display_name'] ??
            '')
        .toString();
    final birth = (baby?['birth_date_display'] ??
            _formatBirth(baby?['birth_date'] ?? child['birth_date']) ??
            '')
        .toString();
    if (_nameCtrl.text != name) _nameCtrl.text = name;
    if (_birthCtrl.text != birth) _birthCtrl.text = birth;
  }

  String? _formatBirth(Object? raw) {
    final s = raw?.toString() ?? '';
    if (s.isEmpty) return null;
    final dt = DateTime.tryParse(s);
    if (dt == null) {
      // already dd.MM.yyyy?
      if (s.contains('.')) return s;
      return s;
    }
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d.$m.${dt.year}';
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
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
      final albums = await repo.childGalleryAlbums(widget.childId);
      if (!mounted) return;
      setState(() {
        _child = child;
        _baby = baby;
        _milestones = milestones;
        _albums = albums;
        _isCustodian = child['is_custodian'] == true;
        _diaryUnavailable = diaryUnavailable;
        _loading = false;
      });
      _syncHeaderFields();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) {
          _error = e is DioException
              ? (e.response?.data is Map
                  ? (e.response!.data['detail']?.toString() ??
                      'Ошибка загрузки')
                  : 'Ошибка загрузки')
              : 'Ошибка загрузки';
        }
      });
    }
  }

  String get _displayName {
    final typed = _nameCtrl.text.trim();
    if (typed.isNotEmpty) return typed;
    return (_baby?['display_name'] ?? _child?['display_name'] ?? 'Малыш')
        .toString();
  }

  String get _avatarUrl =>
      (_baby?['avatar_url'] ?? _child?['avatar_url'] ?? '').toString();

  int get _aheadCount =>
      _milestones.where((m) => m['achieved'] != true).length;

  int get _achievedCount =>
      _milestones.where((m) => m['achieved'] == true).length;

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

  List<Map<String, dynamic>> get _customAlbums => _albums
      .where((a) => a['id']?.toString() != 'all' && a['kind'] == 'custom')
      .toList();

  Map<String, dynamic>? get _allPhotosAlbum {
    for (final a in _albums) {
      if (a['id']?.toString() == 'all') return a;
    }
    return null;
  }

  Future<void> _saveGender(String gender) async {
    if (!_isCustodian || _diaryUnavailable || _savingBaby) return;
    setState(() => _savingBaby = true);
    try {
      final baby = await ref
          .read(familychatRepositoryProvider)
          .patchDiaryBaby({'gender': gender});
      if (!mounted) return;
      setState(() {
        _baby = baby;
        _savingBaby = false;
      });
    } catch (_) {
      if (mounted) setState(() => _savingBaby = false);
    }
  }

  Future<void> _openMilestone(Map<String, dynamic> m) async {
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
    if (mounted) await _load(silent: true);
  }

  Future<void> _openAlbum(Map<String, dynamic> album) async {
    final id = album['id']?.toString() ?? 'all';
    final title = album['title']?.toString() ?? 'Альбом';
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _ChildAlbumPhotosScreen(
          childId: widget.childId,
          albumId: id,
          title: title,
          isCustodian: _isCustodian,
        ),
      ),
    );
    if (mounted) await _load(silent: true);
  }

  InputDecoration _fieldDecoration({required String hint, String? label}) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.35)),
      ),
    );
  }

  Widget _diaryBanner(ThemeData theme) {
    final done = _baby?['milestones_achieved_count'];
    final total = _baby?['milestones_total_count'];
    final achieved = done is int ? done : _achievedCount;
    final tot = total is int ? total : _milestones.length;
    final subtitle = tot > 0
        ? '$achieved из $tot уже в дневнике'
        : 'Откройте мой дневник';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() => _milestoneGroup = _MilestoneGroup.achieved);
        },
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF8B6914),
                Color(0xFF6B5344),
                Color(0xFF5C4A3A),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0x44FFFFFF)),
                  ),
                  child: const Icon(
                    Icons.menu_book_rounded,
                    color: Color(0xFFF5E6D3),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Мой дневник',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFFF8F0E3),
                          fontFamily: 'serif',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFE8D9C4),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.menu_book_outlined,
                  color: Color(0xCCF5E6D3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileTab() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final age = _baby?['age_label']?.toString() ?? '';
    final done = _baby?['milestones_achieved_count'];
    final total = _baby?['milestones_total_count'];
    final filtered = _filteredMilestones;
    final showAchieved = _milestoneGroup == _MilestoneGroup.achieved;
    final gender = (_baby?['gender'] ?? _child?['gender'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _diaryBanner(theme),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChatAvatar(
                name: _displayName,
                avatarUrl: _avatarUrl.isEmpty ? null : _avatarUrl,
                radius: 36,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayName,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          _birthCtrl.text.isEmpty ? '—' : _birthCtrl.text,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (age.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              '· $age',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey('gender-$gender'),
                      initialValue: (gender == 'boy' || gender == 'girl')
                          ? gender
                          : null,
                      decoration: _fieldDecoration(
                        hint: 'Пол',
                        label: 'Пол',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'boy',
                          child: Text('Мальчик'),
                        ),
                        DropdownMenuItem(
                          value: 'girl',
                          child: Text('Девочка'),
                        ),
                      ],
                      onChanged: (!_isCustodian ||
                              _diaryUnavailable ||
                              _savingBaby)
                          ? null
                          : (v) {
                              if (v != null) unawaited(_saveGender(v));
                            },
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_diaryUnavailable) ...[
            const SizedBox(height: 16),
            Text(
              'Вехи Dairy недоступны — откройте Dairy под тем же аккаунтом.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'События',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (done is int && total is int) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$done из $total',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ] else if (_milestones.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$_achievedCount из ${_milestones.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _milestoneSearchCtrl,
            decoration: InputDecoration(
              hintText: 'Поиск по названию',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 36,
              ),
              suffixIcon: _milestoneQuery.isEmpty
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _milestoneSearchCtrl.clear();
                        _milestoneQuery = '';
                      }),
                      icon: const Icon(Icons.close, size: 18),
                    ),
              filled: true,
              fillColor:
                  scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: scheme.primary.withValues(alpha: 0.35)),
              ),
            ),
            onChanged: (v) => setState(() => _milestoneQuery = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MilestoneFilterChip(
                  label: 'Впереди',
                  count: _aheadCount,
                  selected: !showAchieved,
                  onTap: () => setState(
                    () => _milestoneGroup = _MilestoneGroup.ahead,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MilestoneFilterChip(
                  label: 'Свершилось',
                  count: _achievedCount,
                  selected: showAchieved,
                  onTap: () => setState(
                    () => _milestoneGroup = _MilestoneGroup.achieved,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_diaryUnavailable)
            const SizedBox.shrink()
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                _milestoneQuery.trim().isEmpty
                    ? (showAchieved
                        ? 'Пока нет свершившихся вех'
                        : 'Все вехи уже отмечены')
                    : 'Ничего не найдено',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (showAchieved)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.88,
              ),
              itemBuilder: (context, index) {
                final m = filtered[index];
                return _AchievedMilestoneCard(
                  milestone: m,
                  onTap: () => _openMilestone(m),
                );
              },
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.05,
              ),
              itemBuilder: (context, index) {
                final m = filtered[index];
                return _AheadMilestoneCard(
                  milestone: m,
                  onTap: () => _openMilestone(m),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _sectionChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.85)
            : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected
                ? Colors.transparent
                : scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _galleryTab() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allAlbum = _allPhotosAlbum;
    final custom = _customAlbums;

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          if (allAlbum != null) _AllPhotosCard(
            album: allAlbum,
            onTap: () => _openAlbum(allAlbum),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _sectionChip(
                label: 'Альбомы (${custom.length})',
                icon: Icons.menu_book_outlined,
                selected: _gallerySection == _GallerySection.albums,
                onTap: () =>
                    setState(() => _gallerySection = _GallerySection.albums),
              ),
              const SizedBox(width: 8),
              _sectionChip(
                label: 'Места (0)',
                icon: Icons.place_outlined,
                selected: _gallerySection == _GallerySection.places,
                onTap: () =>
                    setState(() => _gallerySection = _GallerySection.places),
              ),
              const SizedBox(width: 8),
              _sectionChip(
                label: 'Годы (0)',
                icon: Icons.calendar_today_outlined,
                selected: _gallerySection == _GallerySection.years,
                onTap: () =>
                    setState(() => _gallerySection = _GallerySection.years),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_gallerySection != _GallerySection.albums)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                _gallerySection == _GallerySection.places
                    ? 'Места появятся после разметки фото'
                    : 'Годы появятся после разметки фото',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (custom.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                'Пока нет альбомов',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: custom.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemBuilder: (context, index) {
                final album = custom[index];
                return _AlbumCard(
                  album: album,
                  onTap: () => _openAlbum(album),
                );
              },
            ),
          if (_isCustodian) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pickAndUpload,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Добавить фото'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickAndUpload() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (picked == null) return;
    try {
      final bytes = await picked.readAsBytes();
      await ref.read(familychatRepositoryProvider).childGalleryUpload(
            childId: widget.childId,
            bytes: Uint8List.fromList(bytes),
            filename: picked.name.isNotEmpty ? picked.name : 'photo.jpg',
            contentType: picked.mimeType,
          );
      await _load(silent: true);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = FamilyTabBar.build(
      controller: _tabs,
      tabs: [
        Tab(text: 'Профиль'),
        const Tab(text: 'Галерея'),
      ],
    );

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: _displayName,
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
                    _profileTab(),
                    _galleryTab(),
                  ],
                ),
    );
  }
}

class _MilestoneFilterChip extends StatelessWidget {
  const _MilestoneFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.9)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '$label $count',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ),
    );
  }
}

IconData _milestoneIconFor(Map<String, dynamic> milestone) {
  final code = milestone['code']?.toString() ?? '';
  switch (code) {
    case 'from_hospital':
    case 'home_from_hospital':
      return Icons.home_outlined;
    case 'first_smile':
      return Icons.sentiment_satisfied_alt_outlined;
    case 'first_laugh':
      return Icons.emoji_emotions_outlined;
    case 'first_sound':
      return Icons.record_voice_over_outlined;
    case 'holds_head':
      return Icons.accessibility_new_outlined;
    case 'first_tooth':
      return Icons.medical_services_outlined;
    case 'rolls_over':
      return Icons.autorenew_rounded;
    case 'sits':
      return Icons.event_seat_outlined;
    case 'crawls':
      return Icons.pets_outlined;
    case 'first_word':
      return Icons.chat_bubble_outline;
    case 'stands':
      return Icons.boy_outlined;
    case 'first_steps':
      return Icons.directions_walk_outlined;
    case 'first_birthday':
      return Icons.celebration_outlined;
  }
  final title = (milestone['title']?.toString() ?? '').toLowerCase();
  if (title.contains('улыб')) return Icons.sentiment_satisfied_alt_outlined;
  if (title.contains('смех')) return Icons.emoji_emotions_outlined;
  if (title.contains('звук') || title.contains('голос')) {
    return Icons.record_voice_over_outlined;
  }
  if (title.contains('роддом') || title.contains('выезд') || title.contains('дом')) {
    return Icons.home_outlined;
  }
  return Icons.flag_outlined;
}

class _AheadMilestoneCard extends StatelessWidget {
  const _AheadMilestoneCard({
    required this.milestone,
    required this.onTap,
  });

  final Map<String, dynamic> milestone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = milestone['title']?.toString() ?? '';
    final icon = _milestoneIconFor(milestone);
    final isTemporal = milestone['is_temporal'] == true ||
        milestone['kind']?.toString() == 'age';
    final bg = theme.colorScheme.primaryContainer.withValues(alpha: 0.4);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 12),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: Icon(
                        icon,
                        size: 40,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    if (isTemporal)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Icon(
                          Icons.schedule,
                          size: 14,
                          color: theme.colorScheme.tertiary,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AchievedMilestoneCard extends StatelessWidget {
  const _AchievedMilestoneCard({
    required this.milestone,
    required this.onTap,
  });

  final Map<String, dynamic> milestone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = milestone['title']?.toString() ?? '';
    final date = milestone['achieved_at_display']?.toString() ?? '';
    final cover = milestone['cover_url']?.toString() ?? '';

    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: cover.isNotEmpty
                  ? FamilyPublicImage(url: cover, fit: BoxFit.cover)
                  : Center(
                      child: Icon(
                        Icons.check_circle,
                        color: theme.colorScheme.primary,
                        size: 36,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (date.isNotEmpty)
                    Text(
                      date,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllPhotosCard extends StatelessWidget {
  const _AllPhotosCard({required this.album, required this.onTap});

  final Map<String, dynamic> album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = album['count'] ?? 0;
    final cover = album['cover'];
    final coverUrl = cover is Map
        ? (cover['file_url'] ?? cover['url'] ?? '').toString()
        : '';

    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 112,
          child: Row(
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: coverUrl.isNotEmpty
                    ? FamilyPublicImage(url: coverUrl, fit: BoxFit.cover)
                    : ColoredBox(
                        color: theme.colorScheme.primaryContainer,
                        child: Icon(
                          Icons.photo_library_outlined,
                          size: 40,
                          color: theme.colorScheme.primary,
                        ),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Все фото',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$count фото',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final Map<String, dynamic> album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = album['title']?.toString() ?? '';
    final count = album['count'] ?? 0;
    final cover = album['cover'];
    final coverUrl = cover is Map
        ? (cover['file_url'] ?? cover['url'] ?? '').toString()
        : '';
    final isVideo = cover is Map && cover['kind']?.toString() == 'video';

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  coverUrl.isNotEmpty
                      ? FamilyPublicImage(url: coverUrl, fit: BoxFit.cover)
                      : ColoredBox(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                          child: Icon(
                            Icons.photo_album_outlined,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                  if (isVideo)
                    const Center(
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.black45,
                        child: Icon(Icons.play_arrow, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '$count фото',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChildAlbumPhotosScreen extends ConsumerStatefulWidget {
  const _ChildAlbumPhotosScreen({
    required this.childId,
    required this.albumId,
    required this.title,
    required this.isCustodian,
  });

  final int childId;
  final String albumId;
  final String title;
  final bool isCustodian;

  @override
  ConsumerState<_ChildAlbumPhotosScreen> createState() =>
      _ChildAlbumPhotosScreenState();
}

class _ChildAlbumPhotosScreenState
    extends ConsumerState<_ChildAlbumPhotosScreen> {
  List<Map<String, dynamic>> _photos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final gallery =
          await ref.read(familychatRepositoryProvider).childGalleryPhotos(
                widget.childId,
                albumId: widget.albumId == 'all' ? null : widget.albumId,
                limit: 100,
              );
      if (!mounted) return;
      setState(() {
        _photos = (gallery['photos'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _photos.isEmpty
              ? const Center(child: Text('Пока нет фото'))
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
    );
  }
}
