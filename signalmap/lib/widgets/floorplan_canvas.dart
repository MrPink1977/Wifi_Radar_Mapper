import 'dart:io';

import 'package:flutter/material.dart';

/// A positioned marker drawn on top of the floor plan.
class CanvasMarker {
  final Offset position; // in floor plan image pixels (before scaling)
  final Color color;
  final String label;
  final double radius;
  final bool isPulse; // animated pulse for the current position dot

  const CanvasMarker({
    required this.position,
    required this.color,
    this.label = '',
    this.radius = 10,
    this.isPulse = false,
  });
}

/// An optional widget rendered on top of the floor plan image (e.g. heatmap).
abstract class CanvasOverlay extends Widget {
  /// Paint the overlay onto [canvas] given the current image [rect].
  void paint(Canvas canvas, Rect imageRect);
}

/// Interactive floor plan canvas with pinch-to-zoom, pan, marker overlay,
/// and tap-to-place support.
class FloorplanCanvas extends StatefulWidget {
  final String imagePath;
  final List<CanvasMarker> markers;
  final Widget? overlay; // rendered below markers, above image
  final void Function(Offset pixelPosition)? onTap;

  const FloorplanCanvas({
    super.key,
    required this.imagePath,
    this.markers = const [],
    this.overlay,
    this.onTap,
  });

  @override
  State<FloorplanCanvas> createState() => _FloorplanCanvasState();
}

class _FloorplanCanvasState extends State<FloorplanCanvas>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformController =
      TransformationController();

  // Pulse animation for the position dot.
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim =
        Tween<double>(begin: 0.6, end: 1.0).animate(_pulseController);
  }

  @override
  void dispose() {
    _transformController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Convert a tap point in widget space back to floor plan image pixels.
  Offset _toImageCoords(Offset tapLocal, Size widgetSize, Size imageSize) {
    // Account for the current InteractiveViewer transformation.
    final matrix = _transformController.value;
    final inverted = Matrix4.inverted(matrix);
    final transformed = MatrixUtils.transformPoint(inverted, tapLocal);

    // Map from the "fitted" image rect to image pixel coords.
    final fitted = applyBoxFit(BoxFit.contain, imageSize, widgetSize);
    final scaleX = imageSize.width / fitted.destination.width;
    final scaleY = imageSize.height / fitted.destination.height;
    final offsetX = (widgetSize.width - fitted.destination.width) / 2;
    final offsetY = (widgetSize.height - fitted.destination.height) / 2;

    return Offset(
      (transformed.dx - offsetX) * scaleX,
      (transformed.dy - offsetY) * scaleY,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imagePath.isEmpty) {
      return const Center(child: Text('No floor plan loaded'));
    }

    return LayoutBuilder(builder: (_, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);

      return GestureDetector(
        onTapUp: widget.onTap == null
            ? null
            : (details) {
                _resolveImageSize().then((imageSize) {
                  if (imageSize == null) return;
                  final imgCoords = _toImageCoords(
                      details.localPosition, size, imageSize);
                  widget.onTap!(imgCoords);
                });
              },
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 0.5,
          maxScale: 5.0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Base floor plan image.
              Image.file(
                File(widget.imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image, size: 64, color: Colors.red),
                ),
              ),

              // Optional heatmap overlay.
              if (widget.overlay != null) widget.overlay!,

              // Markers.
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => CustomPaint(
                  painter: _MarkerPainter(
                    markers: widget.markers,
                    pulseScale: _pulseAnim.value,
                    canvasSize: size,
                    imagePath: widget.imagePath,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<Size?> _resolveImageSize() async {
    try {
      final file = File(widget.imagePath);
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return Size(
          frame.image.width.toDouble(), frame.image.height.toDouble());
    } catch (_) {
      return null;
    }
  }
}

class _MarkerPainter extends CustomPainter {
  final List<CanvasMarker> markers;
  final double pulseScale;
  final Size canvasSize;
  final String imagePath;

  _MarkerPainter({
    required this.markers,
    required this.pulseScale,
    required this.canvasSize,
    required this.imagePath,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // This painter renders markers in widget space; the caller must provide
    // positions already converted to widget pixels. For a production build,
    // a proper coordinate mapping using the image's fitted rect should be used.
    // Here we draw simple circles + labels at the pixel positions.
    for (final marker in markers) {
      final paint = Paint()
        ..color = marker.color
        ..style = PaintingStyle.fill;

      final outerPaint = Paint()
        ..color = marker.color.withOpacity(0.3)
        ..style = PaintingStyle.fill;

      if (marker.isPulse) {
        canvas.drawCircle(
            marker.position, marker.radius * pulseScale * 2.0, outerPaint);
      }

      canvas.drawCircle(marker.position, marker.radius, paint);

      if (marker.label.isNotEmpty) {
        final span = TextSpan(
          text: marker.label,
          style: TextStyle(
            color: Colors.white,
            fontSize: marker.isPulse ? 10 : 12,
            fontWeight: FontWeight.bold,
            shadows: const [
              Shadow(color: Colors.black, blurRadius: 3),
            ],
          ),
        );
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          marker.position -
              Offset(tp.width / 2, tp.height / 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerPainter old) =>
      old.pulseScale != pulseScale || old.markers != markers;
}
