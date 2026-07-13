import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_compose_input.dart';
import '../data/familychat_realtime.dart';

class FamilyChatScreen extends ConsumerStatefulWidget {
  const FamilyChatScreen({super.key});

  @override
  ConsumerState<FamilyChatScreen> createState() => _FamilyChatScreenState();
}

class _FamilyChatScreenState extends ConsumerState<FamilyChatScreen> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;

  void _onRealtime(Map<String, dynamic> event) {
    if (event['event'] != 'chat_message') return;
    final msg = event['message'];
    if (msg is! Map) return;
    final map = Map<String, dynamic>.from(msg);
    if (!mounted) return;
    setState(() {
      if (!_messages.any((m) => m['id'] == map['id'])) {
        _messages = [..._messages, map];
      }
    });
  }

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    _load();
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).familyChatMessages();
      if (!mounted) return;
      setState(() {
        _messages = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty) return;
    _controller.clear();
    try {
      final msg = await ref.read(familychatRepositoryProvider).sendFamilyChat(body);
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m['id'] == msg['id'])) {
          _messages = [..._messages, msg];
        }
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat.Hm();
    return Column(
      children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
                      final created = DateTime.tryParse(m['created_at']?.toString() ?? '');
                      return ListTile(
                        title: Text(m['sender_name']?.toString() ?? ''),
                        subtitle: Text(m['body']?.toString() ?? ''),
                        trailing: created != null ? Text(timeFmt.format(created.toLocal())) : null,
                      );
                    },
                  ),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FamilyComposeInput(
              controller: _controller,
              hintText: 'Сообщение...',
              textInputAction: TextInputAction.send,
              onSend: _send,
            ),
          ),
        ),
      ],
    );
  }
}
