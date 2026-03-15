import 'dart:math';
import 'dart:ui';

class AnchorPoint {
  final String id;
  final Offset position; // pixels on floor plan image
  final double realWorldX; // meters
  final double realWorldY; // meters

  const AnchorPoint({
    required this.id,
    required this.position,
    required this.realWorldX,
    required this.realWorldY,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'px': position.dx,
        'py': position.dy,
        'rx': realWorldX,
        'ry': realWorldY,
      };

  factory AnchorPoint.fromMap(Map<String, dynamic> m) => AnchorPoint(
        id: m['id'] as String,
        position: Offset(m['px'] as double, m['py'] as double),
        realWorldX: m['rx'] as double,
        realWorldY: m['ry'] as double,
      );
}

class Floorplan {
  final String id;
  final String imagePath;
  double scalePixelsPerMeter; // derived from calibration anchors
  List<AnchorPoint> anchorPoints;
  final DateTime createdAt;

  Floorplan({
    required this.id,
    required this.imagePath,
    this.scalePixelsPerMeter = 50.0,
    List<AnchorPoint>? anchorPoints,
    DateTime? createdAt,
  })  : anchorPoints = anchorPoints ?? [],
        createdAt = createdAt ?? DateTime.now();

  /// Compute scale from two calibration anchor points and a known real-world distance.
  void calibrateScale(AnchorPoint a, AnchorPoint b, double realMeters) {
    final dx = a.position.dx - b.position.dx;
    final dy = a.position.dy - b.position.dy;
    final pixelDist = sqrt(dx * dx + dy * dy); // Euclidean distance in pixels
    if (pixelDist > 0 && realMeters > 0) {
      scalePixelsPerMeter = pixelDist / realMeters;
    }
  }

  /// Convert floor plan pixel coords to real-world meters (relative to first anchor).
  Offset pixelsToMeters(Offset pixels) {
    if (anchorPoints.isEmpty) {
      return pixels / scalePixelsPerMeter;
    }
    final ref = anchorPoints.first;
    final dx = (pixels.dx - ref.position.dx) / scalePixelsPerMeter;
    final dy = (pixels.dy - ref.position.dy) / scalePixelsPerMeter;
    return Offset(ref.realWorldX + dx, ref.realWorldY + dy);
  }

  /// Convert real-world meters to floor plan pixel coords.
  Offset metersToPixels(Offset meters) {
    if (anchorPoints.isEmpty) {
      return meters * scalePixelsPerMeter;
    }
    final ref = anchorPoints.first;
    final px = ref.position.dx + (meters.dx - ref.realWorldX) * scalePixelsPerMeter;
    final py = ref.position.dy + (meters.dy - ref.realWorldY) * scalePixelsPerMeter;
    return Offset(px, py);
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'imagePath': imagePath,
        'scale': scalePixelsPerMeter,
        'anchors': anchorPoints.map((a) => a.toMap()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Floorplan.fromMap(Map<String, dynamic> m) => Floorplan(
        id: m['id'] as String,
        imagePath: m['imagePath'] as String,
        scalePixelsPerMeter: (m['scale'] as num).toDouble(),
        anchorPoints: (m['anchors'] as List<dynamic>)
            .map((a) => AnchorPoint.fromMap(a as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(m['createdAt'] as String),
      );
}
