import 'dart:math';
import 'dart:ui';

import '../models/sample_point.dart';
import 'constants.dart';

/// Result of interpolating a single grid cell.
class InterpolatedCell {
  final double rssiDbm;
  final double confidence; // 0.0–1.0

  const InterpolatedCell({required this.rssiDbm, required this.confidence});
}

/// Inverse-distance weighting interpolation over a list of [SamplePoint]s.
///
/// For each cell in the output grid, calculates a weighted average of nearby
/// sample points. Points farther than [influenceRadius] metres are ignored.
/// Confidence drops when sample density is low.
class HeatmapInterpolator {
  final List<SamplePoint> points;
  final double influenceRadius;

  const HeatmapInterpolator({
    required this.points,
    this.influenceRadius = kDefaultInfluenceRadiusMeters,
  });

  /// Interpolate at a single real-world position (metres).
  InterpolatedCell? interpolate(Offset position) {
    if (points.isEmpty) return null;

    double weightedSum = 0.0;
    double totalWeight = 0.0;
    int nearCount = 0;

    for (final p in points) {
      final dx = position.dx - p.x;
      final dy = position.dy - p.y;
      final dist = sqrt(dx * dx + dy * dy);

      if (dist > influenceRadius) continue;

      nearCount++;

      // IDW with power = 2; add small epsilon to avoid div-by-zero at exact hits.
      final weight = 1.0 / (dist * dist + 0.0001);
      weightedSum += p.rssiDbm * weight;
      totalWeight += weight;
    }

    if (totalWeight == 0) return null;

    final rssi = weightedSum / totalWeight;
    final confidence =
        (nearCount / kMinSampleDensityForFullConfidence).clamp(0.0, 1.0);

    return InterpolatedCell(rssiDbm: rssi, confidence: confidence);
  }

  /// Build a 2-D grid of interpolated values.
  ///
  /// [originMeters] and [sizeMeters] define the bounding box in real-world
  /// coordinates. [resolution] is the number of cells per metre.
  List<List<InterpolatedCell?>> buildGrid({
    required Offset originMeters,
    required Size sizeMeters,
    double resolution = 2.0, // cells per metre
  }) {
    final cols = (sizeMeters.width * resolution).ceil();
    final rows = (sizeMeters.height * resolution).ceil();

    return List.generate(rows, (row) {
      return List.generate(cols, (col) {
        final x = originMeters.dx + col / resolution;
        final y = originMeters.dy + row / resolution;
        return interpolate(Offset(x, y));
      });
    });
  }
}
