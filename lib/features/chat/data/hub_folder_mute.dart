import 'package:flutter/material.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../familychat/data/familychat_repository.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
import 'chat_hub_folders.dart';
import 'chat_local_mutations.dart';
import 'chat_mutation_coordinator.dart';
import 'chat_offline_outbox.dart';
import 'hub_folder_mute_store.dart';

/// Apply folder mute flag to FC / TG members (current + later via hooks).
abstract final class HubFolderMute {
  /// FC API historically used 1h/4h/8h/24h — map our 2h/6h to nearest
  /// supported key while TDLib gets exact seconds from [HubFolderMuteState].
  static String fcMuteKey(String mode) {
    return switch (mode) {
      'off' => 'off',
      '1h' => '1h',
      '2h' => '1h', // closest shorter; local until tracks real expiry
      '6h' => '8h',
      '24h' => '24h',
      'forever' || 'quiet' => 'forever',
      _ => 'forever',
    };
  }

  static bool isInQuietWindow(
    HubFolderMuteState state, {
    DateTime? now,
  }) {
    final start = state.quietStart;
    final end = state.quietEnd;
    if (start == null || end == null) return false;
    final n = now ?? DateTime.now();
    final startTod = _parseHm(start);
    final endTod = _parseHm(end);
    if (startTod == null || endTod == null) return false;
    final mins = n.hour * 60 + n.minute;
    final a = startTod.hour * 60 + startTod.minute;
    final b = endTod.hour * 60 + endTod.minute;
    if (a == b) return true;
    if (a < b) return mins >= a && mins < b;
    // Overnight window (e.g. 22:00–08:00).
    return mins >= a || mins < b;
  }

