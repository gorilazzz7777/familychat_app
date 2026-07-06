import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/familychat/data/familychat_repository.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(apiClientProvider));
});

final familychatRepositoryProvider = Provider<FamilyChatRepository>((ref) {
  return FamilyChatRepository(ref.watch(apiClientProvider));
});
