import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../routing/app_uri_parser.dart';

/// Восстановление invite после установки через RuStore.
abstract final class DeferredInviteRecovery {
  static const pendingInviteKey = 'pending_invite_token';
  static const pendingFriendInviteKey = 'pending_friend_invite_token';
  static const _clipboardCheckedKey = 'familychat_clipboard_invite_checked';

  static Future<({String? invite, String? friend})> recover({
    required FamilyChatRepository repository,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    var invite = prefs.getString(pendingInviteKey)?.trim();
    var friend = prefs.getString(pendingFriendInviteKey)?.trim();
    if ((invite != null && invite.isNotEmpty) ||
        (friend != null && friend.isNotEmpty)) {
      return (invite: invite, friend: friend);
    }

    final fromClip = await _readClipboardOnce(prefs);
    if (fromClip != null) {
      if (fromClip.isFriend) {
        await prefs.setString(pendingFriendInviteKey, fromClip.token);
        return (invite: null, friend: fromClip.token);
      }
      await prefs.setString(pendingInviteKey, fromClip.token);
      return (invite: fromClip.token, friend: null);
    }

    if (kIsWeb) return (invite: null, friend: null);

    try {
      final resolved = await repository.resolveDeferredInvite();
      final inv = (resolved['invite_token']?.toString() ?? '').trim();
      final fr = (resolved['friend_invite_token']?.toString() ?? '').trim();
      if (inv.isNotEmpty) {
        await prefs.setString(pendingInviteKey, inv);
      }
      if (fr.isNotEmpty) {
        await prefs.setString(pendingFriendInviteKey, fr);
      }
      return (
        invite: inv.isEmpty ? null : inv,
        friend: fr.isEmpty ? null : fr,
      );
    } catch (_) {
      return (invite: null, friend: null);
    }
  }

  static Future<({String token, bool isFriend})?> _readClipboardOnce(
    SharedPreferences prefs,
  ) async {
    if (kIsWeb) return null;
    if (prefs.getBool(_clipboardCheckedKey) == true) return null;
    await prefs.setBool(_clipboardCheckedKey, true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      final friend = extractFriendInviteTokenFromText(text);
      if (friend != null) return (token: friend, isFriend: true);
      final invite = extractInviteTokenFromText(text);
      if (invite != null) return (token: invite, isFriend: false);
    } catch (_) {}
    return null;
  }
}
