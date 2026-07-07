import 'dart:math' as math;

import 'package:flutter/material.dart';

class TreePerson {
  const TreePerson({
    required this.personId,
    required this.userId,
    required this.displayName,
    required this.avatarUrl,
    required this.gender,
  });

  final int personId;
  final int userId;
  final String displayName;
  final String avatarUrl;
  final String gender;

  factory TreePerson.fromJson(Map<String, dynamic> json) {
    final personId = json['person_id'];
    final userId = json['user_id'];
    return TreePerson(
      personId: personId is int ? personId : int.tryParse('$personId') ?? 0,
      userId: userId is int ? userId : int.tryParse('$userId') ?? 0,
      displayName: json['display_name']?.toString() ?? '',
      avatarUrl: json['avatar_url']?.toString() ?? '',
      gender: json['gender']?.toString() ?? '',
    );
  }
}

class TreeEdge {
  const TreeEdge({
    required this.kind,
    required this.fromPersonId,
    required this.toPersonId,
  });

  final String kind;
  final int fromPersonId;
  final int toPersonId;

  factory TreeEdge.fromJson(Map<String, dynamic> json) {
    final fromId = json['from_person_id'];
    final toId = json['to_person_id'];
    return TreeEdge(
      kind: json['kind']?.toString() ?? '',
      fromPersonId: fromId is int ? fromId : int.tryParse('$fromId') ?? 0,
      toPersonId: toId is int ? toId : int.tryParse('$toId') ?? 0,
    );
  }
}

enum _DirectRelation { parent, child, spouse, sibling, other }

class FamilyTreeStats {
  const FamilyTreeStats({
    required this.familyTotal,
    required this.onMap,
    required this.nearby,
    required this.links,
  });

  final int familyTotal;
  final int onMap;
  final int nearby;
  final int links;
}

class FamilyTreeGraph {
  FamilyTreeGraph({
    required this.personsById,
    required this.edges,
    required this.centerPersonId,
  });

  final Map<int, TreePerson> personsById;
  final List<TreeEdge> edges;
  final int centerPersonId;

