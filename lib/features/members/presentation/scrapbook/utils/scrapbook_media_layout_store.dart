import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:shared_preferences/shared_preferences.dart';

/// Нормализованный прямоугольник медиа на странице альбома.
///
/// `left`/`width` — доли ширины контейнера.
/// `top`/`height` — доли **той же ширины** (width-space), чтобы раскладка
/// на вебе и в приложении сохраняла относительные размеры независимо от
/// высоты медиа-зоны. Старые записи (без `v:2`) интерпретируются через
/// [containerAspect] или текущую высоту контейнера.
class ScrapbookMediaRect {
  const ScrapbookMediaRect({
    required this.left,
    required this.top,
    required this.width,
    this.height,
    this.aspect,
    this.rotationDeg = 0,
    this.containerAspect,
    this.spaceVersion = 2,
  });

  /// Доля ширины контейнера.
  final double left;

  /// Доля высоты (v1) или ширины (v2) контейнера — см. [spaceVersion].
  final double top;

  /// Доля ширины контейнера.
  final double width;

  /// Доля высоты (v1) или ширины (v2). Если null — через [aspect].
  final double? height;

  /// Зафиксированный aspect (width/height кадра) на момент сохранения.
  final double? aspect;

  /// Поворот кадра в градусах (по часовой стрелке).
  final double rotationDeg;

  /// W/H медиа-зоны в момент сохранения (для миграции v1 и fit).
  final double? containerAspect;

  /// 1 = top/height от высоты контейнера; 2 = от ширины (канон).
  final int spaceVersion;

  bool get hasStableSize =>
      (height != null && height! > 0) || (aspect != null && aspect! > 0);

  ScrapbookMediaRect copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
    double? aspect,
    double? rotationDeg,
    double? containerAspect,
    int? spaceVersion,
  }) {
    return ScrapbookMediaRect(
      left: left ?? this.left,
      top: top ?? this.top,
      width: width ?? this.width,
      height: height ?? this.height,
      aspect: aspect ?? this.aspect,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      containerAspect: containerAspect ?? this.containerAspect,
      spaceVersion: spaceVersion ?? this.spaceVersion,
    );
  }

  Map<String, dynamic> toJson() => {
        'l': left,
        't': top,
        'w': width,
        if (height != null) 'h': height,
        if (aspect != null) 'a': aspect,
        if (rotationDeg != 0) 'r': rotationDeg,
        if (containerAspect != null) 'ca': containerAspect,
        'v': spaceVersion,
      };

  factory ScrapbookMediaRect.fromJson(Map<String, dynamic> json) {
    final version = (json['v'] as num?)?.toInt() ?? 1;
    return ScrapbookMediaRect(
      left: (json['l'] as num?)?.toDouble() ?? 0,
      top: (json['t'] as num?)?.toDouble() ?? 0,
      width: (json['w'] as num?)?.toDouble() ?? 0.4,
      height: (json['h'] as num?)?.toDouble(),
      aspect: (json['a'] as num?)?.toDouble(),
      rotationDeg: (json['r'] as num?)?.toDouble() ?? 0,
      containerAspect: (json['ca'] as num?)?.toDouble(),
      spaceVersion: version,
    );
  }

  /// Пиксели в «виртуальной» системе (ширина = [containerW], высота из ca/v).
  /// Затем [fitRectsIntoArea] масштабирует группу под реальную зону.
  RectPx toPixels({
    required double aspect,
    required double containerW,
    required double containerH,
  }) {
    if (containerW <= 0) {
      return const RectPx(left: 0, top: 0, width: 0, height: 0);
    }
    final ar = (this.aspect != null && this.aspect! > 0)
        ? this.aspect!
        : (aspect > 0 ? aspect : 1.0);

    late final double virtualH;
    if (spaceVersion >= 2) {
      virtualH = containerW;
    } else if (containerAspect != null && containerAspect! > 0) {
      virtualH = containerW / containerAspect!;
    } else {
      virtualH = containerH > 0 ? containerH : containerW;
    }

    final w = width * containerW;
    // Рамка всегда по пропорциям фото — иначе contain даёт «поля» внутри.
    final h = ar > 0
        ? w / ar
        : ((height != null && height! > 0) ? height! * virtualH : w);
    return RectPx(
      left: left * containerW,
      top: top * virtualH,
      width: w,
      height: h,
    );
  }

  /// Дописать height/aspect, не меняя положение (миграция старых раскладок).
  ScrapbookMediaRect withStableSize({
    required double aspect,
    required double containerW,
    required double containerH,
  }) {
    if (hasStableSize && height != null && spaceVersion >= 2) {
      return copyWith(aspect: this.aspect ?? aspect);
    }
    final px = toPixels(
      aspect: aspect,
      containerW: containerW,
      containerH: containerH,
    );
    return fromPixels(
      rect: px,
      containerW: containerW,
      containerH: containerH,
      rotationDeg: rotationDeg,
      aspect: aspect,
    );
  }

  /// Переводит v1 → v2 (width-space) при известных размерах контейнера.
  ScrapbookMediaRect toWidthSpace({
    required double containerW,
    required double containerH,
    required double aspect,
  }) {
    if (spaceVersion >= 2) {
      return copyWith(
        containerAspect: containerAspect ??
            (containerH > 0 ? containerW / containerH : null),
      );
    }
    final px = toPixels(
      aspect: aspect,
      containerW: containerW,
      containerH: containerH,
    );
    return fromPixels(
      rect: px,
      containerW: containerW,
      containerH: containerH,
      rotationDeg: rotationDeg,
      aspect: this.aspect ?? aspect,
    );
  }

  static ScrapbookMediaRect fromPixels({
    required RectPx rect,
    required double containerW,
    required double containerH,
    double rotationDeg = 0,
    double? aspect,
  }) {
    if (containerW <= 0 || containerH <= 0) {
      return ScrapbookMediaRect(
        left: 0,
        top: 0,
        width: 0.4,
        height: 0.4,
        aspect: aspect,
        rotationDeg: rotationDeg,
        containerAspect: null,
        spaceVersion: 2,
      );
    }
    final ar = aspect ??
        (rect.height > 0 ? rect.width / rect.height : null);
    // v2: всё в долях ширины — одинаковый вид при любой высоте зоны.
    return ScrapbookMediaRect(
      left: (rect.left / containerW).clamp(0.0, 2.0),
      top: (rect.top / containerW).clamp(0.0, 4.0),
      width: (rect.width / containerW).clamp(0.08, 1.0),
      height: (rect.height / containerW).clamp(0.08, 4.0),
      aspect: ar,
      rotationDeg: rotationDeg,
      containerAspect: containerW / containerH,
      spaceVersion: 2,
    );
  }
}

