import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/device_id_storage.dart';
import '../data/auth_repository.dart';
import 'local_anonymous.dart';

Completer<bool>? _materializeInFlight;

/// Creates server guest if the session is still local-anonymous (no JWT).
///
/// Idempotent under concurrent callers. Requires network.
Future<bool> ensureMaterializedSession(WidgetRef ref) async {
  final auth = ref.read(authRepositoryProvider);
  if (await auth.hasSession()) {
    return true;
  }

  final existing = _materializeInFlight;
  if (existing != null) {
    return existing.future;
  }

  final completer = Completer<bool>();
  _materializeInFlight = completer;

  try {
    await DeviceIdStorage.getOrCreate();
    if (!await auth.tryDeviceAuth()) {
      await auth.guestLogin();
    } else {
      await auth.syncGuestSessionFlag();
    }
    if (!await auth.hasSession()) {
      completer.complete(false);
      return false;
    }
    unawaited(auth.ensureDeviceBound());
    completer.complete(true);
    return true;
  } catch (e, st) {
    if (!completer.isCompleted) {
      completer.completeError(e, st);
    }
    rethrow;
  } finally {
    _materializeInFlight = null;
  }
}

/// True when [status] is local-anonymous or there is no refresh token yet.
Future<bool> needsSessionMaterialize(
  AuthRepository auth, {
  Map<String, dynamic>? status,
}) async {
  if (isLocalAnonymousStatus(status)) return true;
  return !(await auth.hasSession());
}
