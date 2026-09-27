import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_materialize.dart';

/// Ensures a remote guest session exists before a write.
///
/// Returns true on success; shows a snackbar and returns false on failure.
Future<bool> ensureRemoteSessionForWrite({
  required WidgetRef ref,
  BuildContext? context,
}) async {
  try {
    final ok = await ensureMaterializedSession(ref);
    if (!ok) {
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нужен интернет, чтобы продолжить'),
          ),
        );
      }
      return false;
    }
    return true;
  } catch (_) {
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Нужен интернет, чтобы продолжить'),
        ),
      );
    }
    return false;
  }
}
