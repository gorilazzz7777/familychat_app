import 'package:share_handler/share_handler.dart';

import 'share_attachment_data.dart';

Future<List<ShareAttachmentData>> loadShareAttachments(SharedMedia media) async =>
    const [];

Future<ShareAttachmentData> resolveLoadedShareAttachmentBytes(
  ShareAttachmentData attachment, {
  required int index,
}) async =>
    attachment;

Future<void> finishLoadedShareAttachmentRead() async {}

