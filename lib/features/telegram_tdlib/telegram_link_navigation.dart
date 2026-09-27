import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/push/push_navigation.dart';
import 'presentation/telegram_conversation_screen.dart';
import 'telegram_link_utils.dart';
import 'telegram_tdlib_service.dart';

/// Opens `t.me` / `tg://` links inside FC when TDLib is ready.
abstract final class TelegramLinkNavigation {
  /// Returns true if the URL was handled in-app.
  ///
  /// [onSameChat] — optional: when the link points at [currentChatId], call this
  /// instead of pushing another conversation route (jump in place).
  static Future<bool> tryOpen(
    String rawUrl, {
    int? currentChatId,
    Future<void> Function(int messageId)? onSameChat,
  }) async {
    if (!TelegramLinkUtils.looksLikeTelegramLink(rawUrl)) return false;
    final svc = TelegramTdlibService.instance;
    if (!svc.isReady) return false;

    final target = await svc.resolveTelegramLink(rawUrl);
    if (target == null) return false;

    if (currentChatId != null &&
        target.chatId == currentChatId &&
        onSameChat != null) {
      final mid = target.messageId;
      if (mid != null && mid > 0) {
        await onSameChat(mid);
      }
      return true;
    }

    final nav = familyChatNavigatorKey.currentState;
    if (nav == null) return false;
    await nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TelegramConversationScreen(
          chatId: target.chatId,
          title: target.title.isNotEmpty ? target.title : 'Telegram',
          initialMessageId: target.messageId,
        ),
      ),
    );
    return true;
  }

  /// Try in-app open; fall back to external browser/Telegram.
  static Future<void> openOrLaunch(
    String rawUrl, {
    int? currentChatId,
    Future<void> Function(int messageId)? onSameChat,
  }) async {
    final handled = await tryOpen(
      rawUrl,
      currentChatId: currentChatId,
      onSameChat: onSameChat,
    );
    if (handled) return;
    var value = rawUrl.trim();
    if (value.startsWith('@') && value.length > 1) {
      value = 'https://t.me/${value.substring(1)}';
    } else if (!value.startsWith('http://') &&
        !value.startsWith('https://') &&
        !value.startsWith('tg://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
