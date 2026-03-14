import 'sample_point.dart';
import 'path_event.dart';
import 'recommendation.dart';

enum SignalType { wifi, bluetooth }

enum SessionState { setup, scanning, processing, complete, error }

class ScanSession {
  final String id;
  final String projectId;
  final String floorplanId;
  final SignalType signalType;
  final String networkId; // SSID or BT device name
  final DateTime startTime;
  DateTime? endTime;
  SessionState state;
  final List<SamplePoint> samplePoints;
  final List<PathEvent> pathEvents;
  List<Recommendation> recommendations;
  final int algorithmVersion;

  ScanSession({
    required this.id,
    required this.projectId,
    required this.floorplanId,
    required this.signalType,
    required this.networkId,
    DateTime? startTime,
    this.endTime,
    this.state = SessionState.setup,
    List<SamplePoint>? samplePoints,
    List<PathEvent>? pathEvents,
    List<Recommendation>? recommendations,
    this.algorithmVersion = 1,
  })  : startTime = startTime ?? DateTime.now(),
        samplePoints = samplePoints ?? [],
        pathEvents = pathEvents ?? [],
        recommendations = recommendations ?? [];

  Duration? get duration =>
      endTime != null ? endTime!.difference(startTime) : null;

  int get sampleCount => samplePoints.length;

  double? get averageRssi {
    if (samplePoints.isEmpty) return null;
    return samplePoints.map((p) => p.rssiDbm).reduce((a, b) => a + b) /
        samplePoints.length;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'projectId': projectId,
        'floorplanId': floorplanId,
        'signalType': signalType.name,
        'networkId': networkId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'state': state.name,
        'algorithmVersion': algorithmVersion,
      };

  factory ScanSession.fromMap(Map<String, dynamic> m) => ScanSession(
        id: m['id'] as String,
        projectId: m['projectId'] as String,
        floorplanId: m['floorplanId'] as String,
        signalType: SignalType.values.firstWhere(
          (e) => e.name == m['signalType'],
          orElse: () => SignalType.wifi,
        ),
        networkId: m['networkId'] as String,
        startTime: DateTime.parse(m['startTime'] as String),
        endTime: m['endTime'] != null
            ? DateTime.parse(m['endTime'] as String)
            : null,
        state: SessionState.values.firstWhere(
          (e) => e.name == m['state'],
          orElse: () => SessionState.complete,
        ),
        algorithmVersion: m['algorithmVersion'] as int? ?? 1,
      );
}
