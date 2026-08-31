import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'impersonation_storage.dart';

bool isAdminEnterUri(Uri uri) =>
    uri.host == 'admin-enter' && (uri.queryParameters['code']?.isNotEmpty ?? false);

Future<bool> handleAdminEnterUri(WidgetRef ref, Uri uri) async {
  if (!isAdminEnterUri(uri)) return false;
  final code = uri.queryParameters['code']!;
  final client = ref.read(apiClientProvider);
  final auth = ref.read(authRepositoryProvider);
  final storage = ImpersonationStorage();

  await storage.backupCurrentSessionIfNeeded(
    readAccess: client.tokenStorage.readAccess,
    readRefresh: client.tokenStorage.readRefresh,
  );

  await client.tokenStorage.clear();

  await auth.exchangeImpersonation(code);
  await storage.markActive();
  return true;
}

Future<void> exitImpersonation(WidgetRef ref) async {
  final storage = ImpersonationStorage();
  final client = ref.read(apiClientProvider);
  final backup = await storage.readBackup();
  await storage.clear();
  if (backup.access != null &&
      backup.refresh != null &&
      backup.access!.isNotEmpty &&
      backup.refresh!.isNotEmpty) {
    await client.tokenStorage.saveTokens(
      access: backup.access!,
      refresh: backup.refresh!,
    );
  } else {
    await client.tokenStorage.clear();
  }
}
