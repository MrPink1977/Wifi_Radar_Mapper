import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/floorplan.dart';
import '../services/heatmap_service.dart';

/// Widget that renders the interpolated heatmap image on top of the floor plan,
/// properly aligned to real-world coordinates via the [Floorplan] scale.
///
/// [imageSize] is the native pixel size of the floor plan image; required to
/// correctly map real-world metre coordinates to widget pixels when the image
/// is displayed with BoxFit.contain.
class HeatmapOverlay extends StatelessWidget {
  final HeatmapResult result;
  final Floorplan floorplan;
  final Size imageSize;
  final double opacity;

  const HeatmapOverlay({
    super.key,
    required this.result,
    required this.floorplan,
    required this.imageSize,
    this.opacity = 0.65,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
      return CustomPaint(
        size: canvasSize,
        painter: _HeatmapPainter(
          result: result,
          floorplan: floorplan,
          imageSize: imageSize,
          opacity: opacity,
          canvasSize: canvasSize,
        ),
      );
    });
  }
}

class _HeatmapPainter extends CustomPainter {
  final HeatmapResult result;
  final Floorplan floorplan;
  final Size imageSize;
  final double opacity;
  final Size canvasSize;

  _HeatmapPainter({
    required this.result,
    required this.floorplan,
    required this.imageSize,
    required this.opacity,
    required this.canvasSize,
  });

  /// Convert an image-pixel coordinate to a widget-space coordinate,
  /// accounting for BoxFit.contain letterboxing/pillarboxing.
  Offset _imageToWidget(Offset imagePx) {
    final fitted = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
    final scaleX = fitted.destination.width / imageSize.width;
    final scaleY = fitted.destination.height / imageSize.height;
    final offsetX = (canvasSize.width - fitted.destination.width) / 2;
    final offsetY = (canvasSize.height - fitted.destination.height) / 2;
    return Offset(
      offsetX + imagePx.dx * scaleX,
      offsetY + imagePx.dy * scaleY,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Compute the heatmap bounding box in image-pixel space.
    final originImagePx = floorplan.metersToPixels(result.originMeters);
    final endImagePx = floorplan.metersToPixels(
      result.originMeters + Offset(result.sizeMeters.width, result.sizeMeters.height),
    );

    // Convert both corners to widget space.
    final originWidget = _imageToWidget(originImagePx);
    final endWidget = _imageToWidget(endImagePx);

    final src = ui.Rect.fromLTWH(
        0, 0, result.image.width.toDouble(), result.image.height.toDouble());
    final dst = ui.Rect.fromLTRB(
        originWidget.dx, originWidget.dy, endWidget.dx, endWidget.dy);

    final paint = Paint()..color = Colors.white.withOpacity(opacity);
    canvas.drawImageRect(result.image, src, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) =>
      old.result != result ||
      old.opacity != opacity ||
      old.imageSize != imageSize;
}
