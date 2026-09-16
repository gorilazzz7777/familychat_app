import 'package:flutter/widgets.dart';

/// Optional copy for [ChatAttachSheet]. Defaults stay Russian for FamilyChat.
class ChatAttachL10n {
  const ChatAttachL10n({
    this.gallery = '\u0413\u0430\u043b\u0435\u0440\u0435\u044f',
    this.file = '\u0424\u0430\u0439\u043b',
    this.allPhotos = '\u0412\u0441\u0435 ;\u0444\u043e\u0442\u043e',
    this.albums = '\u0410\u043b\u044c\u0431\u043e\u043c\u044b',
    this.recent = '\u041d\u0435\u0434\u0430\u0432\u043d\u0438\u0435',
    this.images = '\u0418\u0437\u043e\u0431\u0440\u0430\u0436\u0435\u043d\u0438\u0444f',
    this.camera = '\u041a\u0430\u043c\u0435\u0440\u0430',
    this.screenshots = '\u0421\u043a\u0440\u0438\u043d\u0448\u043e\u0442\u0446',
    this.downloads = '\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0438',
    this.videos = '\u0412\u0438\u0434\u0435\u043e',
    this.retry = '\u041f\u043e\u0432\u0442\u043e\u0440\u0438\u0442\u044c',
    this.openSettings = '\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438',
    this.add = '\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c',
    this.adding = '\u0414\u043e\u0431\u0430\u0432\u043b\u0444\u0435\u0435\u043c\u2026',
    this.captionHint = '\u041f\u043e\u0434\u043f\u0438\u0441\u044c\u2026',
    this.pickFile = '\u0412\u0444\u0431\u0440\u0430\u0442\u044c \u0444\u0430\u0439\u043b',
    this.pickFileSubtitle = '\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0446 \u0438 \u043c\u0435\u0434\u0438\u0430 \u0441\u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0430\u0432',
    this.pickFileSubtitleMedia = '\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0446, \u0444\u043e\u0442\u043e \u0438 \u0412\u0438\u0434\u0435\u043e',
    this.selectedCount = '\u0412\u0444\u0431\u0440\u0430\u043d\u043e: {count}',
    this.photo = '\u0424\u043e\u0442\u043e',
    this.video = '\u0412\u0438\u0434\u0435\u043e',
    this.pickFromGallery = '\u0412\u0444\u0431\u0440\u0430\u0442\u044c \u0438\u0437 \u0433\u0430\u043b\u0435\u0440\u0435\u0438',
    this.chooseMore = '\u0412\u0444\u0431\u0440\u0430\u0442\u044c \u0435\u0449\u0451',
    this.later = '\u041f\u043e\u0437\u0436\u0435',
  });

  final String gallery;
  final String file;
  final String allPhotos;
  final String albums;
  final String recent;
  final String images;
  final String camera;
  final String screenshots;
  final String downloads;
  final String videos;
  final String retry;
  final String openSettings;
  final String add;
  final String adding;
  final String captionHint;
  final String pickFile;
  final String pickFileSubtitle;
  final String pickFileSubtitleMedia;
  final String selectedCount;
  final String photo;
  final String video;
  final String pickFromGallery;
  final String chooseMore;
  final String later;

  static const russian = ChatAttachL10n();

  static ChatAttachL10n of(BuildContext context) =>
      ChatAttachL10nScope.of(context);

  String selected(int count) =>
      selectedCount.replaceAll('{count}', '$count');
}

class ChatAttachL10nScope extends InheritedWidget {
  const ChatAttachL10nScope({
    super.key,
    required this.l10n,
    required super.child,
  });

  final ChatAttachL10n l10n;

  static ChatAttachL10n of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<ChatAttachL10nScope>()
            ?.l10n ??
        ChatAttachL10n.russian;
  }

  @override
  bool updateShouldNotify(ChatAttachL10nScope oldWidget) =>
      l10n != oldWidget.l10n;
}
