import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:real_page_flip/real_page_flip.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/birthday_format.dart';
import '../../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../child_milestone_detail_screen.dart';
import 'data/scrapbook_layout.dart';
import 'utils/baby_age_format.dart';
import 'utils/milestone_gallery_viewer.dart';
import 'utils/scrapbook_flip_effect_handler.dart';
import 'utils/scrapbook_media_layout_store.dart';
import 'utils/scrapbook_media_prefetch.dart';
import 'utils/scrapbook_milestone_media.dart';
import 'widgets/scrapbook_app_promo_bar.dart';
import 'widgets/scrapbook_kraft_background.dart';
import 'widgets/scrapbook_layout_editor.dart';
import 'widgets/scrapbook_milestone_media_viewer.dart';
import 'widgets/scrapbook_milestone_slot.dart'
    show ScrapbookLayoutEditRequest, resolveMediaAspectRatio;
import 'widgets/scrapbook_page_content.dart';

/// Ширина, с которой альбом открывается разворотом (2 страницы).
const double kScrapbookDoubleSpreadBreakpoint = 720;

class MilestoneScrapbookScreen extends ConsumerStatefulWidget {
  const MilestoneScrapbookScreen({
    super.key,
    required this.babyName,
    required this.milestones,
    this.birthDate,
    this.babyAvatarUrl,
    this.readOnly = false,
    this.childId,
  }) : publicToken = null;

  /// Публичный веб/диплинк-просмотр по токену шаринга.
  const MilestoneScrapbookScreen.public({
    super.key,
    required this.publicToken,
  })  : babyName = '',
        milestones = const [],
        birthDate = null,
        babyAvatarUrl = null,
        readOnly = true,
        childId = null;

  final String babyName;
  final List<Map<String, dynamic>> milestones;
  final DateTime? birthDate;
  final String? babyAvatarUrl;
  final bool readOnly;
  final int? childId;
  final String? publicToken;

  @override
  ConsumerState<MilestoneScrapbookScreen> createState() =>
      _MilestoneScrapbookScreenState();
}

