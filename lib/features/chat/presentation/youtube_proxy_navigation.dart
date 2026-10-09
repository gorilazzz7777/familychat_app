import 'package:flutter/material.dart';

import '../data/youtube_links.dart';
import 'youtube_proxy_player_screen.dart';

/// Opens YouTube links in the in-app proxied player when possible.
abstract final class YoutubeProxyNavigation {
  /// Returns true if [url] was handled (player opened).
  static Future<bool> tryOpen(BuildContext context, String url) async {
    if (!YoutubeLinks.isYoutubeUrl(url)) return false;
    if (!context.mounted) return false;
    await YoutubeProxyPlayerScreen.open(context, url);
    return true;
  }
}
