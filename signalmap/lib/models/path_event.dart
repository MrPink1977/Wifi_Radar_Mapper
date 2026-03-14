/// A single movement vector recorded during a scan, used for dead reckoning
/// replay and path comparison between sessions.
class PathEvent {
  final DateTime timestamp;
  final int stepCount;
  final double headingDeg;
  final double deltaX; // meters
  final double deltaY; // meters

  const PathEvent({
    required this.timestamp,
    required this.stepCount,
    required this.headingDeg,
    required this.deltaX,
    required this.deltaY,
  });

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp.toIso8601String(),
        'stepCount': stepCount,
        'headingDeg': headingDeg,
        'deltaX': deltaX,
        'deltaY': deltaY,
      };

  factory PathEvent.fromMap(Map<String, dynamic> m) => PathEvent(
        timestamp: DateTime.parse(m['timestamp'] as String),
        stepCount: m['stepCount'] as int,
        headingDeg: (m['headingDeg'] as num).toDouble(),
        deltaX: (m['deltaX'] as num).toDouble(),
        deltaY: (m['deltaY'] as num).toDouble(),
      );
}
