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

    // 1. Find the best IoT gateway zone: strong mean RSSI, low variance,
    //    reasonably central position.
    final gatewayCandidate = _findBestGatewayZone(points);
    if (gatewayCandidate != null) results.add(gatewayCandidate);

    // 2. Find the best mesh extender location: balanced mid-point between
    //    strong and weak regions.
    final meshCandidate = _findMeshExtenderZone(points);
    if (meshCandidate != null) results.add(meshCandidate);

    // 3. Identify dead zones: repeated low RSSI across multiple points.
    results.addAll(_findDeadZones(points));

    return results;
  }

  Recommendation? _findBestGatewayZone(List<SamplePoint> points) {
    // Score each point: higher is better. Blend normalised RSSI with inverse
    // variance (reliability) and centrality.
    final centroid = _centroid(points);
    final maxDist = _maxDistFromCentroid(points, centroid);

    SamplePoint? best;
    double bestScore = -999;

    for (final p in points) {
      final rssiScore = normaliseRssi(p.rssiDbm); // 0–1, higher = better
      final reliabilityScore =
          (1.0 / (1.0 + p.variance)).clamp(0.0, 1.0); // low variance = 1
      final distFromCentroid =
          (Offset(p.x, p.y) - centroid).distance;
      final centralityScore =
          maxDist > 0 ? (1.0 - distFromCentroid / maxDist) : 1.0;

      final score =
          rssiScore * 0.6 + reliabilityScore * 0.3 + centralityScore * 0.1;

      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }

    if (best == null || bestScore < 0.5) return null;

    return Recommendation(
      type: RecommendationType.bestGateway,
      position: Offset(best.x, best.y),
      score: bestScore,
      title: 'Best Gateway / Router Location',
      description:
          'Recommended for ESP32, hub, or bridge placement. '
          'Signal: ${best.rssiDbm.toStringAsFixed(0)} dBm '
          '(${tierForRssi(best.rssiDbm).label})',
    );
  }

  Recommendation? _findMeshExtenderZone(List<SamplePoint> points) {
    // Find the mid-point between the strongest and weakest zones.
    final sorted = [...points]..sort((a, b) => a.rssiDbm.compareTo(b.rssiDbm));
    final strong = sorted.last;
    final weak = sorted.first;

    if (strong.rssiDbm < -65) return null; // no strong zone to extend from

    final midX = (strong.x + weak.x) / 2;
    final midY = (strong.y + weak.y) / 2;
    final score = (normaliseRssi(strong.rssiDbm) + (1.0 - normaliseRssi(weak.rssiDbm))) / 2;

    return Recommendation(
      type: RecommendationType.bestMeshExtender,
      position: Offset(midX, midY),
      score: score,
      title: 'Best Mesh Extender Location',
      description:
          'Placing a mesh node here bridges the strong zone near '
          '(${strong.x.toStringAsFixed(1)}m, ${strong.y.toStringAsFixed(1)}m) '
          'with the weaker area around '
          '(${weak.x.toStringAsFixed(1)}m, ${weak.y.toStringAsFixed(1)}m).',
    );
  }

  List<Recommendation> _findDeadZones(List<SamplePoint> points) {
    // Cluster contiguous weak points (below -80 dBm) and flag each cluster.
    final deadPoints = points.where((p) => p.rssiDbm < -80).toList();
    if (deadPoints.isEmpty) return [];

    final clusters = _cluster(deadPoints, clusterRadius: 2.5);
    return clusters.map((cluster) {
      final cx = cluster.map((p) => p.x).reduce((a, b) => a + b) / cluster.length;
      final cy = cluster.map((p) => p.y).reduce((a, b) => a + b) / cluster.length;
      final meanRssi = cluster.map((p) => p.rssiDbm).reduce((a, b) => a + b) /
          cluster.length;
      return Recommendation(
        type: RecommendationType.deadZone,
        position: Offset(cx, cy),
        score: 1.0 - normaliseRssi(meanRssi),
        title: 'Dead Zone Detected',
        description:
            'Average signal: ${meanRssi.toStringAsFixed(0)} dBm. '
            'Connection likely unstable. Consider adding a mesh node '
            'or relocating nearby devices.',
      );
    }).toList();
  }

  Offset _centroid(List<SamplePoint> points) {
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / points.length;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / points.length;
    return Offset(cx, cy);
  }

  double _maxDistFromCentroid(List<SamplePoint> points, Offset centroid) {
    double max = 0;
    for (final p in points) {
      final d = (Offset(p.x, p.y) - centroid).distance;
      if (d > max) max = d;
    }
    return max;
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
