import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/media/gallery_media_utils.dart';

/// Макс. высота миниатюры в пузыре (~как в Telegram).
double chatMediaMaxThumbHeight(double maxWidth) =>
    (maxWidth * 1.7).clamp(220.0, 420.0);

/// w/h из полей вложения, если сервер/клиент их уже положили.
double? chatAttachmentAspectRatio(Map<String, dynamic> attachment) {
  double? numField(String key) {
    final v = attachment[key];
    if (v is num && v > 0) return v.toDouble();
    return null;
  }

  final w = numField('width') ??
      numField('image_width') ??
      numField('thumb_width') ??
      numField('w');
  final h = numField('height') ??
      numField('image_height') ??
      numField('thumb_height') ??
      numField('h');
  if (w != null && h != null && h > 0) return w / h;

  final exif = attachment['photo_exif'];
  if (exif is Map) {
    final ew = (exif['ImageWidth'] as num?)?.toDouble() ??
        (exif['PixelXDimension'] as num?)?.toDouble() ??
        (exif['width'] as num?)?.toDouble();
    final eh = (exif['ImageLength'] as num?)?.toDouble() ??
        (exif['PixelYDimension'] as num?)?.toDouble() ??
        (exif['height'] as num?)?.toDouble();
    if (ew != null && eh != null && eh > 0) return ew / eh;
  }
  return null;
}

/// Вписать медиа в maxWidth×maxHeight с сохранением пропорций (без обрезки).
Size chatFitMediaSize({
  required double aspectRatio,
  required double maxWidth,
  required double maxHeight,
}) {
  var aspect = aspectRatio;
  if (aspect <= 0 || !aspect.isFinite) aspect = 4 / 3;
  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }
  if (width > maxWidth) {
    width = maxWidth;
    height = width / aspect;
  }
  return Size(width, height);
}

Future<Size?> chatDecodeImageSize(Uint8List bytes) async {
  if (!isSafeUiPreviewBytes(bytes)) return null;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    if (size.width <= 0 || size.height <= 0) return null;
    return size;
  } catch (_) {
    return null;
  }
}
