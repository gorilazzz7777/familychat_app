import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/link_preview_service.dart';

class ChatLinkPreviewTile extends StatefulWidget {
  const ChatLinkPreviewTile({
    super.key,
    required this.url,
    this.onTap,
  });

  final String url;
  final VoidCallback? onTap;

  @override
  State<ChatLinkPreviewTile> createState() => _ChatLinkPreviewTileState();
}

class _ChatLinkPreviewTileState extends State<ChatLinkPreviewTile> {
  ChatLinkPreview? _preview;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChatLinkPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _preview = null;
      _tried = false;
      _load();
    }
  }

  Future<void> _load() async {
    final preview = await LinkPreviewService.instance.load(widget.url);
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _tried = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final host = LinkPreviewService.displayHost(widget.url);
    final path = LinkPreviewService.displayPath(widget.url);
    final title = _preview?.title?.trim();
    final description = _preview?.description?.trim();
    final imageUrl = _preview?.imageUrl;
    final showCard = _tried && _preview != null && _preview!.hasCard;

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showCard && imageUrl != null && imageUrl.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => ColoredBox(
                          color: cs.surfaceContainerHigh,
                          child: Icon(
                            Icons.link,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 2),
                  child: Icon(Icons.link, color: cs.primary),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (title != null && title.isNotEmpty) ? title : host,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    if (title != null && title.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        path.isNotEmpty ? '$host$path' : host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ] else if (path.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                    if (description != null && description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
