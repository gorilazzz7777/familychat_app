import 'dart:async';

import 'package:flutter/material.dart';

import '../../familychat/data/familychat_repository.dart';
import 'chat_call_screen.dart';

Future<void> showIncomingCallDialog(
  BuildContext context, {
  required FamilyChatRepository repository,
  required int callId,
  required int threadId,
  required String callerName,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Входящий звонок'),
      content: Text(callerName.isNotEmpty ? callerName : 'Family Chat'),
      actions: [
        TextButton(
          onPressed: () async {
            await repository.callAction(callId, 'decline');
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('Отклонить'),
        ),
        FilledButton(
          onPressed: () async {
            await repository.callAction(callId, 'accept');
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
            unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ChatCallScreen(
                    threadId: threadId,
                    title: callerName.isNotEmpty ? callerName : 'Чат',
                    callId: callId,
                    isCaller: false,
                  ),
                ),
              ),
            );
          },
          child: const Text('Ответить'),
        ),
      ],
    ),
  );
}
