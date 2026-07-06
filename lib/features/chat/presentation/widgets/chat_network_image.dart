import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_realtime_utils.dart';

/// Изображение вложения чата. На web — через API-прокси с JWT (обход CORS).
class ChatNetworkImage extends ConsumerStatefulWidget {
  const ChatNetworkImage({
    super.key,
    required this.threadId,
    required this.attachment,
    this.height,
    this.width,
    this.fit = BoxFit.cover,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double? height;
  final double? width;
  final BoxFit fit;

  @override
  ConsumerState<ChatNetworkImage> createState() => _ChatNetworkImageState();
}

class _ChatNetworkImageState extends ConsumerState<ChatNetworkImage> {
  Map<String, String>? _headers;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _loadHeaders();
    }
  }

  Future<void> _loadHeaders() async {
    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (!mounted || token == null || token.isEmpty) return;
    setState(() => _headers = {'Authorization': 'Bearer $token'});
  }

  String _imageUrl(FamilyChatRepository repo) {
    final attachmentId = chatAsInt(widget.attachment['id']);
    if (kIsWeb && attachmentId != null) {
      return repo.chatAttachmentContentUrl(widget.threadId, attachmentId);
    }
    return widget.attachment['file_url']?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final url = _imageUrl(ref.read(familychatRepositoryProvider));
    if (url.isEmpty) {
      return SizedBox(
        height: widget.height,
        width: widget.width,
        child: const ColoredBox(
          color: Color(0x22000000),
          child: Icon(Icons.broken_image_outlined),
        ),
      );
    }

    if (kIsWeb && _headers == null) {
      return SizedBox(
        height: widget.height,
        width: widget.width,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: _headers,
      height: widget.height,
      width: widget.width,
      fit: widget.fit,
      placeholder: (_, __) => SizedBox(
        height: widget.height,
        width: widget.width,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorWidget: (_, __, ___) => SizedBox(
        height: widget.height,
        width: widget.width,
        child: const ColoredBox(
          color: Color(0x22000000),
          child: Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }
}

String chatAttachmentImageUrl({
  required FamilyChatRepository repo,
  required int threadId,
  required Map<String, dynamic> attachment,
}) {
  final attachmentId = chatAsInt(attachment['id']);
  if (kIsWeb && attachmentId != null) {
    return repo.chatAttachmentContentUrl(threadId, attachmentId);
  }
  return attachment['file_url']?.toString() ?? '';
}

Future<Map<String, String>?> chatImageAuthHeaders(WidgetRef ref) async {
  if (!kIsWeb) return null;
  final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
  if (token == null || token.isEmpty) return null;
  return {'Authorization': 'Bearer $token'};
}