class RectPx {
  const RectPx({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  RectPx copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
  }) {
    return RectPx(
      left: left ?? this.left,
      top: top ?? this.top,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }

  RectPx scaled(double s, {double ox = 0, double oy = 0}) {
    return RectPx(
      left: left * s + ox,
      top: top * s + oy,
      width: width * s,
      height: height * s,
    );
  }

  RectPx clampedTo(double maxW, double maxH) {
    var w = width.clamp(48.0, maxW);
    var h = height.clamp(48.0, maxH);
    final aspect = width > 0 ? width / height : 1.0;
    if (w / aspect > maxH) {
      h = maxH;
      w = h * aspect;
    } else {
      h = w / aspect;
    }
    var l = left.clamp(0.0, maxW - w);
    var t = top.clamp(0.0, maxH - h);
    return RectPx(left: l, top: t, width: w, height: h);
  }
}

/// Равномерно вписывает группу кадров в зону, сохраняя относительные размеры.
List<RectPx> fitRectsIntoArea(List<RectPx> rects, Size area, {double pad = 0}) {
  if (rects.isEmpty || area.width <= 0 || area.height <= 0) return rects;
  var minL = double.infinity;
  var minT = double.infinity;
  var maxR = 0.0;
  var maxB = 0.0;
  for (final r in rects) {
    minL = math.min(minL, r.left);
    minT = math.min(minT, r.top);
    maxR = math.max(maxR, r.right);
    maxB = math.max(maxB, r.bottom);
  }
  final contentW = math.max(1.0, maxR - minL);
  final contentH = math.max(1.0, maxB - minT);
  final availW = math.max(1.0, area.width - pad * 2);
  final availH = math.max(1.0, area.height - pad * 2);
  final scale = math.min(availW / contentW, availH / contentH);
  final usedW = contentW * scale;
  final usedH = contentH * scale;
  final ox = pad + (availW - usedW) / 2 - minL * scale;
  final oy = pad + (availH - usedH) / 2 - minT * scale;
  return [for (final r in rects) r.scaled(scale, ox: ox, oy: oy)];
}

String scrapbookMediaLayoutKey(Map<String, dynamic> attachment) {
  final id = attachment['id'];
  if (id != null) return 'id:$id';
  final url = attachment['url']?.toString() ??
      attachment['file_url']?.toString() ??
      '';
  return 'url:${url.hashCode}';
}

/// Все возможные ключи раскладки для одного вложения (id и url).
List<String> scrapbookMediaLayoutKeys(Map<String, dynamic> attachment) {
  final keys = <String>[];
  final id = attachment['id'];
  if (id != null) keys.add('id:$id');
  final url = attachment['url']?.toString() ??
      attachment['file_url']?.toString() ??
      '';
  if (url.isNotEmpty) keys.add('url:${url.hashCode}');
  return keys;
}

ScrapbookMediaRect? scrapbookLookupLayout(
  Map<String, ScrapbookMediaRect> layouts,
  Map<String, dynamic> attachment,
) {
  for (final key in scrapbookMediaLayoutKeys(attachment)) {
    final found = layouts[key];
    if (found != null) return found;
  }
  return null;
}

/// Сопоставляет сохранённые раскладки текущим медиа (в т.ч. при смене ключей).
Map<String, ScrapbookMediaRect> scrapbookAlignLayoutsToMedia({
  required Map<String, ScrapbookMediaRect> layouts,
  required List<Map<String, dynamic>> media,
}) {
  if (layouts.isEmpty || media.isEmpty) return {};
  final out = <String, ScrapbookMediaRect>{};
  final used = <String>{};

  for (final item in media.take(6)) {
    final primary = scrapbookMediaLayoutKey(item);
    final hit = scrapbookLookupLayout(layouts, item);
    if (hit != null) {
      out[primary] = hit;
      for (final k in scrapbookMediaLayoutKeys(item)) {
        if (layouts.containsKey(k)) used.add(k);
      }
    }
  }

  if (out.length >= media.take(6).length) return out;

  // Fallback: по порядку значений (стабильная сортировка ключей).
  final leftover = layouts.entries
      .where((e) => !used.contains(e.key) && !e.key.startsWith('_'))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  var li = 0;
  for (final item in media.take(6)) {
    final primary = scrapbookMediaLayoutKey(item);
    if (out.containsKey(primary)) continue;
    if (li >= leftover.length) break;
    out[primary] = leftover[li++].value;
  }
  return out;
}

/// Кэш раскладок + prefs. [peek] синхронный — без прыжков на первом кадре.
class ScrapbookMediaLayoutStore {
  static const _prefsPrefix = 'scrapbook_media_layout_v2:';
  static const _aspectPrefsPrefix = 'scrapbook_media_aspect_v1:';

