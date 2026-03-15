import 'dart:math';
import 'dart:ui';

import '../models/recommendation.dart';
import '../models/sample_point.dart';
import '../utils/constants.dart';

/// Analyses a completed scan session to produce placement [Recommendation]s.
class RecommendationService {
  /// Generate recommendations from a set of committed sample points.
  List<Recommendation> analyse(List<SamplePoint> points) {
    if (points.isEmpty) return [];

    final results = <Recommendation>[];

    // 1. Top 3 placement candidates (numbered pins on the heatmap).
    results.addAll(_findPlacementCandidates(points));

    // 2. Dead zones: areas with persistently poor signal.
    results.addAll(_findDeadZones(points));

    return results;
  }

  // ── Placement candidates ─────────────────────────────────────────────────

  /// Identify the top 3 candidate locations for mesh extender or IoT hub
  /// placement. Candidates are scored as a percentage of the best recorded
  /// signal in the session so the number has a clear, intuitive meaning.
  List<Recommendation> _findPlacementCandidates(List<SamplePoint> points) {
    if (points.length < 2) return [];

    // Best (highest) RSSI seen in the entire scan — this is the router core.
    final bestRssi = points.map((p) => p.rssiDbm).reduce(max);

    // Score each point relative to the best recorded signal.
    final centroid = _centroid(points);

    final scored = points.map((p) {
      // How strong is this location relative to the best point? (0–1)
      final signalRatio = normaliseRssi(p.rssiDbm) /
          (normaliseRssi(bestRssi).clamp(0.01, 1.0));

      // Prefer locations that have stable signal (low variance).
      final stabilityBonus = 1.0 / (1.0 + p.variance * 0.05);

      // Slightly favour points that are away from the router core so the
      // recommendation extends coverage rather than clustering near the source.
      final distFromBest = _distanceTo(p, _findPointNearest(points, bestRssi));
      final spreadBonus = (distFromBest / 10.0).clamp(0.0, 0.3);

      return _ScoredPoint(
        point: p,
        score: (signalRatio.clamp(0.0, 1.0) * 0.7 +
                stabilityBonus * 0.2 +
                spreadBonus * 0.1),
        signalPct: (signalRatio * 100).round().clamp(0, 100),
        rssi: p.rssiDbm,
        bestRssi: bestRssi,
      );
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    // Pick top 3 while ensuring minimum spacing so pins don't cluster.
    final candidates = _selectSpaced(scored, maxCount: 3, minSpacingMeters: 2.0);

    return candidates.asMap().entries.map((entry) {
      final rank = entry.key + 1;
      final c = entry.value;
      final direction = _compassDirection(Offset(c.point.x, c.point.y), centroid);
      final tier = tierForRssi(c.rssi);

      String header;
      switch (rank) {
        case 1:
          header = 'Option 1 — Best Placement';
          break;
        case 2:
          header = 'Option 2 — Second Choice';
          break;
        default:
          header = 'Option 3 — Third Choice';
      }

      final description =
          'Signal strength: ${c.signalPct}% of router baseline '
          '(${c.rssi.toStringAsFixed(0)} dBm — ${tier.label}). '
          '${_placementRationale(rank, direction, c.signalPct)}';

      return Recommendation(
        type: RecommendationType.bestMeshExtender,
        position: Offset(c.point.x, c.point.y),
        score: c.signalPct / 100.0,
        title: header,
        description: description,
        rank: rank,
      );
    }).toList();
  }

  String _placementRationale(int rank, String direction, int pct) {
    if (pct >= 80) {
      return 'Strong, stable signal in the $direction area. '
          'Ideal for a mesh node, ESP32 hub, or IoT gateway.';
    } else if (pct >= 60) {
      return 'Good coverage in the $direction area. '
          'Placing a mesh node here extends reliable signal further into weak zones.';
    } else {
      return 'Moderate signal in the $direction area. '
          'A mesh node here will improve coverage in surrounding dead zones.';
    }
  }

  // ── Dead zones ────────────────────────────────────────────────────────────

  List<Recommendation> _findDeadZones(List<SamplePoint> points) {
    final deadPoints = points.where((p) => p.rssiDbm < -80).toList();
    if (deadPoints.isEmpty) return [];

    final bestRssi = points.map((p) => p.rssiDbm).reduce(max);
    final clusters = _cluster(deadPoints, clusterRadius: 2.5);

    return clusters.map((cluster) {
      final cx = cluster.map((p) => p.x).reduce((a, b) => a + b) / cluster.length;
      final cy = cluster.map((p) => p.y).reduce((a, b) => a + b) / cluster.length;
      final meanRssi =
          cluster.map((p) => p.rssiDbm).reduce((a, b) => a + b) / cluster.length;
      final centroid = _centroid(points);
      final direction = _compassDirection(Offset(cx, cy), centroid);
      final pct =
          ((normaliseRssi(meanRssi) / normaliseRssi(bestRssi).clamp(0.01, 1.0)) * 100)
              .round()
              .clamp(0, 100);

      return Recommendation(
        type: RecommendationType.deadZone,
        position: Offset(cx, cy),
        score: 1.0 - normaliseRssi(meanRssi),
        title: 'Dead Zone — $direction area',
        description:
            'Signal here is only $pct% of router baseline '
            '(${meanRssi.toStringAsFixed(0)} dBm). '
            'Connection is likely unstable or failing. '
            'Add a mesh node nearby to extend coverage.',
      );
    }).toList();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Offset _centroid(List<SamplePoint> points) {
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / points.length;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / points.length;
    return Offset(cx, cy);
  }

  SamplePoint _findPointNearest(List<SamplePoint> points, double targetRssi) {
    return points.reduce((a, b) =>
        (a.rssiDbm - targetRssi).abs() < (b.rssiDbm - targetRssi).abs() ? a : b);
  }

  double _distanceTo(SamplePoint a, SamplePoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
  }

  /// Cardinal/intercardinal compass direction of [pos] relative to [origin].
  String _compassDirection(Offset pos, Offset origin) {
    final dx = pos.dx - origin.dx;
    final dy = pos.dy - origin.dy; // positive Y = south in screen coords

    final angle = atan2(dy, dx) * 180 / pi; // -180 to 180

    // Normalise to 0–360 from north (screen Y-up convention)
    final bearing = (angle + 450) % 360;

    if (bearing < 22.5 || bearing >= 337.5) return 'north';
    if (bearing < 67.5) return 'northeast';
    if (bearing < 112.5) return 'east';
    if (bearing < 157.5) return 'southeast';
    if (bearing < 202.5) return 'south';
    if (bearing < 247.5) return 'southwest';
    if (bearing < 292.5) return 'west';
    return 'northwest';
  }

  /// Select up to [maxCount] candidates ensuring minimum spacing between them.
  List<_ScoredPoint> _selectSpaced(
    List<_ScoredPoint> sorted, {
    required int maxCount,
    required double minSpacingMeters,
  }) {
    final selected = <_ScoredPoint>[];
    for (final candidate in sorted) {
      if (selected.length >= maxCount) break;
      final tooClose = selected.any((s) {
        final dx = s.point.x - candidate.point.x;
        final dy = s.point.y - candidate.point.y;
        return sqrt(dx * dx + dy * dy) < minSpacingMeters;
      });
      if (!tooClose) selected.add(candidate);
    }
    return selected;
  }

  /// Simple greedy clustering by distance radius.
  List<List<SamplePoint>> _cluster(
      List<SamplePoint> points, {required double clusterRadius}) {
    final remaining = [...points];
    final clusters = <List<SamplePoint>>[];

    while (remaining.isNotEmpty) {
      final seed = remaining.removeAt(0);
      final cluster = [seed];

      remaining.removeWhere((p) {
        final dist = sqrt(
            (p.x - seed.x) * (p.x - seed.x) + (p.y - seed.y) * (p.y - seed.y));
        if (dist <= clusterRadius) {
          cluster.add(p);
          return true;
        }
        return false;
      });

      clusters.add(cluster);
    }
    return clusters;
  }
}

class _ScoredPoint {
  final SamplePoint point;
  final double score;
  final int signalPct;
  final double rssi;
  final double bestRssi;

  const _ScoredPoint({
    required this.point,
    required this.score,
    required this.signalPct,
    required this.rssi,
    required this.bestRssi,
  });
}
