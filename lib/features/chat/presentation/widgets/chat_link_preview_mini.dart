import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/link_preview_service.dart';

/// Компактное превью ссылки над полем ввода (шаринг / compose).
class ChatLinkPreviewMini extends StatefulWidget {
  const ChatLinkPreviewMini({super.key, required this.url});

  final String url;

  @override
  State<ChatLinkPreviewMini> createState() => _ChatLinkPreviewMiniState();
}

class _ChatLinkPreviewMiniState extends State<ChatLinkPreviewMini> {
  ChatLinkPreview? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChatLinkPreviewMini oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _preview = null;
      _load();
    }
  }

  Future<void> _load() async {
    final preview = await LinkPreviewService.instance.load(widget.url);
    if (!mounted) return;
    setState(() => _preview = preview);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (preview == null || !preview.hasCard) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = preview.title?.trim();
    final description = preview.description?.trim();
    final imageUrl = preview.imageUrl?.trim();
    final host = preview.host.isNotEmpty
        ? preview.host
        : LinkPreviewService.displayHost(widget.url);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: imageUrl != null && imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          httpHeaders: kIsWeb
                              ? const {}
                              : const {
                                  'Accept':
                                      'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
                                },
                          errorWidget: (_, __, ___) => ColoredBox(
                            color: cs.surfaceContainerHigh,
                            child: Icon(Icons.link, color: cs.primary, size: 22),
                          ),
                        )
                      : ColoredBox(
                          color: cs.surfaceContainerHigh,
                          child: Icon(Icons.link, color: cs.primary, size: 22),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (title != null && title.isNotEmpty) ? title : host,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (description != null && description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.6)),
        ],
      ),
    );
  }
}
