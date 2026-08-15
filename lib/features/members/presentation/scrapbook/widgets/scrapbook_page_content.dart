import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../../profile/presentation/widgets/chat_avatar.dart';
import '../data/scrapbook_layout.dart';
import '../utils/baby_age_format.dart';
import 'scrapbook_kraft_background.dart';
import 'scrapbook_milestone_slot.dart';

class ScrapbookPageContent extends StatelessWidget {
  const ScrapbookPageContent({
    super.key,
    required this.page,
    this.birthDate,
    this.babyAvatarUrl,
    this.babyName,
    this.onTapMedia,
    this.onTapPlaceholder,
    this.onRequestLayoutEdit,
    this.layoutRevision = 0,
    this.asBookLeaf = false,
  });

  final ScrapbookPageModel page;
  final DateTime? birthDate;
  final String? babyAvatarUrl;
  final String? babyName;
  final void Function(
    Map<String, dynamic> milestone,
    List<Map<String, dynamic>> media, {
    int initialIndex,
  })? onTapMedia;
  final void Function(Map<String, dynamic> milestone)? onTapPlaceholder;
  final void Function(ScrapbookLayoutEditRequest request)? onRequestLayoutEdit;
  final int layoutRevision;
  /// Половина книжного разворота (без «стола» вокруг листа).
  final bool asBookLeaf;

  @override
  Widget build(BuildContext context) {
    final isCover = page.kind == ScrapbookPageKind.cover;
    return ScrapbookKraftBackground(
      padding: EdgeInsets.fromLTRB(
        asBookLeaf ? 8 : 10,
        isCover ? 18 : (asBookLeaf ? 8 : 10),
        asBookLeaf ? 8 : 10,
        asBookLeaf ? 8 : 10,
      ),
      showSpine: false,
      leafOnly: asBookLeaf,
      child: switch (page.kind) {
        ScrapbookPageKind.cover => _CoverBody(
            page: page,
            babyAvatarUrl: babyAvatarUrl,
            babyName: babyName ?? page.coverTitle ?? 'Малыш',
            birthDate: birthDate,
          ),
        ScrapbookPageKind.achieved => _AchievedBody(
            page: page,
            birthDate: birthDate,
            onTapMedia: onTapMedia,
            onTapPlaceholder: onTapPlaceholder,
            onRequestLayoutEdit: onRequestLayoutEdit,
            layoutRevision: layoutRevision,
          ),
        ScrapbookPageKind.ahead => _AheadBody(
            page: page,
            birthDate: birthDate,
            onTapPlaceholder: onTapPlaceholder,
          ),
      },
    );
  }
}

class _CoverBody extends StatelessWidget {
  const _CoverBody({
    required this.page,
    required this.babyName,
    this.babyAvatarUrl,
    this.birthDate,
  });

  final ScrapbookPageModel page;
  final String babyName;
  final String? babyAvatarUrl;
  final DateTime? birthDate;

  bool get _hasAvatar {
    final url = babyAvatarUrl?.trim() ?? '';
    return url.isNotEmpty;
  }

  String? get _birthDateLabel {
    final birth = birthDate;
    if (birth == null) return null;
    final raw = DateFormat('d MMMM yyyy', 'ru').format(birth);
    return 'Дата рождения: $raw';
  }

