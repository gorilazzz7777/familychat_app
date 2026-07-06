import 'package:share_handler/share_handler.dart';

import 'share_attachment_loader_stub.dart'
    if (dart.library.io) 'share_attachment_loader_io.dart';

export 'share_attachment_loader_stub.dart'
    if (dart.library.io) 'share_attachment_loader_io.dart';

Future<List<ShareAttachmentData>> readShareAttachments(SharedMedia media) =>
    loadShareAttachments(media);