  factory FamilyTreeGraph.fromPayload(
    Map<String, dynamic> payload, {
    required int centerPersonId,
  }) {
    final persons = (payload['persons'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(TreePerson.fromJson)
        .where((p) => p.personId > 0)
        .toList();
  return FamilyTreeGraph(
      personsById: {for (final p in persons) p.personId: p},
      edges: (payload['edges'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .map(TreeEdge.fromJson)
          .where((e) => e.fromPersonId > 0 && e.toPersonId > 0)
          .toList(),
      centerPersonId: centerPersonId,
    );
  }

  Set<int> neighbors(int personId) {
    final result = <int>{};
    for (final edge in edges) {
      if (edge.kind == 'parent') {
        if (edge.fromPersonId == personId) result.add(edge.toPersonId);
        if (edge.toPersonId == personId) result.add(edge.fromPersonId);
      } else if (edge.kind == 'spouse' || edge.kind == 'sibling') {
        if (edge.fromPersonId == personId) result.add(edge.toPersonId);
        if (edge.toPersonId == personId) result.add(edge.fromPersonId);
      }
    }
    return result;
  }

  Set<int> visiblePersonIds() {
    final ring1 = neighbors(centerPersonId);
    final visible = <int>{centerPersonId, ...ring1};
    for (final personId in ring1) {
      visible.addAll(neighbors(personId));
    }
    return visible.where(personsById.containsKey).toSet();
  }

  List<TreeEdge> visibleEdges(Set<int> visibleIds) {
    return edges.where((edge) {
      return visibleIds.contains(edge.fromPersonId) && visibleIds.contains(edge.toPersonId);
    }).toList();
  }

  FamilyTreeStats stats() {
    final visible = visiblePersonIds();
    final ring1 = neighbors(centerPersonId);
    return FamilyTreeStats(
      familyTotal: personsById.length,
      onMap: visible.length,
      nearby: ring1.length,
      links: visibleEdges(visible).length,
    );
  }

  String relationLabel(int targetPersonId) {
    if (targetPersonId == centerPersonId) return 'Вы';
    final path = _shortestPath(centerPersonId, targetPersonId);
    if (path == null) return 'Родственник';
    return _labelFromPath(path, personsById[targetPersonId]);
  }

  Map<int, Offset> layoutPositions() {
    const center = Offset(420, 420);
    const ring1Radius = 165.0;
    const ring2Radius = 130.0;
    final visible = visiblePersonIds();
    final positions = <int, Offset>{centerPersonId: center};

    final ring1 = neighbors(centerPersonId).where(visible.contains).toList()
      ..sort((a, b) => a.compareTo(b));

    final buckets = <_DirectRelation, List<int>>{
      _DirectRelation.parent: [],
      _DirectRelation.child: [],
      _DirectRelation.spouse: [],
      _DirectRelation.sibling: [],
      _DirectRelation.other: [],
    };
    for (final personId in ring1) {
      buckets[_directRelation(personId)]!.add(personId);
    }

    void placeInArc(List<int> ids, double centerAngleDeg, double spreadDeg) {
      if (ids.isEmpty) return;
      if (ids.length == 1) {
        final angle = centerAngleDeg * math.pi / 180;
        positions[ids.first] = center + Offset(math.cos(angle), math.sin(angle)) * ring1Radius;
        return;
      }
      final start = centerAngleDeg - spreadDeg / 2;
      final step = spreadDeg / (ids.length - 1);
      for (var i = 0; i < ids.length; i++) {
        final angle = (start + step * i) * math.pi / 180;
        positions[ids[i]] = center + Offset(math.cos(angle), math.sin(angle)) * ring1Radius;
      }
    }

    placeInArc(buckets[_DirectRelation.parent]!, -90, 80);
    placeInArc(buckets[_DirectRelation.child]!, 90, 80);
    placeInArc(buckets[_DirectRelation.spouse]!, 0, 40);
    placeInArc(buckets[_DirectRelation.sibling]!, 180, 80);
    placeInArc(buckets[_DirectRelation.other]!, 225, 60);

    final ring2 = visible.where((id) => id != centerPersonId && !ring1.contains(id)).toList()
      ..sort((a, b) => a.compareTo(b));
    for (final personId in ring2) {
      final anchorIds = neighbors(personId).where(positions.containsKey).toList();
      if (anchorIds.isEmpty) {
        final angle = (personId % 360) * math.pi / 180;
        positions[personId] = center + Offset(math.cos(angle), math.sin(angle)) * (ring1Radius + ring2Radius);
        continue;
      }
      anchorIds.sort((a, b) {
        final da = (positions[a]! - center).distanceSquared;
        final db = (positions[b]! - center).distanceSquared;
        return da.compareTo(db);
      });
      final anchorPos = positions[anchorIds.first]!;
      var direction = anchorPos - center;
      if (direction.distance < 1) {
        direction = const Offset(0, -1);
      } else {
        direction = direction / direction.distance;
      }
      positions[personId] = anchorPos + direction * ring2Radius;
    }

    return positions;
  }

  _DirectRelation _directRelation(int neighborId) {
    for (final edge in edges) {
      if (edge.kind == 'parent') {
        if (edge.fromPersonId == neighborId && edge.toPersonId == centerPersonId) {
          return _DirectRelation.parent;
        }
        if (edge.fromPersonId == centerPersonId && edge.toPersonId == neighborId) {
          return _DirectRelation.child;
        }
      }
      if (edge.kind == 'spouse') {
        final linked = (edge.fromPersonId == centerPersonId && edge.toPersonId == neighborId) ||
            (edge.toPersonId == centerPersonId && edge.fromPersonId == neighborId);
        if (linked) return _DirectRelation.spouse;
      }
      if (edge.kind == 'sibling') {
        final linked = (edge.fromPersonId == centerPersonId && edge.toPersonId == neighborId) ||
            (edge.toPersonId == centerPersonId && edge.fromPersonId == neighborId);
        if (linked) return _DirectRelation.sibling;
      }
    }
    return _DirectRelation.other;
  }

  List<String>? _shortestPath(int fromId, int toId) {
    if (fromId == toId) return [];
    final queue = <List<dynamic>>[
      [fromId, <String>[]],
    ];
    final visited = <int>{fromId};

    while (queue.isNotEmpty) {
      final item = queue.removeAt(0);
      final personId = item[0] as int;
      final path = item[1] as List<String>;
      if (personId == toId) return path;
      if (path.length >= 8) continue;
      for (final step in _stepsFrom(personId)) {
        final nextId = step.$1;
        final stepKind = step.$2;
        if (visited.contains(nextId)) continue;
        visited.add(nextId);
        queue.add([nextId, [...path, stepKind]]);
      }
    }
    return null;
  }

  Iterable<(int, String)> _stepsFrom(int personId) sync* {
    for (final edge in edges) {
      if (edge.kind == 'parent') {
        if (edge.fromPersonId == personId) yield (edge.toPersonId, 'child');
        if (edge.toPersonId == personId) yield (edge.fromPersonId, 'parent');
      } else if (edge.kind == 'spouse') {
        if (edge.fromPersonId == personId) yield (edge.toPersonId, 'spouse');
        if (edge.toPersonId == personId) yield (edge.fromPersonId, 'spouse');
      } else if (edge.kind == 'sibling') {
        if (edge.fromPersonId == personId) yield (edge.toPersonId, 'sibling');
        if (edge.toPersonId == personId) yield (edge.fromPersonId, 'sibling');
      }
    }
  }

  String _labelFromPath(List<String> path, TreePerson? target) {
    final g = target?.gender ?? '';
    if (path.isEmpty) return 'Вы';
    if (path.length == 1) {
      return switch (path.first) {
        'spouse' => g == 'male'
            ? 'Муж'
            : g == 'female'
                ? 'Жена'
                : 'Супруг(а)',
        'parent' => g == 'male'
            ? 'Отец'
            : g == 'female'
                ? 'Мать'
                : 'Родитель',
        'child' => g == 'male'
            ? 'Сын'
            : g == 'female'
                ? 'Дочь'
                : 'Ребёнок',
        'sibling' => g == 'male'
            ? 'Брат'
            : g == 'female'
                ? 'Сестра'
                : 'Брат/сестра',
        _ => 'Родственник',
      };
    }
    if (path.length == 2 && path.every((s) => s == 'parent')) {
      return g == 'male' ? 'Дедушка' : g == 'female' ? 'Бабушка' : 'Дед/бабушка';
    }
    if (path.length == 2 && path.every((s) => s == 'child')) {
      return g == 'male' ? 'Внук' : g == 'female' ? 'Внучка' : 'Внук/внучка';
    }
    if (path.contains('spouse')) return 'Свойственник';
    if (path.contains('sibling')) return 'Брат/сестра';
    return 'Родственник';
  }
}

class FamilyTreeEdgePainter extends CustomPainter {
  FamilyTreeEdgePainter({
    required this.edges,
    required this.positions,
    required this.nodeRadius,
    required this.color,
  });

  final List<TreeEdge> edges;
  final Map<int, Offset> positions;
  final double nodeRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final edge in edges) {
      final from = positions[edge.fromPersonId];
      final to = positions[edge.toPersonId];
      if (from == null || to == null) continue;
      canvas.drawLine(from, to, paint);
    }
  }

  @override
  bool shouldRepaint(covariant FamilyTreeEdgePainter oldDelegate) {
    return oldDelegate.edges != edges ||
        oldDelegate.positions != positions ||
        oldDelegate.color != color;
  }
}
