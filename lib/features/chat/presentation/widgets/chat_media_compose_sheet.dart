import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/widgets/family_compose_input.dart';

/// Экран подписи к фото перед отправкой (как в Telegram).
class ChatMediaComposeSheet extends StatefulWidget {
  const ChatMediaComposeSheet({
    super.key,
    required this.imageBytes,
    required this.filename,
    required this.onSend,
  });

  final Uint8List imageBytes;
  final String filename;
  final Future<void> Function(String caption) onSend;

  static Future<void> show(
    BuildContext context, {
    required Uint8List imageBytes,
    required String filename,
    required Future<void> Function(String caption) onSend,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.black,
      builder: (_) => ChatMediaComposeSheet(
        imageBytes: imageBytes,
        filename: filename,
        onSend: onSend,
      ),
    );
  }

  @override
  State<ChatMediaComposeSheet> createState() => _ChatMediaComposeSheetState();
}

class _ChatMediaComposeSheetState extends State<ChatMediaComposeSheet> {
  final _captionController = TextEditingController();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final caption = _captionController.text.trim();
    Navigator.of(context).pop();
    await widget.onSend(caption);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.92,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 3,
              child: Image.memory(
                widget.imageBytes,
                fit: BoxFit.contain,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomInset),
            child: FamilyComposeInput(
              controller: _captionController,
              hintText: 'Подпись...',
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSend: _submit,
              fillColor: Colors.white.withValues(alpha: 0.12),
              borderColor: Colors.white.withValues(alpha: 0.2),
              textColor: Colors.white,
              hintColor: Colors.white.withValues(alpha: 0.6),
              sendIconColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
