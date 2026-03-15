import 'dart:io';
import 'dart:ui' as ui;

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

/// A line drawn between two image-pixel positions on the floor plan.
class CanvasLine {
  final Offset from;   // image pixels
  final Offset to;     // image pixels
  final Color color;
  final double strokeWidth;
  final String? label; // optional midpoint label

  const CanvasLine({
    required this.from,
    required this.to,
    this.color = Colors.white,
    this.strokeWidth = 2.0,
    this.label,
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
  final List<CanvasLine> lines;
  final Widget? overlay; // rendered below markers, above image
  final void Function(Offset pixelPosition)? onTap;

  const FloorplanCanvas({
    super.key,
    required this.imagePath,
    this.markers = const [],
    this.lines = const [],
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

  // Cached image size for coordinate mapping.
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim =
        Tween<double>(begin: 0.6, end: 1.0).animate(_pulseController);
    _loadImageSize();
  }

  @override
  void didUpdateWidget(FloorplanCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _imageSize = null;
      _loadImageSize();
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadImageSize() async {
    final size = await _resolveImageSize();
    if (size != null && mounted) {
      setState(() => _imageSize = size);
    }
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

              // Optional heatmap overlay — rendered in widget space.
              if (widget.overlay != null) widget.overlay!,

              // Markers and lines — require image size for correct positioning.
              if (_imageSize != null)
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => CustomPaint(
                    painter: _MarkerPainter(
                      markers: widget.markers,
                      lines: widget.lines,
                      pulseScale: _pulseAnim.value,
                      canvasSize: size,
                      imageSize: _imageSize!,
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
      final codec = await ui.instantiateImageCodec(bytes);
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
  final List<CanvasLine> lines;
  final double pulseScale;
  final Size canvasSize;
  final Size imageSize;

  _MarkerPainter({
    required this.markers,
    required this.lines,
    required this.pulseScale,
    required this.canvasSize,
    required this.imageSize,
  });

  /// Convert an image-pixel position to a widget-space position,
  /// accounting for BoxFit.contain letterboxing/pillarboxing.
  Offset _toWidget(Offset imagePx) {
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
    // Draw lines first (behind markers).
    for (final line in lines) {
      final fromW = _toWidget(line.from);
      final toW = _toWidget(line.to);

      final paint = Paint()
        ..color = line.color
        ..strokeWidth = line.strokeWidth
        ..style = PaintingStyle.stroke;

      canvas.drawLine(fromW, toW, paint);

      if (line.label != null && line.label!.isNotEmpty) {
        final mid = Offset((fromW.dx + toW.dx) / 2, (fromW.dy + toW.dy) / 2);
        final span = TextSpan(
          text: line.label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: Colors.black, blurRadius: 4)],
          ),
        );
        final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
          ..layout();
        // Draw background pill for readability.
        final bgRect = Rect.fromCenter(
          center: mid,
          width: tp.width + 10,
          height: tp.height + 6,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
          Paint()..color = Colors.black.withOpacity(0.6),
        );
        tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // Draw markers.
    for (final marker in markers) {
      final pos = _toWidget(marker.position);

      final paint = Paint()
        ..color = marker.color
        ..style = PaintingStyle.fill;

      final outerPaint = Paint()
        ..color = marker.color.withOpacity(0.3)
        ..style = PaintingStyle.fill;

      if (marker.isPulse) {
        canvas.drawCircle(pos, marker.radius * pulseScale * 2.0, outerPaint);
        // White outline for visibility over heatmap.
        canvas.drawCircle(
            pos,
            marker.radius + 2,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }

      canvas.drawCircle(pos, marker.radius, paint);

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
          pos - Offset(tp.width / 2, tp.height / 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerPainter old) =>
      old.pulseScale != pulseScale ||
      old.markers != markers ||
      old.lines != lines ||
      old.imageSize != imageSize;
}
