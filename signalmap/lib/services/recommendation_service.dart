import 'dart:math';
import 'dart:ui';

import '../models/recommendation.dart';
import '../models/sample_point.dart';
import '../utils/constants.dart';

/// Analyses a completed scan session to produce placement [Recommendation]s.
class RecommendationService {
  /// Generate recommendations from a set of committed sample points.
  ///
  /// [routerPosition] is the real-world metres position of the router anchor,
  /// used for relative location descriptions. If null, the strongest-signal
  /// point is used as a proxy.
  List<Recommendation> analyse(
    List<SamplePoint> points, {
    Offset? routerPosition,
  }) {
    if (points.isEmpty) return [];

    final results = <Recommendation>[];
    results.addAll(_findPlacementCandidates(points, routerPosition));
    results.addAll(_findDeadZones(points, routerPosition));
    return results;
  }

  // ── Placement candidates ─────────────────────────────────────────────────

  List<Recommendation> _findPlacementCandidates(
      List<SamplePoint> points, Offset? routerPosition) {
    if (points.length < 2) return [];

    final bestRssi = points.map((p) => p.rssiDbm).reduce(max);
    final routerRef = routerPosition ??
        Offset(_findPointNearest(points, bestRssi).x,
            _findPointNearest(points, bestRssi).y);

    final scored = points.map((p) {
      final signalRatio = normaliseRssi(p.rssiDbm) /
          (normaliseRssi(bestRssi).clamp(0.01, 1.0));
      final stabilityBonus = 1.0 / (1.0 + p.variance * 0.05);
      final distFromRouter = _distFromOffset(p, routerRef);
      // Moderate spread bonus: favour points away from router (extending range)
      // but not too far (still usable signal).
      final spreadBonus = (distFromRouter / 12.0).clamp(0.0, 0.25);

      return _ScoredPoint(
        point: p,
        score: signalRatio.clamp(0.0, 1.0) * 0.65 +
            stabilityBonus * 0.25 +
            spreadBonus * 0.10,
        signalPct: (signalRatio * 100).round().clamp(0, 100),
        rssi: p.rssiDbm,
        bestRssi: bestRssi,
      );
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    // ── Option 1: Absolute best scoring location ──────────────────────────
    final opt1 = scored.first;

    // ── Option 2: Best location that is genuinely spatially different ─────
    // Must be at least 3 m from Option 1 and have a distinct signal level.
    _ScoredPoint? opt2;
    for (final candidate in scored.skip(1)) {
      final d = _dist(candidate.point, opt1.point);
      if (d >= 3.0) {
        opt2 = candidate;
        break;
      }
    }

    // ── Option 3: Best in the weakest zone ────────────────────────────────
    // Find the weakest-signal area: points below the lower-quartile RSSI.
    // A mesh node here bridges toward dead zones.
    _ScoredPoint? opt3;
    final sortedByRssi = [...scored]
      ..sort((a, b) => a.rssi.compareTo(b.rssi));
    final lowerQuartileIdx = sortedByRssi.length ~/ 4;
    final weakThreshold = sortedByRssi.isNotEmpty
        ? sortedByRssi[lowerQuartileIdx].rssi
        : double.negativeInfinity;

    for (final candidate in scored) {
      if (candidate.rssi > weakThreshold) continue;
      final d1 = _dist(candidate.point, opt1.point);
      if (d1 < 2.0) continue;
      if (opt2 != null && _dist(candidate.point, opt2.point) < 2.0) continue;
      opt3 = candidate;
      break;
    }

    // Build candidates list — only include genuinely distinct options.
    final rankedCandidates = <({int rank, _ScoredPoint sp})>[
      (rank: 1, sp: opt1),
      if (opt2 != null) (rank: 2, sp: opt2),
      if (opt3 != null) (rank: 3, sp: opt3),
    ];

    return rankedCandidates.map((entry) {
      final rank = entry.rank;
      final c = entry.sp;
      final location =
          _relativeLocation(Offset(c.point.x, c.point.y), routerRef, points);
      final tier = tierForRssi(c.rssi);

      final String header;
      switch (rank) {
        case 1:
          header = 'Option 1 — Best Placement';
          break;
        case 2:
          header = 'Option 2 — Second Choice';
          break;
        default:
          header = 'Option 3 — Weakest Zone Bridge';
      }

      final description =
          'Signal strength: ${c.signalPct}% of router baseline '
          '(${c.rssi.toStringAsFixed(0)} dBm — ${tier.label}). '
          '${_placementRationale(rank, location, c.signalPct)}';

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

  /// Describe [pos] relative to the router/scan area — no compass directions.
  String _relativeLocation(
      Offset pos, Offset routerRef, List<SamplePoint> allPoints) {
    final dx = pos.dx - routerRef.dx;
    final dy = pos.dy - routerRef.dy;
    final dist = sqrt(dx * dx + dy * dy);

    if (dist < 1.5) return 'close to your router';
    if (dist < 3.0) return 'approximately ${dist.toStringAsFixed(1)} m from your router';
    if (dist < 6.0) return 'about ${dist.toStringAsFixed(0)} metres from your router';
    return 'approximately ${dist.toStringAsFixed(0)} metres from your router';
  }

  String _placementRationale(int rank, String locationDesc, int pct) {
    switch (rank) {
      case 1:
        if (pct >= 80) {
          return 'Strongest, most stable zone — $locationDesc. '
              'Ideal for a mesh node, ESP32 hub, or IoT gateway.';
        }
        return 'Best signal zone recorded — $locationDesc. '
            'Good placement for a mesh extender.';
      case 2:
        return 'A different zone to Option 1, $locationDesc. '
            'A mesh node here extends coverage to a distinct part of your space.';
      default:
        return 'The best signal available in a weaker area of your space — '
            '$locationDesc. A mesh node here would most improve '
            'coverage in surrounding dead zones.';
    }
  }

  // ── Dead zones ────────────────────────────────────────────────────────────

  List<Recommendation> _findDeadZones(
      List<SamplePoint> points, Offset? routerPosition) {
    final deadPoints = points.where((p) => p.rssiDbm < -80).toList();
    if (deadPoints.isEmpty) return [];

    final bestRssi = points.map((p) => p.rssiDbm).reduce(max);
    final routerRef = routerPosition ??
        Offset(_findPointNearest(points, bestRssi).x,
            _findPointNearest(points, bestRssi).y);
    final clusters = _cluster(deadPoints, clusterRadius: 2.5);

    return clusters.map((cluster) {
      final cx = cluster.map((p) => p.x).reduce((a, b) => a + b) / cluster.length;
      final cy = cluster.map((p) => p.y).reduce((a, b) => a + b) / cluster.length;
      final meanRssi =
          cluster.map((p) => p.rssiDbm).reduce((a, b) => a + b) / cluster.length;
      final location =
          _relativeLocation(Offset(cx, cy), routerRef, points);
      final pct =
          ((normaliseRssi(meanRssi) / normaliseRssi(bestRssi).clamp(0.01, 1.0)) * 100)
              .round()
              .clamp(0, 100);

      return Recommendation(
        type: RecommendationType.deadZone,
        position: Offset(cx, cy),
        score: 1.0 - normaliseRssi(meanRssi),
        title: 'Weak Zone Detected',
        description:
            'Signal here is only $pct% of router baseline '
            '(${meanRssi.toStringAsFixed(0)} dBm). '
            'This area is $location — connection is likely unstable. '
            'A mesh node nearby would extend coverage here.',
      );
    }).toList();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  SamplePoint _findPointNearest(List<SamplePoint> points, double targetRssi) {
    return points.reduce((a, b) =>
        (a.rssiDbm - targetRssi).abs() < (b.rssiDbm - targetRssi).abs() ? a : b);
  }

  double _dist(SamplePoint a, SamplePoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
  }

  double _distFromOffset(SamplePoint p, Offset o) {
    final dx = p.x - o.dx;
    final dy = p.y - o.dy;
    return sqrt(dx * dx + dy * dy);
  }

  List<List<SamplePoint>> _cluster(
      List<SamplePoint> points, {required double clusterRadius}) {
    final remaining = [...points];
    final clusters = <List<SamplePoint>>[];

    while (remaining.isNotEmpty) {
      final seed = remaining.removeAt(0);
      final cluster = [seed];

      remaining.removeWhere((p) {
        final d = sqrt(
            (p.x - seed.x) * (p.x - seed.x) + (p.y - seed.y) * (p.y - seed.y));
        if (d <= clusterRadius) {
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
