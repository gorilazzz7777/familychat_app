import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/link_preview_service.dart';

/// Превью ссылки в пузыре: сайт, заголовок страницы и фото со ссылки.
class ChatLinkPreviewCard extends StatefulWidget {
  const ChatLinkPreviewCard({
    super.key,
    required this.url,
    required this.isMine,
    this.maxWidth,
  });

  final String url;
  final bool isMine;
  final double? maxWidth;

  @override
  State<ChatLinkPreviewCard> createState() => _ChatLinkPreviewCardState();
}

class _ChatLinkPreviewCardState extends State<ChatLinkPreviewCard> {
  ChatLinkPreview? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChatLinkPreviewCard oldWidget) {
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

  Future<void> _open() async {
    final raw = LinkPreviewService.isUnusablePageUrl(_preview?.canonicalUrl)
        ? widget.url
        : (_preview?.canonicalUrl ?? widget.url).trim();
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final theme = Theme.of(context);
    final isMine = widget.isMine;
    final accent = isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary;
    final titleColor =
        isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final descColor = isMine
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.82)
        : theme.colorScheme.onSurfaceVariant;
    final host = (preview?.host.trim().isNotEmpty == true)
        ? preview!.host.trim()
        : LinkPreviewService.displayHost(widget.url);
    final siteName = preview?.siteName?.trim();
    final title = preview?.title?.trim();
    final description = preview?.description?.trim();
    final imageUrl = preview?.imageUrl?.trim();
    final source = (siteName != null && siteName.isNotEmpty) ? siteName : host;
    final showTitle = title != null &&
        title.isNotEmpty &&
        title.toLowerCase() != source.toLowerCase();
    final width = widget.maxWidth ?? 280;

    return Material(
      color: titleColor.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: _open,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 3,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              source,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accent,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            if (showTitle) ...[
                              const SizedBox(height: 2),
                              Text(
                                title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: titleColor,
                                  fontWeight: FontWeight.w700,
                                  height: 1.25,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                            if (description != null &&
                                description.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                description,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: descColor,
                                  height: 1.25,
                                  decoration: TextDecoration.none,
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
              if (imageUrl != null && imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(10),
                  ),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      httpHeaders: kIsWeb
                          ? const {}
                          : const {
                              'Accept':
                                  'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
                            },
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