  /// code → layouts (ключ есть = уже грузили из prefs).
  static final Map<String, Map<String, ScrapbookMediaRect>> _layoutCache = {};

  /// mediaKey → aspect ratio
  static final Map<String, double> _aspectCache = {};

  static bool hasLayouts(String milestoneCode) =>
      _layoutCache.containsKey(milestoneCode);

  /// Синхронный снимок. null если ещё не префетчили.
  static Map<String, ScrapbookMediaRect>? peek(String milestoneCode) {
    final cached = _layoutCache[milestoneCode];
    if (cached == null) return null;
    return Map<String, ScrapbookMediaRect>.from(cached);
  }

  static double? peekAspect(String mediaKey) => _aspectCache[mediaKey];

  static void putAspect(String mediaKey, double aspect) {
    if (aspect > 0) _aspectCache[mediaKey] = aspect;
  }

  static Future<void> preload(
    Iterable<String> milestoneCodes, {
    Iterable<Map<String, dynamic>>? mediaForAspects,
  }) async {
    final codes = milestoneCodes.where((c) => c.isNotEmpty).toSet();
    await Future.wait([
      ...codes.map(load),
      if (mediaForAspects != null) warmAspects(mediaForAspects),
    ]);
  }

  static Future<void> warmAspects(
    Iterable<Map<String, dynamic>> media,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    for (final item in media) {
      final key = scrapbookMediaLayoutKey(item);
      if (_aspectCache.containsKey(key)) continue;
      final raw = prefs.getDouble('$_aspectPrefsPrefix$key');
      if (raw != null && raw > 0) {
        _aspectCache[key] = raw;
      }
    }
  }

  static Future<void> persistAspect(String mediaKey, double aspect) async {
    if (aspect <= 0) return;
    _aspectCache[mediaKey] = aspect;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_aspectPrefsPrefix$mediaKey', aspect);
  }

