/// Shared chat package — realtime, contracts, message utilities.
///
/// Apps provide a URI builder and [ChatCapabilities].
/// Family Chat is the reference consumer; TeamCoach plugs in via adapter.
library;

export 'src/contract/chat_capabilities.dart';
export 'src/contract/chat_host.dart';
export 'src/contract/chat_repository.dart';
export 'src/realtime/gorila_chat_realtime.dart';
export 'src/util/chat_realtime_utils.dart';
export 'src/util/chat_conversation_session.dart';
export 'src/util/feature_matrix.dart';
