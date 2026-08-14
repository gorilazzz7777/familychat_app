import 'dart:math' as math;
import 'dart:math' show Point;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// CRS тайлов Яндекса (эллиптический Меркатор).
///
/// Без него маркеры на `core-renderer-tiles` уезжают на север
/// (GPS в WGS84 + тайлы EPSG:3395 на дефолтном EPSG:3857).
@immutable
class Epsg3395 extends Crs {
  static const double _scale = 0.5 / (math.pi * _EllipticalMercator.r);

  const Epsg3395()
      : super(
          code: 'EPSG:3395',
          infinite: false,
          wrapLng: (-180, 180),
        );

  @override
  Projection get projection => const _EllipticalMercator();

  @override
  (double, double) transform(double x, double y, double scale) => (
        scale * (_scale * x + 0.5),
        scale * (-_scale * y + 0.5),
      );

  @override
  (double, double) untransform(double x, double y, double scale) => (
        (x / scale - 0.5) / _scale,
        (y / scale - 0.5) / -_scale,
      );

  @override
  (double, double) latLngToXY(LatLng latlng, double scale) {
    final (x, y) = projection.projectXY(latlng);
    return transform(x, y, scale);
  }

  @override
  LatLng pointToLatLng(Point point, double zoom) {
    final (x, y) = untransform(
      point.x.toDouble(),
      point.y.toDouble(),
      scale(zoom),
    );
    return projection.unprojectXY(x, y);
  }

  @override
  Bounds<double>? getProjectedBounds(double zoom) {
    final b = projection.bounds!;
    final s = scale(zoom);
    final (minx, miny) = transform(b.min.x, b.min.y, s);
    final (maxx, maxy) = transform(b.max.x, b.max.y, s);
    return Bounds<double>(
      Point<double>(minx, miny),
      Point<double>(maxx, maxy),
    );
  }
}

@immutable
class _EllipticalMercator extends Projection {
  static const double r = 6378137;
  static const double rMinor = 6356752.314245179;

  static const Bounds<double> _bounds = Bounds<double>.unsafe(
    Point<double>(-20037508.34279, -15496570.73972),
    Point<double>(20037508.34279, 18764656.23138),
  );

  const _EllipticalMercator() : super(_bounds);

  @override
  (double, double) projectXY(LatLng latlng) {
    final d = math.pi / 180;
    var y = latlng.latitude * d;
    final tmp = rMinor / r;
    final e = math.sqrt(1 - tmp * tmp);
    final con = e * math.sin(y);

    final ts = math.tan(math.pi / 4 - y / 2) /
        math.pow((1 - con) / (1 + con), e / 2);
    y = -r * math.log(math.max(ts, 1E-10));

    return (latlng.longitude * d * r, y);
  }

  @override
  LatLng unprojectXY(double x, double y) {
    final d = 180 / math.pi;
    final tmp = rMinor / r;
    final e = math.sqrt(1 - tmp * tmp);
    final ts = math.exp(-y / r);
    var phi = math.pi / 2 - 2 * math.atan(ts);

    for (var i = 0, dphi = 0.1; i < 15 && dphi.abs() > 1e-7; i++) {
      final con = e * math.sin(phi);
      final conPow = math.pow((1 - con) / (1 + con), e / 2);
      dphi = math.pi / 2 - 2 * math.atan(ts * conPow) - phi;
      phi += dphi;
    }

    return LatLng(phi * d, x * d / r);
  }
}