  String? get _ageLabel {
    final birth = birthDate;
    if (birth == null) return null;
    final age = babyAgeAtDate(birthDate: birth, onDate: DateTime.now());
    if (age.isEmpty) return null;
    return 'Сейчас: $age';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ~2× прежнего (radius 52 → 104), но не выходим за высоту страницы.
        final maxAvatar = (constraints.maxHeight * 0.46).clamp(120.0, 240.0);
        final avatarRadius = (maxAvatar / 2) - 12;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_hasAvatar)
                _CoverAvatarFrame(
                  avatarUrl: babyAvatarUrl!,
                  babyName: babyName,
                  radius: avatarRadius,
                )
              else
                Icon(
                  Icons.menu_book_rounded,
                  size: avatarRadius.clamp(56, 96),
                  color: const Color(0xFF6B5344).withValues(alpha: 0.75),
                ),
              const SizedBox(height: 18),
              Text(
                page.coverTitle ?? babyName,
                textAlign: TextAlign.center,
                style: GoogleFonts.merriweather(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF4A3728),
                  height: 1.2,
                ),
              ),
              if (_birthDateLabel != null) ...[
                const SizedBox(height: 14),
                Text(
                  _birthDateLabel!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.caveat(
                    fontSize: 20,
                    color: const Color(0xFF6B5344),
                  ),
                ),
              ],
              if (_ageLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  _ageLabel!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.caveat(
                    fontSize: 20,
                    color: const Color(0xFF6B5344),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'Семейный альбом первых умений',
                textAlign: TextAlign.center,
                style: GoogleFonts.caveat(
                  fontSize: 18,
                  color: const Color(0xFF8B7355),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Листайте →',
                style: GoogleFonts.caveat(
                  fontSize: 18,
                  color: const Color(0xFF8B7355),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CoverAvatarFrame extends StatelessWidget {
  const _CoverAvatarFrame({
    required this.avatarUrl,
    required this.babyName,
    this.radius = 104,
  });

  final String avatarUrl;
  final String babyName;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF7F0E4),
        border: Border.all(color: const Color(0xFFC4A882), width: 2.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF8B7355).withValues(alpha: 0.55),
            width: 1.3,
          ),
        ),
        child: ChatAvatar(
          name: babyName,
          avatarUrl: avatarUrl,
          radius: radius,
        ),
      ),
    );
  }
}

class _AchievedBody extends StatelessWidget {
  const _AchievedBody({
    required this.page,
    this.birthDate,
    this.onTapMedia,
    this.onTapPlaceholder,
    this.onRequestLayoutEdit,
    this.layoutRevision = 0,
  });

  final ScrapbookPageModel page;
  final DateTime? birthDate;
  final void Function(
    Map<String, dynamic> milestone,
    List<Map<String, dynamic>> media, {
    int initialIndex,
  })? onTapMedia;
  final void Function(Map<String, dynamic> milestone)? onTapPlaceholder;
  final void Function(ScrapbookLayoutEditRequest request)? onRequestLayoutEdit;
  final int layoutRevision;

  @override
  Widget build(BuildContext context) {
    if (page.slots.isEmpty) {
      return Center(
        child: Text(
          'Пока пусто',
          style: GoogleFonts.caveat(
            fontSize: 22,
            color: const Color(0xFF8B7355),
          ),
        ),
      );
    }

    final slot = page.slots.first;
    return ScrapbookMilestoneSlot(
      milestone: slot.milestone,
      achieved: slot.achieved,
      birthDate: birthDate,
      layoutRevision: layoutRevision,
      onTapMedia: (media, {initialIndex = 0}) => onTapMedia?.call(
        slot.milestone,
        media,
        initialIndex: initialIndex,
      ),
      onTapPlaceholder: () => onTapPlaceholder?.call(slot.milestone),
      onRequestLayoutEdit: onRequestLayoutEdit,
    );
  }
}

class _AheadBody extends StatelessWidget {
  const _AheadBody({
    required this.page,
    this.birthDate,
    this.onTapPlaceholder,
  });

  final ScrapbookPageModel page;
  final DateTime? birthDate;
  final void Function(Map<String, dynamic> milestone)? onTapPlaceholder;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (page.sectionTitle != null) ...[
          Text(
            page.sectionTitle!,
            textAlign: TextAlign.center,
            style: GoogleFonts.merriweather(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF4A3728),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: page.slots.isEmpty
              ? Center(
                  child: Text(
                    'Пока пусто',
                    style: GoogleFonts.caveat(
                      fontSize: 22,
                      color: const Color(0xFF8B7355),
                    ),
                  ),
                )
              : ListView.separated(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: page.slots.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final slot = page.slots[index];
                    return SizedBox(
                      height: 120,
                      child: ScrapbookMilestoneSlot(
                        milestone: slot.milestone,
                        achieved: false,
                        birthDate: birthDate,
                        onTapPlaceholder: () =>
                            onTapPlaceholder?.call(slot.milestone),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

String scrapbookCalendarMonthLabel(DateTime month) {
  final raw = DateFormat('LLLL yyyy', 'ru').format(month);
  if (raw.isEmpty) return '';
  return raw[0].toUpperCase() + raw.substring(1);
}
