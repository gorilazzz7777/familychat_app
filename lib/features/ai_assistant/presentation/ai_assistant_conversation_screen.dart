import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/data/familychat_realtime.dart';
import '../data/ai_assistant_api.dart';

class AiAssistantConversationScreen extends ConsumerStatefulWidget {
  const AiAssistantConversationScreen({super.key, required this.sessionId});

  final int sessionId;

  @override
  ConsumerState<AiAssistantConversationScreen> createState() =>
      _AiAssistantConversationScreenState();
}

class _AiAssistantConversationScreenState
    extends ConsumerState<AiAssistantConversationScreen> {
  late final AiAssistantApi _api;
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _pendingFiles =
      <({String filename, String contentType, Uint8List bytes})>[];

  Map<String, dynamic>? _session;
  final List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  String _streamThinking = '';
  String _streamText = '';
  int? _streamingMessageId;

  bool get _inputDisabled => _session?['input_disabled'] == true;

  @override
  void initState() {
    super.initState();
    _api = AiAssistantApi(ref.read(apiClientProvider));
    FamilyChatRealtime.instance.addListener(_onWs);
    _load();
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onWs);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onWs(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    final sid = event['session_id'];
    if (sid != widget.sessionId) return;
    if (ev == 'ai_assistant.delta') {
      final mid = event['message_id'];
      final kind = event['kind']?.toString();
      setState(() {
        _streamingMessageId = mid is int ? mid : int.tryParse('$mid');
        if (kind == 'reset') {
          _streamThinking = '';
          _streamText = '';
          final id = _streamingMessageId;
          if (id != null) {
            final idx = _messages.indexWhere((m) => m['id'] == id);
            if (idx >= 0) {
              _messages[idx] = {
                ..._messages[idx],
                'text': '',
                'thinking': '',
                'citations': const [],
                'status': 'streaming',
              };
            }
          }
        } else if (kind == 'thinking') {
          _streamThinking += event['text']?.toString() ?? '';
        } else if (kind == 'text') {
          _streamText += event['text']?.toString() ?? '';
        } else if (kind == 'citation') {
          final cit = event['citation'];
          if (cit is Map) {
            final idx = _messages.indexWhere((m) => m['id'] == mid);
            if (idx >= 0) {
              final list = List<Map<String, dynamic>>.from(
                (_messages[idx]['citations'] as List?)
                        ?.whereType<Map>()
                        .map((e) => Map<String, dynamic>.from(e)) ??
                    const [],
              );
              list.add(Map<String, dynamic>.from(cit));
              _messages[idx] = {
                ..._messages[idx],
                'citations': list,
                'thinking': _streamThinking.isNotEmpty
                    ? _streamThinking
                    : _messages[idx]['thinking'],
                'text': _streamText.isNotEmpty
                    ? _streamText
                    : _messages[idx]['text'],
                'status': 'streaming',
              };
            }
          }
        } else if (kind == 'title') {
          final title = event['title']?.toString();
          if (title != null && title.isNotEmpty) {
            _session = {...?_session, 'title': title};
          }
        }
        _upsertStreamingBubble();
      });
      _scrollToEnd();
    } else if (ev == 'ai_assistant.done') {
      final msg = event['message'];
      final session = event['session'];
      setState(() {
        if (session is Map) {
          _session = Map<String, dynamic>.from(session);
        }
        if (msg is Map) {
          final m = Map<String, dynamic>.from(msg);
          final id = m['id'];
          final idx = _messages.indexWhere((e) => e['id'] == id);
          if (idx >= 0) {
            _messages[idx] = m;
          } else {
            _messages.add(m);
          }
        }
        _streamThinking = '';
        _streamText = '';
        _streamingMessageId = null;
        _sending = false;
      });
      _scrollToEnd();
    } else if (ev == 'ai_assistant.error') {
      setState(() {
        _sending = false;
        _error = event['error']?.toString() ?? 'Ошибка генерации';
        _streamThinking = '';
        _streamText = '';
        _streamingMessageId = null;
      });
    }
  }

  void _upsertStreamingBubble() {
    final mid = _streamingMessageId;
    if (mid == null) return;
    final idx = _messages.indexWhere((m) => m['id'] == mid);
    final bubble = {
      'id': mid,
      'role': 'assistant',
      'text': _streamText,
      'thinking': _streamThinking,
      'citations': idx >= 0 ? (_messages[idx]['citations'] ?? const []) : const [],
      'status': 'streaming',
    };
    if (idx >= 0) {
      _messages[idx] = {..._messages[idx], ...bubble};
    } else {
      _messages.add(bubble);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _api.listMessages(widget.sessionId);
      final session = data['session'];
      final messages = data['messages'];
      if (!mounted) return;
      setState(() {
        _session = session is Map
            ? Map<String, dynamic>.from(session)
            : null;
        _messages
          ..clear()
          ..addAll(
            (messages is List)
                ? messages
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                : const [],
          );
        _loading = false;
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    final files = await picker.pickMultiImage(imageQuality: 85);
    for (final f in files) {
      final bytes = await f.readAsBytes();
      final name = f.name;
      final mime = name.toLowerCase().endsWith('.png')
          ? 'image/png'
          : 'image/jpeg';
      _pendingFiles.add((filename: name, contentType: mime, bytes: bytes));
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      _pendingFiles.add((
        filename: f.name,
        contentType: 'application/octet-stream',
        bytes: bytes,
      ));
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    if (_sending || _inputDisabled) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingFiles.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
      _streamThinking = '';
      _streamText = '';
    });
    final files = List.of(_pendingFiles);
    _pendingFiles.clear();
    _controller.clear();
    try {
      final res = await _api.sendMessage(
        sessionId: widget.sessionId,
        text: text,
        files: files,
      );
      final userMsg = res['user_message'];
      final assistantMsg = res['assistant_message'];
      final session = res['session'];
      if (!mounted) return;
      setState(() {
        if (session is Map) {
          _session = Map<String, dynamic>.from(session);
        }
        if (userMsg is Map) {
          _messages.add(Map<String, dynamic>.from(userMsg));
        }
        if (assistantMsg is Map) {
          _messages.add(Map<String, dynamic>.from(assistantMsg));
          _streamingMessageId = assistantMsg['id'] is int
              ? assistantMsg['id'] as int
              : int.tryParse('${assistantMsg['id']}');
        }
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = (_session?['title']?.toString().trim().isNotEmpty == true)
        ? _session!['title'].toString()
        : 'AI Ассистент';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) =>
                        _MessageBubble(message: _messages[i]),
                  ),
          ),
          if (_inputDisabled)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(16),
              child: Text(
                'Для продолжения начните новый чат',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            )
          else ...[
            if (_pendingFiles.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (var i = 0; i < _pendingFiles.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          label: Text(_pendingFiles[i].filename),
                          onDeleted: () => setState(() {
                            _pendingFiles.removeAt(i);
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _sending ? null : _pickImages,
                      icon: const Icon(Icons.image_outlined),
                      tooltip: 'Фото',
                    ),
                    IconButton(
                      onPressed: _sending ? null : _pickFiles,
                      icon: const Icon(Icons.attach_file),
                      tooltip: 'Файл',
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        enabled: !_sending,
                        decoration: const InputDecoration(
                          hintText: 'Сообщение',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message['role']?.toString() == 'user';
    final text = message['text']?.toString() ?? '';
    final thinking = message['thinking']?.toString() ?? '';
    final citations = (message['citations'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    final status = message['status']?.toString() ?? '';
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bg = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        child: Card(
          color: bg,
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUser && thinking.isNotEmpty)
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        'Думает',
                        style: theme.textTheme.labelLarge,
                      ),
                      children: [
                        SelectableText(
                          thinking,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (text.isNotEmpty) SelectableText(text),
                if (text.isEmpty && status == 'streaming')
                  Text(
                    '…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (status == 'error')
                  Text(
                    message['error_message']?.toString() ?? 'Ошибка',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (citations.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Источники', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  for (final c in citations)
                    InkWell(
                      onTap: () {
                        final url = c['url']?.toString();
                        if (url == null || url.isEmpty) return;
                        unawaited(launchUrl(Uri.parse(url)));
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          c['title']?.toString().isNotEmpty == true
                              ? c['title'].toString()
                              : (c['url']?.toString() ?? ''),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
