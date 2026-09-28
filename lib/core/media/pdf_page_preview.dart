import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Renders the first PDF page to a cached PNG for chat bubbles.
class PdfPagePreview {
  PdfPagePreview._();

  static final Map<String, Future<String?>> _inflight = {};
  static final Map<String, String> _memory = {};
  static bool _initDone = false;

  static bool looksLikePdf({
    String? filename,
    String? contentType,
    String? path,
  }) {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.contains('pdf')) return true;
    final name = (filename ?? path ?? '').toLowerCase();
    return name.endsWith('.pdf');
  }

  /// Returns a local PNG path of page 1, or null on failure / unsupported.
  static Future<String?> firstPageJpegPath(
    String pdfPath, {
    int maxEdge = 420,
  }) async {
    if (kIsWeb || pdfPath.isEmpty) return null;
    final file = File(pdfPath);
    if (!await file.exists()) return null;

    final cached = _memory[pdfPath];
    if (cached != null && await File(cached).exists()) return cached;

    return _inflight.putIfAbsent(pdfPath, () async {
      try {
        final out = await _renderLocked(pdfPath, maxEdge: maxEdge);
        if (out != null) _memory[pdfPath] = out;
        return out;
      } finally {
        _inflight.remove(pdfPath);
      }
    });
  }

  static Future<String?> _renderLocked(
    String pdfPath, {
    required int maxEdge,
  }) async {
    if (!_initDone) {
      await pdfrxFlutterInitialize();
      _initDone = true;
    }

    final cacheDir = await _cacheDir();
    final stat = await File(pdfPath).stat();
    final diskKey =
        '${pdfPath.hashCode.toRadixString(16)}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
    final outPath = p.join(cacheDir.path, '$diskKey.png');
    final existing = File(outPath);
    if (await existing.exists() && await existing.length() > 64) {
      return outPath;
    }

    PdfDocument? doc;
    PdfImage? pageImage;
    ui.Image? uiImage;
    try {
      doc = await PdfDocument.openFile(pdfPath);
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final longest = page.width > page.height ? page.width : page.height;
      final scale = maxEdge / longest;
      final w = (page.width * scale).round().clamp(64, maxEdge * 2);
      final h = (page.height * scale).round().clamp(64, maxEdge * 2);
      pageImage = await page.render(width: w, height: h);
      if (pageImage == null) return null;
      uiImage = await pageImage.createImage();
      final bytes = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      await existing.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return outPath;
    } catch (e, st) {
      debugPrint('[pdf-preview] fail path=$pdfPath err=$e\n$st');
      return null;
    } finally {
      uiImage?.dispose();
      pageImage?.dispose();
      await doc?.dispose();
    }
  }

  static Future<Directory> _cacheDir() async {
    final root = await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'pdf_page_preview'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
