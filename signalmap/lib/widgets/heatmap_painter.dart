import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/floorplan.dart';
import '../services/heatmap_service.dart';

/// Widget that renders the interpolated heatmap image on top of the floor plan,
/// properly aligned to real-world coordinates via the [Floorplan] scale.
class HeatmapOverlay extends StatelessWidget {
  final HeatmapResult result;
  final Floorplan floorplan;
  final double opacity;

  const HeatmapOverlay({
    super.key,
    required this.result,
    required this.floorplan,
    this.opacity = 0.65,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      return CustomPaint(
        size: Size(constraints.maxWidth, constraints.maxHeight),
        painter: _HeatmapPainter(
          result: result,
          floorplan: floorplan,
          opacity: opacity,
          canvasSize: Size(constraints.maxWidth, constraints.maxHeight),
        ),
      );
    });
  }
}

class _HeatmapPainter extends CustomPainter {
  final HeatmapResult result;
  final Floorplan floorplan;
  final double opacity;
  final Size canvasSize;

  _HeatmapPainter({
    required this.result,
    required this.floorplan,
    required this.opacity,
    required this.canvasSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Map the heatmap origin (real-world metres) to canvas pixels.
    final originPx = floorplan.metersToPixels(result.originMeters);

    // Size of the heatmap in canvas pixels.
    final widthPx = result.sizeMeters.width * floorplan.scalePixelsPerMeter;
    final heightPx = result.sizeMeters.height * floorplan.scalePixelsPerMeter;

    final src = Rect.fromLTWH(
        0, 0, result.image.width.toDouble(), result.image.height.toDouble());
    final dst = Rect.fromLTWH(originPx.dx, originPx.dy, widthPx, heightPx);

    final paint = Paint()..color = Colors.white.withOpacity(opacity);
    canvas.drawImageRect(result.image, src, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) =>
      old.result != result || old.opacity != opacity;
}
