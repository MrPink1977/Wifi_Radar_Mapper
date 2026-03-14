import 'dart:ui';

/// How the position of this sample was determined.
enum SourceMode { manual, deadReckoned, corrected }

/// A single averaged RSSI measurement at a known (or estimated) position.
class SamplePoint {
  final String id;
  final String sessionId;
  final double x; // real-world meters from floor plan origin
  final double y;
  final double rssiDbm; // averaged RSSI
  final double variance; // rolling variance of raw readings
  final double confidence; // 0.0–1.0
  final SourceMode sourceMode;
  final DateTime timestamp;

  const SamplePoint({
    required this.id,
    required this.sessionId,
    required this.x,
    required this.y,
    required this.rssiDbm,
    required this.variance,
    required this.confidence,
    required this.sourceMode,
    required this.timestamp,
  });

  Offset get offset => Offset(x, y);

  Map<String, dynamic> toMap() => {
        'id': id,
        'sessionId': sessionId,
        'x': x,
        'y': y,
        'rssiDbm': rssiDbm,
        'variance': variance,
        'confidence': confidence,
        'sourceMode': sourceMode.name,
        'timestamp': timestamp.toIso8601String(),
      };

  factory SamplePoint.fromMap(Map<String, dynamic> m) => SamplePoint(
        id: m['id'] as String,
        sessionId: m['sessionId'] as String,
        x: (m['x'] as num).toDouble(),
        y: (m['y'] as num).toDouble(),
        rssiDbm: (m['rssiDbm'] as num).toDouble(),
        variance: (m['variance'] as num).toDouble(),
        confidence: (m['confidence'] as num).toDouble(),
        sourceMode: SourceMode.values.firstWhere(
          (e) => e.name == m['sourceMode'],
          orElse: () => SourceMode.manual,
        ),
        timestamp: DateTime.parse(m['timestamp'] as String),
      );
}