  static TimeOfDay? _parseHm(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  /// Seconds until end of quiet window (for TG mute_for), or null.
  static int? quietMuteForSeconds(HubFolderMuteState state) {
    if (!isInQuietWindow(state)) return null;
    final end = _parseHm(state.quietEnd ?? '');
    if (end == null) return 366 * 24 * 3600;
    final now = DateTime.now();
    var endAt = DateTime(now.year, now.month, now.day, end.hour, end.minute);
    if (!endAt.isAfter(now)) {
      endAt = endAt.add(const Duration(days: 1));
    }
    return endAt.difference(now).inSeconds.clamp(60, 366 * 24 * 3600);
  }

  static Future<void> applyFolderState({
    required String folderKey,
    required HubFolderMuteState state,
    required FamilyChatRepository repo,
    required TelegramTdlibService tdlib,
    required List<ChatFolderData> fcFolders,
    required Map<int, Set<String>> tgFolderExtras,
  }) async {
    await HubFolderMuteStore.set(folderKey, state);
    await reconcileFolder(
      folderKey: folderKey,
      repo: repo,
      tdlib: tdlib,
      fcFolders: fcFolders,
      tgFolderExtras: tgFolderExtras,
    );
  }

  static Future<void> clearFolder({
    required String folderKey,
    required FamilyChatRepository repo,
    required TelegramTdlibService tdlib,
    required List<ChatFolderData> fcFolders,
    required Map<int, Set<String>> tgFolderExtras,
  }) async {
    await applyFolderState(
      folderKey: folderKey,
      state: const HubFolderMuteState(mode: 'off'),
      repo: repo,
      tdlib: tdlib,
      fcFolders: fcFolders,
      tgFolderExtras: tgFolderExtras,
    );
  }

  static Future<void> reconcileFolder({
    required String folderKey,
    required FamilyChatRepository repo,
    required TelegramTdlibService tdlib,
    required List<ChatFolderData> fcFolders,
    required Map<int, Set<String>> tgFolderExtras,
  }) async {
    await HubFolderMuteStore.ensureLoaded();
    var state = HubFolderMuteStore.get(folderKey);
    if (state == null || state.mode == 'off') {
      state = const HubFolderMuteState(mode: 'off');
    } else if (!state.isActive && state.mode != 'quiet') {
      await HubFolderMuteStore.clear(folderKey);
      state = const HubFolderMuteState(mode: 'off');
    }

    final members = _membersForFolder(
      folderKey: folderKey,
      fcFolders: fcFolders,
      tgFolderExtras: tgFolderExtras,
      tdlib: tdlib,
    );

    final wantMute = _wantMutedNow(state);
    for (final m in members) {
      try {
        if (m.threadId != null) {
          await _applyFcThread(
            repo: repo,
            threadId: m.threadId!,
            state: state,
            wantMute: wantMute,
          );
        }
        if (m.tgChatId != null && m.tgChatId != 0) {
          await _applyTgChat(
            tdlib: tdlib,
            chatId: m.tgChatId!,
            state: state,
            wantMute: wantMute,
          );
        }
      } catch (e) {
        debugPrint('[folder-mute] member apply failed $folderKey: $e');
      }
    }
  }

  static Future<void> reconcileAll({
    required FamilyChatRepository repo,
    required TelegramTdlibService tdlib,
    required List<ChatFolderData> fcFolders,
    required Map<int, Set<String>> tgFolderExtras,
  }) async {
    await HubFolderMuteStore.ensureLoaded();
    final keys = HubFolderMuteStore.snapshot.keys.toList();
    for (final key in keys) {
      await reconcileFolder(
        folderKey: key,
        repo: repo,
        tdlib: tdlib,
        fcFolders: fcFolders,
        tgFolderExtras: tgFolderExtras,
      );
    }
  }

  /// After a chat was added to a folder — apply that folder's flag if active.
  static Future<void> onMemberAdded({
    required String folderKey,
    int? threadId,
    int? tgChatId,
    required FamilyChatRepository repo,
    required TelegramTdlibService tdlib,
  }) async {
    await HubFolderMuteStore.ensureLoaded();
    final state = HubFolderMuteStore.get(folderKey);
    if (state == null || !state.isActive) return;
    final wantMute = _wantMutedNow(state);
    try {
      if (threadId != null) {
        await _applyFcThread(
          repo: repo,
          threadId: threadId,
          state: state,
          wantMute: wantMute,
        );
      }
      if (tgChatId != null && tgChatId != 0) {
        await _applyTgChat(
          tdlib: tdlib,
          chatId: tgChatId,
          state: state,
          wantMute: wantMute,
        );
      }
    } catch (e) {
      debugPrint('[folder-mute] onMemberAdded failed: $e');
    }
  }

  static bool _wantMutedNow(HubFolderMuteState state) {
    if (state.mode == 'off') return false;
    if (state.mode == 'quiet') return isInQuietWindow(state);
    return state.isActive;
  }

  static Future<void> _applyFcThread({
    required FamilyChatRepository repo,
    required int threadId,
    required HubFolderMuteState state,
    required bool wantMute,
  }) async {
    if (state.mode == 'quiet') {
      if (wantMute) {
        final start = state.quietStart ?? '22:00';
        final end = state.quietEnd ?? '08:00';
        final off = state.utcOffsetMinutes ??
            DateTime.now().timeZoneOffset.inMinutes;
        if (ChatLocalStore.isSupported) {
          await ChatLocalMutations.patchThreadNotificationsLocal(
            threadId,
            {'notifications_enabled': false},
          );
          await ChatOfflineOutbox.enqueueQuietHours(
            threadId: threadId,
            start: start,
            end: end,
            utcOffsetMinutes: off,
          );
          ChatMutationCoordinator.scheduleSync(repo);
        } else {
          await repo.setThreadQuietHours(
            threadId,
            start: start,
            end: end,
            utcOffsetMinutes: off,
          );
        }
      } else {
        // Outside quiet window: enable notifications for this thread.
        if (ChatLocalStore.isSupported) {
          await ChatLocalMutations.patchThreadNotificationsLocal(
            threadId,
            {'notifications_enabled': true},
          );
          await ChatOfflineOutbox.enqueueMute(
            threadId: threadId,
            muteKey: 'off',
          );
          ChatMutationCoordinator.scheduleSync(repo);
        } else {
          await repo.setThreadMute(threadId, 'off');
        }
      }
      return;
    }

    final key = wantMute ? fcMuteKey(state.mode) : 'off';
    if (ChatLocalStore.isSupported) {
      await ChatLocalMutations.patchThreadNotificationsLocal(
        threadId,
        {'notifications_enabled': key == 'off'},
      );
      await ChatOfflineOutbox.enqueueMute(threadId: threadId, muteKey: key);
      ChatMutationCoordinator.scheduleSync(repo);
    } else {
      await repo.setThreadMute(threadId, key);
    }
  }

  static Future<void> _applyTgChat({
    required TelegramTdlibService tdlib,
    required int chatId,
    required HubFolderMuteState state,
    required bool wantMute,
  }) async {
    if (!wantMute) {
      await tdlib.setChatMuted(chatId, muted: false);
      return;
    }
    if (state.mode == 'quiet') {
      final sec = quietMuteForSeconds(state) ?? (366 * 24 * 3600);
      await tdlib.setChatMuted(chatId, muted: true, muteForSeconds: sec);
      return;
    }
    final sec = HubFolderMuteState.muteForSeconds(
      state.mode,
      mutedUntilMs: state.mutedUntilMs,
    );
    await tdlib.setChatMuted(chatId, muted: true, muteForSeconds: sec);
  }

  static List<({int? threadId, int? tgChatId})> _membersForFolder({
    required String folderKey,
    required List<ChatFolderData> fcFolders,
    required Map<int, Set<String>> tgFolderExtras,
    required TelegramTdlibService tdlib,
  }) {
    final out = <({int? threadId, int? tgChatId})>[];
    if (folderKey.startsWith('custom:')) {
      final id = int.tryParse(folderKey.substring(7));
      if (id == null) return out;
      ChatFolderData? folder;
      for (final f in fcFolders) {
        if (f.id == id) {
          folder = f;
          break;
        }
      }
      if (folder == null) return out;
      for (final key in folder.memberKeys) {
        if (key.startsWith('t:')) {
          final tid = int.tryParse(key.substring(2));
          if (tid != null) out.add((threadId: tid, tgChatId: null));
        } else if (key.startsWith('tg:')) {
          final tg = int.tryParse(key.substring(3));
          if (tg != null) out.add((threadId: null, tgChatId: tg));
        }
      }
      return out;
    }
    if (folderKey.startsWith('tg:')) {
      final id = int.tryParse(folderKey.substring(3));
      if (id == null) return out;
      final ids = <int>{...tdlib.chatIdsInFolder(id)};
      final extras = tgFolderExtras[id];
      if (extras != null) {
        for (final key in extras) {
          if (!key.startsWith('tg:')) continue;
          final tg = int.tryParse(key.substring(3));
          if (tg != null) ids.add(tg);
        }
      }
      for (final tg in ids) {
        out.add((threadId: null, tgChatId: tg));
      }
    }
    return out;
  }
}
