import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
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
    final preview = (_preview != null && !_preview!.isGenericBrand)
        ? _preview
        : null;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final host = preview?.host.isNotEmpty == true
        ? preview!.host
        : LinkPreviewService.displayHost(widget.url);
    final title = LinkPreviewService.displayTitle(
      originalUrl: widget.url,
      preview: preview,
    );
    final description = preview?.description?.trim();
    final showDescription = description != null &&
        description.isNotEmpty &&
        !description.toLowerCase().contains('найдётся всё') &&
        !description.toLowerCase().contains('найдется все');
    final imageUrl = preview?.imageUrl?.trim();
    final urlLabel = LinkPreviewService.displayPageUrl(
      widget.url,
      preview?.canonicalUrl,
    );
    final letter = host.isNotEmpty ? host[0].toUpperCase() : '#';

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
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 72,
                    height: 72,
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
                            placeholder: (_, __) => ColoredBox(
                              color: cs.surfaceContainerHigh,
                              child: const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            ),
                            errorWidget: (_, __, ___) => _LetterThumb(
                              letter: letter,
                              color: cs.primary,
                              background: cs.primaryContainer,
                            ),
                          )
                        : _LetterThumb(
                            letter: _tried ? letter : '',
                            color: cs.primary,
                            background: cs.surfaceContainerHigh,
                            loading: !_tried,
                          ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    if (showDescription) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      urlLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.primary,
                        decoration: TextDecoration.none,
                      ),
                    ),
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

class _LetterThumb extends StatelessWidget {
  const _LetterThumb({
    required this.letter,
    required this.color,
    required this.background,
    this.loading = false,
  });

  final String letter;
  final Color color;
  final Color background;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: background,
      child: Center(
        child: loading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: color,
                ),
              )
            : Text(
                letter,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 22,
                ),
              ),
      ),
    );
  }
}