  static Future<Map<String, ScrapbookMediaRect>> load(String milestoneCode) async {
    if (milestoneCode.isEmpty) return {};
    final existing = _layoutCache[milestoneCode];
    if (existing != null) {
      return Map<String, ScrapbookMediaRect>.from(existing);
    }

    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString('$_prefsPrefix$milestoneCode');
    // Миграция со старого префикса v1.
    if (raw == null || raw.isEmpty) {
      raw = prefs.getString('scrapbook_media_layout_v1:$milestoneCode');
    }
    if (raw == null || raw.isEmpty) {
      _layoutCache[milestoneCode] = {};
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _layoutCache[milestoneCode] = {};
        return {};
      }
      final out = <String, ScrapbookMediaRect>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map) {
          out[entry.key.toString()] = ScrapbookMediaRect.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      }
      _layoutCache[milestoneCode] = out;
      return Map<String, ScrapbookMediaRect>.from(out);
    } catch (_) {
      _layoutCache[milestoneCode] = {};
      return {};
    }
  }

  /// Пишет раскладку и мержит в кэш памяти.
  static Future<void> save(
    String milestoneCode,
    Map<String, ScrapbookMediaRect> layouts,
  ) async {
    if (milestoneCode.isEmpty) return;
    final copy = Map<String, ScrapbookMediaRect>.from(layouts);
    _layoutCache[milestoneCode] = copy;

    final prefs = await SharedPreferences.getInstance();
    final encoded = <String, dynamic>{
      for (final e in copy.entries) e.key: e.value.toJson(),
    };
    await prefs.setString('$_prefsPrefix$milestoneCode', jsonEncode(encoded));
  }

  /// Сбросить раскладку (память + prefs), чтобы собрался новый default.
  static Future<void> clear(String milestoneCode) async {
    if (milestoneCode.isEmpty) return;
    _layoutCache[milestoneCode] = {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefsPrefix$milestoneCode');
    await prefs.remove('scrapbook_media_layout_v1:$milestoneCode');
  }

  /// Применить раскладки с сервера (не затирает prefs, если сервер пуст).
  static Future<void> hydrateFromServer(
    String milestoneCode,
    Map<String, dynamic>? raw, {
    List<Map<String, dynamic>>? media,
  }) async {
    if (milestoneCode.isEmpty || raw == null || raw.isEmpty) return;
    final parsed = <String, ScrapbookMediaRect>{};
    for (final e in raw.entries) {
      final key = e.key.toString();
      if (key.startsWith('_')) continue;
      final value = e.value;
      if (value is Map) {
        parsed[key] = ScrapbookMediaRect.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    }
    if (parsed.isEmpty) return;
    final aligned = media == null || media.isEmpty
        ? parsed
        : scrapbookAlignLayoutsToMedia(layouts: parsed, media: media);
    if (aligned.isEmpty) return;
    await save(milestoneCode, aligned);
  }

  static Map<String, dynamic> layoutsToJson(
    Map<String, ScrapbookMediaRect> layouts,
  ) {
    return {
      for (final e in layouts.entries) e.key: e.value.toJson(),
    };
  }

  /// Раскладка по умолчанию: для 3–4 фото — scrapbook-коллаж (как в приложении).
  static Map<String, ScrapbookMediaRect> defaultLayouts({
    required List<Map<String, dynamic>> media,
    required List<double> aspects,
    required double containerW,
    required double containerH,
  }) {
    final n = media.length.clamp(0, 6);
    if (n == 0 || containerW <= 0 || containerH <= 0) return {};

    final out = <String, ScrapbookMediaRect>{};
    const gap = 8.0;

    Size fit(double aspect, double maxW, double maxH) {
      var ar = aspect <= 0 ? 1.0 : aspect;
      final byW = Size(maxW, maxW / ar);
      if (byW.height <= maxH + 0.5) return byW;
      return Size(maxH * ar, maxH);
    }

    void put(int i, double left, double top, double width, double height) {
      final key = scrapbookMediaLayoutKey(media[i]);
      final ar = aspects[i];
      out[key] = ScrapbookMediaRect.fromPixels(
        rect: RectPx(left: left, top: top, width: width, height: height),
        containerW: containerW,
        containerH: containerH,
        aspect: ar > 0 ? ar : null,
      );
    }

    if (n == 1) {
      final size = fit(aspects[0], containerW, containerH);
      put(0, (containerW - size.width) / 2, (containerH - size.height) / 2,
          size.width, size.height);
      return out;
    }

    if (n == 2) {
      final cellW = (containerW - gap) / 2;
      final s0 = fit(aspects[0], cellW, containerH);
      final s1 = fit(aspects[1], cellW, containerH);
      final rowH = s0.height > s1.height ? s0.height : s1.height;
      final top = (containerH - rowH) / 2;
      put(0, 0, top + (rowH - s0.height) / 2, s0.width, s0.height);
      put(1, cellW + gap, top + (rowH - s1.height) / 2, s1.width, s1.height);
      return out;
    }

    if (n == 3 || n == 4) {
      return _collageLayouts(
        media: media.take(n).toList(),
        aspects: aspects.take(n).toList(),
        containerW: containerW,
        containerH: containerH,
        gap: gap,
      );
    }

    final mostlyLandscape =
        aspects.take(n).where((a) => a >= 1.0).length >= (n / 2).ceil();
    final preferredCols =
        (mostlyLandscape && containerW > containerH) ? 3 : 2;
    final cols = n < preferredCols ? n : preferredCols;
    final rows = (n + cols - 1) ~/ cols;
    final rowHeight = (containerH - gap * (rows - 1)) / rows;
    final cellW = (containerW - gap * (cols - 1)) / cols;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        if (i >= n) break;
        final size = fit(aspects[i], cellW, rowHeight);
        final left = c * (cellW + gap) + (cellW - size.width) / 2;
        final top = r * (rowHeight + gap) + (rowHeight - size.height) / 2;
        put(i, left, top, size.width, size.height);
      }
    }
    return out;
  }

  /// Коллаж: высокий слева + стопка справа (+ нижний широкий для 4).
  /// Слоты заполняются с учётом ориентации кадров.
  static Map<String, ScrapbookMediaRect> _collageLayouts({
    required List<Map<String, dynamic>> media,
    required List<double> aspects,
    required double containerW,
    required double containerH,
    required double gap,
  }) {
    final n = media.length;
    final out = <String, ScrapbookMediaRect>{};

    Size fit(double aspect, double maxW, double maxH) {
      final ar = aspect <= 0 ? 1.0 : aspect;
      final byW = Size(maxW, maxW / ar);
      if (byW.height <= maxH + 0.5) return byW;
      return Size(maxH * ar, maxH);
    }

    void put(int i, double left, double top, double width, double height) {
      final ar = aspects[i];
      out[scrapbookMediaLayoutKey(media[i])] = ScrapbookMediaRect.fromPixels(
        rect: RectPx(left: left, top: top, width: width, height: height),
        containerW: containerW,
        containerH: containerH,
        aspect: ar > 0 ? ar : null,
      );
    }

    final portraits = <int>[];
    final landscapes = <int>[];
    for (var i = 0; i < n; i++) {
      if (aspects[i] < 1.0) {
        portraits.add(i);
      } else {
        landscapes.add(i);
      }
    }

    int takeSlot(List<int> prefer, List<int> fallback) {
      if (prefer.isNotEmpty) return prefer.removeAt(0);
      if (fallback.isNotEmpty) return fallback.removeAt(0);
      return 0;
    }

    final leftIdx = takeSlot(portraits, landscapes);
    final topRightIdx = takeSlot(landscapes, portraits);
    final midRightIdx = takeSlot(portraits, landscapes);
    final bottomIdx =
        n == 4 ? takeSlot(landscapes, portraits) : null;

    final leftColW = containerW * 0.42;
    final rightColW = containerW - leftColW - gap;
    final upperBudget = containerH * (n == 4 ? 0.68 : 0.92);

    // Правая стопка задаёт высоту верхнего блока.
    var tr = fit(aspects[topRightIdx], rightColW, upperBudget);
    var mr = fit(
      aspects[midRightIdx],
      rightColW,
      math.max(48.0, upperBudget - tr.height - gap),
    );
    var rightStackH = tr.height + gap + mr.height;
    if (rightStackH > upperBudget && rightStackH > 0) {
      final s = upperBudget / rightStackH;
      tr = Size(tr.width * s, tr.height * s);
      mr = Size(mr.width * s, mr.height * s);
      rightStackH = tr.height + gap + mr.height;
    }

    // Левый портрет той же высоты, что правая стопка.
    final leftSize = fit(aspects[leftIdx], leftColW, rightStackH);

    put(leftIdx, 0, 0, leftSize.width, leftSize.height);
    put(
      topRightIdx,
      leftColW + gap + (rightColW - tr.width) / 2,
      0,
      tr.width,
      tr.height,
    );
    put(
      midRightIdx,
      leftColW + gap + (rightColW - mr.width) / 2,
      tr.height + gap,
      mr.width,
      mr.height,
    );

    if (bottomIdx != null) {
      final upperH = math.max(leftSize.height, rightStackH);
      final bottom = fit(
        aspects[bottomIdx],
        containerW * 0.72,
        math.max(48.0, containerH - upperH - gap),
      );
      put(
        bottomIdx,
        (containerW - bottom.width) / 2,
        upperH + gap,
        bottom.width,
        bottom.height,
      );
    }

    return out;
  }
}
