import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../../core/widgets/family_app_bar.dart';
import '../../../../core/widgets/family_input_styles.dart';

/// Экран задания для AI-составления сообщения.
class ChatAiComposeScreen extends ConsumerStatefulWidget {
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
  ConsumerState<ChatAiComposeScreen> createState() =>
      _ChatAiComposeScreenState();
}

class _ChatAiComposeScreenState extends ConsumerState<ChatAiComposeScreen> {
  late final TextEditingController _controller;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTask);
    if (widget.initialTask.isNotEmpty) {
      _controller.selection = TextSelection.collapsed(
        offset: widget.initialTask.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final task = _controller.text.trim();
    if (task.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Опишите, о чём составить сообщение')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final suggestion = await ref
          .read(familychatRepositoryProvider)
          .aiComposeMessage(widget.threadId, task: task);
      if (!mounted) return;
      Navigator.of(context).pop(suggestion);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось составить сообщение. Попробуйте ещё раз.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = widget.peerTitle.trim();

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'С помощью AI',
        automaticallyImplyLeading: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'О чём составить сообщение?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (peer.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Чат: $peer',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: DecoratedBox(
                  decoration: FamilyInputStyles.composeShellDecoration(theme),
                  child: TextField(
                    controller: _controller,
                    enabled: !_loading,
                    autofocus: true,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Например: поблагодарить за помощь и предложить встретиться',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Составить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
