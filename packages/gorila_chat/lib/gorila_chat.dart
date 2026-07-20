/// Shared chat package — UI, realtime, contracts.
///
/// Apps implement [ChatRepository] / [ChatCallRepository] / [ChatHost].
library;

export 'src/contract/chat_call_repository.dart';
export 'src/contract/chat_capabilities.dart';
export 'src/contract/chat_host.dart';
export 'src/contract/chat_repository.dart';
export 'src/contract/chat_send_options.dart';
export 'src/realtime/gorila_chat_realtime.dart';
export 'src/util/active_chat_context.dart';
export 'src/util/chat_conversation_session.dart';
export 'src/util/chat_realtime_utils.dart';
export 'src/util/feature_matrix.dart';
export 'src/ui/attach/chat_attach_models.dart';
export 'src/ui/attach/chat_attach_sheet.dart';
export 'src/ui/calls/chat_call_screen.dart';
export 'src/ui/calls/incoming_call_coordinator.dart';
export 'src/ui/calls/incoming_call_screen.dart';
export 'src/ui/conversation/chat_ai_compose_screen.dart';
export 'src/ui/conversation/chat_info_sheet.dart';
export 'src/ui/conversation/gorila_conversation_screen.dart';
export 'src/ui/widgets/chat_avatar.dart';
export 'src/ui/widgets/chat_compose_input.dart';
export 'src/ui/widgets/chat_message_actions_sheet.dart';
export 'src/ui/widgets/chat_pinned_bar.dart';
export 'src/ui/widgets/chat_send_options_sheet.dart';