class _MilestoneScrapbookScreenState
    extends ConsumerState<MilestoneScrapbookScreen> {
  late String _babyName;
  late List<Map<String, dynamic>> _milestones;
  late List<ScrapbookPageModel> _pages;
  final ValueNotifier<int> _pageIndex = ValueNotifier(0);
  final PageFlipController _flipController = PageFlipController();
  late final ScrapbookFlipEffectHandler _flipEffects;
  int _contentEpoch = 0;
  bool _initialReloadDone = false;
  String? _loadError;
  DateTime? _birthDate;
  String? _babyAvatarUrl;
  ScrapbookLayoutEditRequest? _layoutEdit;
  final GlobalKey<ScrapbookLayoutEditorState> _layoutEditorKey =
      GlobalKey<ScrapbookLayoutEditorState>();
  int _layoutRevision = 0;
  ScrapbookLayoutTool _layoutTool = ScrapbookLayoutTool.transform;
  bool _sharing = false;

  bool get _isPublic =>
      widget.publicToken != null && widget.publicToken!.isNotEmpty;

  bool get _readOnly => widget.readOnly || _isPublic;

  @override
  void initState() {
    super.initState();
    _flipEffects = ScrapbookFlipEffectHandler(
      hapticTexturePreset: PaperTexturePreset.kraft,
    );
    _babyName = widget.babyName;
    _birthDate = widget.birthDate;
    _babyAvatarUrl = widget.babyAvatarUrl?.trim();
    if (_babyAvatarUrl != null && _babyAvatarUrl!.isEmpty) {
      _babyAvatarUrl = null;
    }
    _milestones = List<Map<String, dynamic>>.from(widget.milestones);
    _rebuildPages();
    if (kIsWeb) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialLoad();
    });
  }

  @override
  void dispose() {
    if (kIsWeb) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _pageIndex.dispose();
    _flipEffects.dispose();
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!kIsWeb || !mounted) return false;
    if (_layoutEdit != null) return false;
    if (event is! KeyDownEvent) return false;
    if (_pages.isEmpty || !_initialReloadDone || _loadError != null) {
      return false;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      _flipController.nextPage();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      _flipController.previousPage();
      return true;
    }
    return false;
  }

  void _rebuildPages() {
    final birth = _birthDate;
    _pages = buildScrapbookPages(
      milestones: _milestones,
      babyName: _babyName.isEmpty ? 'Малыш' : _babyName,
      birthDate: birth,
      calendarLabelBuilder: scrapbookCalendarMonthLabel,
      ageLabelBuilder: birth == null
          ? null
          : (date) => babyAgeAtDate(birthDate: birth, onDate: date),
      // Публичная веб-ссылка: только выполненные вехи, без «нам предстоит».
      includeAhead: !_isPublic,
    );
  }

  Future<void> _hydrateLayouts(List<Map<String, dynamic>> items) async {
    for (final m in items) {
      final code = m['code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final raw = m['media_layouts'];
      if (raw is Map && raw.isNotEmpty) {
        await ScrapbookMediaLayoutStore.hydrateFromServer(
          code,
          Map<String, dynamic>.from(raw),
          media: scrapbookMilestoneMedia(m),
        );
      } else if (_isPublic) {
        // Не тянем локальный 2×2-кэш чужого браузера — пусть соберётся
        // дефолтный scrapbook-коллаж, как в приложении.
        await ScrapbookMediaLayoutStore.clear(code);
      }
    }
  }

  Future<void> _initialLoad() async {
    if (_isPublic) {
      await _loadPublic();
      return;
    }
    await _reloadMilestones(restorePage: false, loadBirthDate: true);
  }

  Future<void> _loadPublic() async {
    final token = widget.publicToken!;
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final data = await repo.publicScrapbook(token);
      if (!mounted) return;
      final baby = (data['baby'] as Map<String, dynamic>?) ?? {};
      final items = (data['milestones'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      await _hydrateLayouts(items);
      final allMedia = <Map<String, dynamic>>[];
      for (final m in items) {
        allMedia.addAll(scrapbookMilestoneMedia(m));
      }
      await ScrapbookMediaPrefetch.prefetch(
        allMedia,
        context: mounted ? context : null,
      ).timeout(const Duration(seconds: 8), onTimeout: () {});
      if (!mounted) return;
      setState(() {
        _milestones = items;
        _babyName = baby['display_name']?.toString() ??
            baby['first_name']?.toString() ??
            'Малыш';
        _birthDate = scrapbookBirthDateFromBaby(baby);
        final rawAvatar = baby['avatar_url']?.toString().trim() ?? '';
        _babyAvatarUrl = rawAvatar.isEmpty ? null : rawAvatar;
        _rebuildPages();
        _contentEpoch += 1;
        _initialReloadDone = true;
        _loadError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError = 'Не удалось открыть альбом';
          _initialReloadDone = true;
        });
      }
    }
  }

  Future<void> _reloadMilestones({
    bool restorePage = true,
    bool loadBirthDate = false,
  }) async {
    final savedPage = _pageIndex.value;
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final futures = <Future<dynamic>>[repo.diaryMilestones()];
      if (loadBirthDate || _birthDate == null) {
        futures.add(repo.diaryBaby());
      }

      final results = await Future.wait(futures);
      if (!mounted) return;

      final items = results[0] as List<Map<String, dynamic>>;
      DateTime? birthDate = _birthDate;
      var avatarUrl = _babyAvatarUrl;
      if (results.length > 1) {
        final baby = results[1] as Map<String, dynamic>?;
        if (baby != null) {
          birthDate = scrapbookBirthDateFromBaby(baby) ?? birthDate;
          final rawAvatar = baby['avatar_url']?.toString().trim() ?? '';
          avatarUrl = rawAvatar.isEmpty ? null : rawAvatar;
          final name = baby['display_name']?.toString() ??
              baby['first_name']?.toString();
          if (name != null && name.isNotEmpty) _babyName = name;
        }
      }

      final codes = <String>{};
      final allMedia = <Map<String, dynamic>>[];
      for (final m in items) {
        final code = m['code']?.toString() ?? '';
        if (code.isNotEmpty) codes.add(code);
        allMedia.addAll(scrapbookMilestoneMedia(m));
      }
      await ScrapbookMediaLayoutStore.preload(
        codes,
        mediaForAspects: allMedia,
      );
      await _hydrateLayouts(items);
      // Если на сервере пусто, а локально уже есть разметка — заливаем,
      // чтобы публичный шаринг совпал с приложением.
      await _pushLocalLayoutsIfServerEmpty(items);
      await Future.wait([
        Future.wait(
          allMedia.map((item) async {
            final key = scrapbookMediaLayoutKey(item);
            if (ScrapbookMediaLayoutStore.peekAspect(key) != null) return;
            final ar = await resolveMediaAspectRatio(item);
            if (ar != null) {
              await ScrapbookMediaLayoutStore.persistAspect(key, ar);
            }
          }),
        ),
        ScrapbookMediaPrefetch.prefetch(
          allMedia,
          context: mounted ? context : null,
        ).timeout(const Duration(seconds: 8), onTimeout: () {}),
      ]);
      if (!mounted) return;

      setState(() {
        _milestones = items;
        _birthDate = birthDate;
        _babyAvatarUrl = avatarUrl;
        _rebuildPages();
        _contentEpoch += 1;
        _initialReloadDone = true;
      });

      unawaited(
        ScrapbookMediaPrefetch.prefetch(
          allMedia,
          context: mounted ? context : null,
        ),
      );

      if (!restorePage || savedPage <= 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final target = savedPage.clamp(0, _pages.length - 1);
        _pageIndex.value = target;
        final wide = MediaQuery.sizeOf(context).width >=
            kScrapbookDoubleSpreadBreakpoint;
        await _flipController.goToPage(_toFlipIndex(target, wide: wide));
      });
    } catch (_) {
      if (mounted) {
        setState(() => _initialReloadDone = true);
      }
    }
  }

  Future<void> _pushLocalLayoutsIfServerEmpty(
    List<Map<String, dynamic>> items,
  ) async {
    if (_readOnly) return;
    final repo = ref.read(familychatRepositoryProvider);
    for (final m in items) {
      final code = m['code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final raw = m['media_layouts'];
      if (raw is Map && raw.isNotEmpty) continue;
      final local = await ScrapbookMediaLayoutStore.load(code);
      if (local.isEmpty) continue;
      try {
        await repo.saveMilestoneMediaLayouts(
          code,
          ScrapbookMediaLayoutStore.layoutsToJson(local),
        );
      } catch (_) {}
    }
  }

  Future<void> _syncLayoutsToServer() async {
    final repo = ref.read(familychatRepositoryProvider);
    for (final m in _milestones) {
      final code = m['code']?.toString() ?? '';
      if (code.isEmpty) continue;
      final layouts = await ScrapbookMediaLayoutStore.load(code);
      if (layouts.isEmpty) continue;
      try {
        await repo.saveMilestoneMediaLayouts(
          code,
          ScrapbookMediaLayoutStore.layoutsToJson(layouts),
        );
      } catch (_) {}
    }
  }

  Future<void> _shareAlbum() async {
    if (_sharing || _readOnly) return;
    setState(() => _sharing = true);
    try {
      // Чтобы на вебе открылись те же координаты, что в приложении.
      await _syncLayoutsToServer();
      final res =
          await ref.read(familychatRepositoryProvider).createScrapbookShare();
      final url = (res['web_url'] ?? res['share_url'] ?? '').toString();
      if (url.isEmpty) return;
      await SharePlus.instance.share(
        ShareParams(text: 'Смотри дневник $_babyName: $url'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать ссылку: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _openMedia(
    Map<String, dynamic> milestone,
    List<Map<String, dynamic>> media, {
    int initialIndex = 0,
  }) async {
    if (media.isEmpty) return;

    final galleryPhotos = milestonePhotosForGalleryViewer(media);
    if (galleryPhotos.isNotEmpty && !_readOnly) {
      final status = await ref.read(familychatRepositoryProvider).status();
      final raw = status['user_id'];
      final currentUserId = raw is int ? raw : int.tryParse('$raw');
      if (currentUserId != null && mounted) {
        final source = media[initialIndex.clamp(0, media.length - 1)];
        final rawAtt = source['attachment_id'];
        final attId = rawAtt is int ? rawAtt : int.tryParse('$rawAtt');
        var initial = initialIndex.clamp(0, galleryPhotos.length - 1);
        if (attId != null) {
          final found = galleryPhotos.indexWhere((p) => p['id'] == attId);
          if (found >= 0) initial = found;
        }
        await GalleryPhotoViewerScreen.open(
          context,
          profileUserId: currentUserId,
          photo: galleryPhotos[initial],
          currentUserId: currentUserId,
          photos: galleryPhotos,
          initialIndex: initial,
        );
        return;
      }
    }

    if (!mounted) return;
    await ScrapbookMilestoneMediaViewer.open(
      context,
      title: milestone['title']?.toString() ?? 'Веха',
      media: media,
      initialIndex: initialIndex,
    );
  }

  Future<void> _openMilestone(Map<String, dynamic> milestone) async {
    if (_readOnly) return;
    final code = milestone['code']?.toString();
    if (code == null || code.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChildMilestoneDetailScreen(
          code: code,
          initial: milestone,
          canEdit: true,
          childId: widget.childId,
          childName: widget.babyName,
        ),
      ),
    );
    if (mounted) {
      await _reloadMilestones(loadBirthDate: _birthDate == null);
    }
  }

  Widget _buildPage(
    BuildContext context,
    int index, {
    bool asBookLeaf = false,
  }) {
    if (index < 0 || index >= _pages.length) {
      return const ColoredBox(color: ScrapbookKraftBackground.paperColor);
    }
    final page = _pages[index];
    return ScrapbookPageContent(
      page: page,
      birthDate: _birthDate,
      babyAvatarUrl: _babyAvatarUrl,
      babyName: _babyName,
      layoutRevision: _layoutRevision,
      asBookLeaf: asBookLeaf,
      onTapMedia: _openMedia,
      onTapPlaceholder: _readOnly ? null : _openMilestone,
      onRequestLayoutEdit: _readOnly
          ? null
          : (request) {
              setState(() {
                _layoutEdit = request;
                _layoutTool = ScrapbookLayoutTool.transform;
              });
            },
    );
  }

  /// Разворот: index 0 = только обложка (закрытый альбом), дальше пары страниц.
  Widget _buildSpread(BuildContext context, int flipIndex) {
    if (flipIndex == 0) {
      return _buildCoverAlone(context);
    }

    final left = 1 + (flipIndex - 1) * 2;
    final right = left + 1;
    return ColoredBox(
      color: ScrapbookKraftBackground.deskColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x88000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildPage(context, left, asBookLeaf: true),
                ),
                Container(width: 1.2, color: const Color(0xFFB8956E)),
                Expanded(
                  child: right < _pages.length
                      ? _buildPage(context, right, asBookLeaf: true)
                      : const ColoredBox(
                          color: ScrapbookKraftBackground.paperColor,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Обложка как один закрытый лист по центру (не разворот).
  Widget _buildCoverAlone(BuildContext context) {
    return ColoredBox(
      color: ScrapbookKraftBackground.deskColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = (constraints.maxHeight - 16).clamp(200.0, 4000.0);
          final maxW = (constraints.maxWidth - 12).clamp(160.0, 4000.0);
          // Один лист ≈ половина книжного разворота, портрет ~0.72.
          var width = math.min(maxW * 0.48, 460.0);
          var height = width / 0.72;
          if (height > maxH) {
            height = maxH;
            width = height * 0.72;
          }
          if (width > maxW) {
            width = maxW;
            height = width / 0.72;
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: SizedBox(
                width: width,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x88000000),
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _buildPage(context, 0, asBookLeaf: true),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Обложка отдельно + ceil((n-1)/2) разворотов контента.
  int get _spreadCount {
    final n = _pages.length;
    if (n <= 1) return n;
    return 1 + ((n - 1) + 1) ~/ 2;
  }

  int _toFlipIndex(int pageIndex, {required bool wide}) {
    if (_pages.isEmpty) return 0;
    final safe = pageIndex.clamp(0, _pages.length - 1);
    if (!wide) return safe;
    if (safe <= 0) return 0;
    return 1 + (safe - 1) ~/ 2;
  }

  int _fromFlipIndex(int flipIndex, {required bool wide}) {
    if (!wide) return flipIndex;
    if (flipIndex <= 0) return 0;
    return (1 + (flipIndex - 1) * 2)
        .clamp(0, _pages.isEmpty ? 0 : _pages.length - 1);
  }

  Future<void> _commitLayoutEdit() async {
    await _layoutEditorKey.currentState?.commit();
  }

  void _toggleLayoutTool() {
    setState(() {
      _layoutTool = _layoutTool == ScrapbookLayoutTool.transform
          ? ScrapbookLayoutTool.rotate
          : ScrapbookLayoutTool.transform;
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = _layoutEdit;
    final pageCount = _pages.length;
    final safeInitial =
        pageCount == 0 ? 0 : _pageIndex.value.clamp(0, pageCount - 1);

    return Scaffold(
      backgroundColor: ScrapbookKraftBackground.deskColor,
      appBar: AppBar(
        backgroundColor: ScrapbookKraftBackground.deskColor,
        foregroundColor: const Color(0xFFF5E6D3),
        title: Text(editing != null ? 'Разметка фото' : 'Мой дневник'),
        leading: editing != null
            ? IconButton(
                tooltip: 'Отмена',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _layoutEdit = null),
              )
            : null,
        actions: [
          if (editing != null) ...[
            IconButton(
              tooltip: _layoutTool == ScrapbookLayoutTool.transform
                  ? 'Режим поворота'
                  : 'Перемещение и масштаб',
              onPressed: _toggleLayoutTool,
              icon: Icon(
                _layoutTool == ScrapbookLayoutTool.transform
                    ? Icons.rotate_right
                    : Icons.open_with,
              ),
            ),
            TextButton(
              onPressed: _commitLayoutEdit,
              child: const Text(
                'Готово',
                style: TextStyle(
                  color: Color(0xFFE6D5BC),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ] else ...[
            if (!_readOnly)
              IconButton(
                tooltip: 'Поделиться альбомом',
                onPressed: _sharing ? null : _shareAlbum,
                icon: _sharing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFE6D5BC),
                        ),
                      )
                    : Icon(
                        defaultTargetPlatform == TargetPlatform.iOS
                            ? Icons.ios_share
                            : Icons.share_outlined,
                      ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: _pageIndex,
                  builder: (context, index, _) {
                    final wide = MediaQuery.sizeOf(context).width >=
                        kScrapbookDoubleSpreadBreakpoint;
                    final String label;
                    if (!wide || _pages.length <= 1) {
                      label = '${index + 1} / ${_pages.length}';
                    } else if (index == 0) {
                      // Обложка — одна страница.
                      label = '1 / ${_pages.length}';
                    } else {
                      final left = index + 1;
                      final right = (index + 2).clamp(1, _pages.length);
                      label = left == right
                          ? '$left / ${_pages.length}'
                          : '$left–$right / ${_pages.length}';
                    }
                    return Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: const Color(0xFFE6D5BC),
                          ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar:
          (_isPublic && editing == null) ? const ScrapbookAppPromoBar() : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: editing != null,
            child: IgnorePointer(
              ignoring: editing != null,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  child: _buildAlbumBody(safeInitial),
                ),
              ),
            ),
          ),
          if (editing != null)
            ScrapbookLayoutEditor(
              key: _layoutEditorKey,
              request: editing,
              tool: _layoutTool,
              onDone: (layouts) async {
                final pageToKeep = _pageIndex.value;
                await ScrapbookMediaLayoutStore.save(
                  editing.milestoneCode,
                  layouts,
                );
                try {
                  await ref
                      .read(familychatRepositoryProvider)
                      .saveMilestoneMediaLayouts(
                        editing.milestoneCode,
                        ScrapbookMediaLayoutStore.layoutsToJson(layouts),
                      );
                } catch (_) {}
                if (!mounted) return;
                setState(() {
                  _layoutEdit = null;
                  _layoutRevision += 1;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (!mounted) return;
                  final target = pageToKeep.clamp(0, _pages.length - 1);
                  _pageIndex.value = target;
                  final wide = MediaQuery.sizeOf(context).width >=
                      kScrapbookDoubleSpreadBreakpoint;
                  await _flipController.goToPage(
                    _toFlipIndex(target, wide: wide),
                  );
                });
              },
            ),
        ],
      ),
    );
  }

  Widget _buildAlbumBody(int safeInitial) {
    if (_loadError != null) {
      return Center(
        child: Text(
          _loadError!,
          style: const TextStyle(color: Color(0xFFE6D5BC)),
        ),
      );
    }
    if (!_initialReloadDone) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE6D5BC)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kScrapbookDoubleSpreadBreakpoint;
        final flipInitial = _toFlipIndex(safeInitial, wide: wide);
        final flipCount = wide ? _spreadCount : _pages.length;
        final flip = PageFlipWidget(
          key: ValueKey('${_contentEpoch}_${wide ? 'spread' : 'single'}'),
          controller: _flipController,
          initialIndex: flipCount == 0 ? 0 : flipInitial.clamp(0, flipCount - 1),
          itemCount: flipCount,
          isDoubleSpread: wide,
          config: PageFlipConfig(
            backgroundColor: ScrapbookKraftBackground.deskColor,
            hapticTexturePreset: PaperTexturePreset.kraft,
            enableSound: !kIsWeb,
            enableHaptics: !kIsWeb,
            effectHandler: _flipEffects,
            sensitivity: 0.5,
            cutoffForward: 0.32,
            cutoffPrevious: 0.32,
            skipTapAnimation: false,
          ),
          onPageChanged: (index) {
            _pageIndex.value = _fromFlipIndex(index, wide: wide);
          },
          itemBuilder: wide
              ? _buildSpread
              : (context, index) => _buildPage(context, index),
        );

        if (!wide) return flip;

        // Книжный формат: шире «листа» пропорции разворота ~1.4–1.6.
        final maxW = constraints.maxWidth.clamp(0.0, 1180.0).toDouble();
        final maxH = constraints.maxHeight;
        final targetW = maxW;
        final targetH = (targetW / 1.55).clamp(280.0, maxH).toDouble();

        return Center(
          child: SizedBox(
            width: targetW,
            height: targetH,
            child: flip,
          ),
        );
      },
    );
  }
}

/// Открыть альбом из профиля ребёнка.
Future<void> openMilestoneScrapbook(
  BuildContext context, {
  required String babyName,
  required List<Map<String, dynamic>> milestones,
  DateTime? birthDate,
  String? babyAvatarUrl,
  int? childId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MilestoneScrapbookScreen(
        babyName: babyName,
        milestones: milestones,
        birthDate: birthDate,
        babyAvatarUrl: babyAvatarUrl,
        childId: childId,
      ),
    ),
  );
}

DateTime? scrapbookBirthDateFromBaby(Map<String, dynamic>? baby) {
  if (baby == null) return null;
  return parseBirthDate(baby['birth_date']?.toString()) ??
      parseBirthDate(baby['birth_date_display']?.toString());
}
