import 'dart:typed_data';

import 'upload_image_exif_log_io.dart'
    if (dart.library.html) 'upload_image_exif_log_stub.dart' as path_io;

Future<Uint8List?> readBytesFromPath(String path) => path_io.readBytesFromPath(path);
