import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../models/sample_point.dart';
import '../utils/constants.dart';
import '../utils/interpolation.dart';

/// The rendered heatmap as an [ui.Image] plus metadata.
class HeatmapResult {
  final ui.Image image;
  final Offset originMeters;
  final Size sizeMeters;
  final int rows;
  final int cols;

  const HeatmapResult({
    required this.image,
    required this.originMeters,
    required this.sizeMeters,
    required this.rows,
    required this.cols,
  });
}

/// Builds a raster heatmap image from a list of [SamplePoint]s using IDW
/// interpolation. Renders directly to an [ui.Image] for efficient overlay
/// on the floor plan canvas.
class HeatmapService extends ChangeNotifier {
  HeatmapResult? _currentResult;
  HeatmapResult? get currentResult => _currentResult;

  bool _isProcessing = false;
  bool get isProcessing => _isProcessing;

  /// Rebuild the heatmap from [points]. Runs interpolation on a background
  /// isolate to keep the UI responsive.
  Future<void> rebuild({
    required List<SamplePoint> points,
    required Offset originMeters,
    required Size sizeMeters,
    double resolution = 3.0,
    double influenceRadius = kDefaultInfluenceRadiusMeters,
  }) async {
    if (_isProcessing) return;
    _isProcessing = true;
    notifyListeners();

    try {
      final interpolator = HeatmapInterpolator(
        points: points,
        influenceRadius: influenceRadius,
      );

      final grid = await compute(_buildGrid, _GridParams(
        points: points,
        originMeters: originMeters,
        sizeMeters: sizeMeters,
        resolution: resolution,
        influenceRadius: influenceRadius,
      ));

      final image = await _renderToImage(grid, originMeters, sizeMeters, resolution);
      _currentResult = HeatmapResult(
        image: image,
        originMeters: originMeters,
        sizeMeters: sizeMeters,
        rows: grid.length,
        cols: grid.isNotEmpty ? grid.first.length : 0,
      );
    } catch (e) {
      debugPrint('[HeatmapService] rebuild error: $e');
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<ui.Image> _renderToImage(
    List<List<InterpolatedCell?>> grid,
    Offset originMeters,
    Size sizeMeters,
    double resolution,
  ) async {
    final rows = grid.length;
    final cols = grid.isNotEmpty ? grid.first.length : 0;

    if (rows == 0 || cols == 0) {
      // Return a 1x1 transparent image as a fallback.
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder);
      return recorder.endRecording().toImage(1, 1);
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    const cellPx = 4.0; // pixels per grid cell in the heatmap texture

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final cell = grid[row][col];
        if (cell == null) continue;

        final color = _colorForRssi(cell.rssiDbm, cell.confidence);
        final paint = ui.Paint()..color = color;

        canvas.drawRect(
          ui.Rect.fromLTWH(col * cellPx, row * cellPx, cellPx, cellPx),
          paint,
        );
      }
    }

    return recorder
        .endRecording()
        .toImage((cols * cellPx).toInt(), (rows * cellPx).toInt());
  }

  ui.Color _colorForRssi(double dbm, double confidence) {
    final normalised = normaliseRssi(dbm);

    // Map 0→1 to red→yellow→green using HSL hue (0°=red, 120°=green).
    final hue = normalised * 120.0;
    final alpha = (200 * confidence).round().clamp(0, 255);

    return ui.HSLColor.fromAHSL(alpha / 255.0, hue, 0.9, 0.5).toColor();
  }

  @override
  void dispose() {
    _currentResult?.image.dispose();
    super.dispose();
  }
}

// ── Background compute helpers ────────────────────────────────────────────────

class _GridParams {
  final List<SamplePoint> points;
  final Offset originMeters;
  final Size sizeMeters;
  final double resolution;
  final double influenceRadius;

  const _GridParams({
    required this.points,
    required this.originMeters,
    required this.sizeMeters,
    required this.resolution,
    required this.influenceRadius,
  });
}

List<List<InterpolatedCell?>> _buildGrid(_GridParams params) {
  final interpolator = HeatmapInterpolator(
    points: params.points,
    influenceRadius: params.influenceRadius,
  );
  return interpolator.buildGrid(
    originMeters: params.originMeters,
    sizeMeters: params.sizeMeters,
    resolution: params.resolution,
  );
}
