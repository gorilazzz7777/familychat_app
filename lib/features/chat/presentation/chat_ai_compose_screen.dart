import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorila_chat/gorila_chat.dart' as gorila;

import '../../../core/providers/app_providers.dart';

/// Family Chat wrapper around shared AI compose screen.
class ChatAiComposeScreen extends ConsumerWidget {
  const ChatAiComposeScreen({
    super.key,
    required this.threadId,
    this.initialTask = '',
    this.peerTitle = '',
  });

  final int threadId;
  final String initialTask;
  final String peerTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return gorila.ChatAiComposeScreen(
      initialTask: initialTask,
      peerTitle: peerTitle,
      onCompose: (task) => ref
          .read(familychatRepositoryProvider)
          .aiComposeMessage(threadId, task: task),
    );
  }
}
