import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:uuid/uuid.dart';

import '../models/floorplan.dart';
import '../models/path_event.dart';
import '../models/sample_point.dart';
import '../models/scan_session.dart';
import '../utils/constants.dart';
import 'heatmap_service.dart';
import 'motion_service.dart';
import 'recommendation_service.dart';
import 'signal_service.dart';
import 'storage_service.dart';

const _uuid = Uuid();

/// High-level controller that orchestrates [SignalService], [MotionService],
/// and [HeatmapService] during an active scan session.
///
/// Responsible for:
///   - Deciding when to commit a [SamplePoint] (distance + dwell thresholds).
///   - Appending [PathEvent]s for replay.
///   - Triggering heatmap rebuilds after commits.
///   - Finalising the session and running recommendations.
class ScanController extends ChangeNotifier {
  final SignalService signal;
  final MotionService motion;
  final HeatmapService heatmap;
  final StorageService storage;
  final RecommendationService _recommender = RecommendationService();

  ScanSession? _session;
  ScanSession? get session => _session;

  Floorplan? _floorplan;
  Floorplan? get floorplan => _floorplan;

  bool get isScanning =>
      _session?.state == SessionState.scanning;

  // Router anchor (set during prepare, applied after motion reset).
  Offset? _routerAnchorMeters;
  Offset? get routerAnchorMeters => _routerAnchorMeters;

  // Position tracking for commit logic.
  Offset? _lastCommitPosition;
  DateTime? _lastCommitTime;

  // Timers
  Timer? _commitTimer;
  Timer? _heatmapTimer;

  ScanController({
    required this.signal,
    required this.motion,
    required this.heatmap,
    required this.storage,
  });

  /// Prepare a new scan session for [floorplan].
  ///
  /// [routerAnchor] is the user-confirmed router position in real-world
  /// metres. It is stored here and applied after the motion sensor reset
  /// when [startScan] is called, so the position dot begins at the router.
  void prepare({
    required Floorplan floorplan,
    required String projectId,
    required String networkId,
    Offset? routerAnchor,
  }) {
    _floorplan = floorplan;
    _routerAnchorMeters = routerAnchor;
    _session = ScanSession(
      id: _uuid.v4(),
      projectId: projectId,
      floorplanId: floorplan.id,
      signalType: SignalType.wifi,
      networkId: networkId,
      routerX: routerAnchor?.dx,
      routerY: routerAnchor?.dy,
    );
    notifyListeners();
  }

  /// Start scanning. Begins sensor data collection and sampling loop.
  Future<void> startScan() async {
    if (_session == null) return;
    _session!.state = SessionState.scanning;

    // Reset to origin first, then immediately apply the router anchor so the
    // position dot starts where the user is standing (not at (0,0)).
    motion.resetToOrigin();
    if (_routerAnchorMeters != null) {
      motion.correctPosition(
          _routerAnchorMeters!.dx, _routerAnchorMeters!.dy);
    }

    await signal.start();
    await motion.start();

    // Commit loop: evaluate every second.
    _commitTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _maybeCommit());

    // Heatmap refresh loop: rebuild every 2 seconds if new points exist.
    _heatmapTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _maybeRebuildHeatmap());

    notifyListeners();
  }

  /// Pause scanning without ending the session.
  void pauseScan() {
    _commitTimer?.cancel();
    signal.stop();
    notifyListeners();
  }

  /// Apply a manual position correction from the user tapping the floor plan.
  void applyManualAnchor(Offset positionMeters) {
    motion.correctPosition(positionMeters.dx, positionMeters.dy);
    // Force an immediate commit at the corrected position.
    _commitNow(sourceMode: SourceMode.corrected);
  }

  /// Finish the scan, run recommendations, and persist everything.
  Future<void> finishScan() async {
    _commitTimer?.cancel();
    _heatmapTimer?.cancel();
    signal.stop();
    motion.stop();

    if (_session == null) return;

    _session!.state = SessionState.processing;
    _session!.endTime = DateTime.now();
    notifyListeners();

    // Run recommendation engine.
    _session!.recommendations =
        _recommender.analyse(_session!.samplePoints);

    // Persist — save before transitioning to complete so the home screen
    // sees the scan immediately when the user taps Done.
    await storage.saveSession(_session!);
    await storage.saveSamplePoints(_session!.samplePoints);
    await storage.saveRecommendations(
        _session!.id, _session!.recommendations);

    // Bump project updatedAt so it surfaces at the top of the home list.
    await storage.updateProjectTimestamp(_session!.projectId);

    _session!.state = SessionState.complete;
    notifyListeners();
  }

  void _maybeCommit() {
    final pos = motion.position;
    final sig = signal.smoothed;

    if (sig == null || sig.sampleCount < 3) return;

    final currentPos = Offset(pos.x, pos.y);
    final now = DateTime.now();

    final enoughDistance = _lastCommitPosition == null ||
        (currentPos - _lastCommitPosition!).distance >= kCommitDistanceMeters;

    final enoughDwell = _lastCommitTime == null ||
        now.difference(_lastCommitTime!).inMilliseconds >=
            kCommitDwellSeconds * 1000;

    if (enoughDistance && enoughDwell) {
      _commitNow(sourceMode: SourceMode.deadReckoned);
    }
  }

  void _commitNow({required SourceMode sourceMode}) {
    final pos = motion.position;
    final sig = signal.smoothed;
    if (sig == null || _session == null) return;

    final point = SamplePoint(
      id: _uuid.v4(),
      sessionId: _session!.id,
      x: pos.x,
      y: pos.y,
      rssiDbm: sig.meanDbm,
      variance: sig.variance,
      confidence: pos.confidence,
      sourceMode: sourceMode,
      timestamp: DateTime.now(),
    );

    _session!.samplePoints.add(point);

    final pathEvent = PathEvent(
      timestamp: DateTime.now(),
      stepCount: pos.totalSteps,
      headingDeg: pos.headingDeg,
      deltaX: _lastCommitPosition != null ? pos.x - _lastCommitPosition!.dx : 0,
      deltaY: _lastCommitPosition != null ? pos.y - _lastCommitPosition!.dy : 0,
    );
    _session!.pathEvents.add(pathEvent);

    _lastCommitPosition = Offset(pos.x, pos.y);
    _lastCommitTime = DateTime.now();

    notifyListeners();
  }

  // Called by the 2-second timer; only rebuilds if there are new points.
  int _lastHeatmapPointCount = 0;
  void _maybeRebuildHeatmap() {
    final count = _session?.samplePoints.length ?? 0;
    if (count > _lastHeatmapPointCount) {
      _lastHeatmapPointCount = count;
      _rebuildHeatmap();
    }
  }

  void _rebuildHeatmap() {
    if (_floorplan == null || _session == null) return;
    final points = _session!.samplePoints;
    if (points.isEmpty) return;

    final xs = points.map((p) => p.x).toList();
    final ys = points.map((p) => p.y).toList();
    final minX = xs.reduce((a, b) => a < b ? a : b) - 2;
    final minY = ys.reduce((a, b) => a < b ? a : b) - 2;
    final maxX = xs.reduce((a, b) => a > b ? a : b) + 2;
    final maxY = ys.reduce((a, b) => a > b ? a : b) + 2;

    heatmap.rebuild(
      points: points,
      originMeters: Offset(minX, minY),
      sizeMeters: Size(maxX - minX, maxY - minY),
    );
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _heatmapTimer?.cancel();
    signal.dispose();
    motion.dispose();
    heatmap.dispose();
    super.dispose();
  }
}
