import 'dart:html' as html;

import 'package:flutter/foundation.dart';

import '../../features/chat/data/familychat_presence_service.dart';

void installWebVisibilityPresenceListener() {
  if (!kIsWeb) return;
  void onChange(html.Event _) {
    final visible = !(html.document.hidden ?? false);
    FamilyChatPresenceService.onWebVisibilityChanged(visible: visible);
  }

  html.document.onVisibilityChange.listen(onChange);
}
