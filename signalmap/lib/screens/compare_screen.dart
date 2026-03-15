import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/floorplan.dart';
import '../models/sample_point.dart';
import '../models/scan_session.dart';
import '../services/heatmap_service.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../widgets/floorplan_canvas.dart';
import '../widgets/heatmap_painter.dart';

class CompareScreen extends StatefulWidget {
  final String projectId;
  const CompareScreen({super.key, required this.projectId});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  List<ScanSession> _sessions = [];
  ScanSession? _sessionA;
  ScanSession? _sessionB;
  List<SamplePoint> _pointsA = [];
  List<SamplePoint> _pointsB = [];
  Floorplan? _floorplan;

  // Heatmap instances are recreated fresh for each render to avoid the
  // HeatmapService._isProcessing guard silently swallowing a second rebuild
  // request when the user changes session selection mid-render.
  HeatmapResult? _resultA;
  HeatmapResult? _resultB;

  bool _loading = true;
  bool _rendering = false;
  bool _showB = false;
  Size? _imageSize;

  // Generation counter: if the user changes selection while a render is in
  // flight, the stale result is discarded instead of overwriting the new one.
  int _renderGeneration = 0;

  double? _repeatabilityScore;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final storage = context.read<StorageService>();
    final sessions =
        await storage.loadCompletedSessionsForProject(widget.projectId);

    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
      if (sessions.length >= 2) {
        _sessionA = sessions[0];
        _sessionB = sessions[1];
      }
    });

    if (_sessionA != null && _sessionB != null) {
      await _renderComparison();
    }
  }

  Future<void> _renderComparison() async {
    if (_sessionA == null || _sessionB == null) return;

    // Capture the generation for this render before any awaits.
    final gen = ++_renderGeneration;
    if (mounted) setState(() => _rendering = true);

    final storage = context.read<StorageService>();

    final pointsA = await storage.loadSamplePoints(_sessionA!.id);
    final pointsB = await storage.loadSamplePoints(_sessionB!.id);
    final floorplan = await storage.loadFloorplan(_sessionA!.floorplanId);

    Size? imageSize;
    if (floorplan != null && floorplan.imagePath.isNotEmpty) {
      try {
        final bytes = await File(floorplan.imagePath).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        imageSize = Size(
            frame.image.width.toDouble(), frame.image.height.toDouble());
      } catch (_) {}
    }

    // Compute shared coordinate bounds for both heatmaps.
    HeatmapResult? resultA;
    HeatmapResult? resultB;
    final allPoints = [...pointsA, ...pointsB];

    if (allPoints.isNotEmpty) {
      final xs = allPoints.map((p) => p.x).toList();
      final ys = allPoints.map((p) => p.y).toList();
      final origin = Offset(xs.reduce(min) - 2, ys.reduce(min) - 2);
      final size = Size(
        xs.reduce(max) - origin.dx + 2,
        ys.reduce(max) - origin.dy + 2,
      );

      // Create fresh HeatmapService instances to avoid the _isProcessing
      // guard blocking a re-render when the user changes session selection.
      final svcA = HeatmapService();
      final svcB = HeatmapService();

      await Future.wait([
        if (pointsA.isNotEmpty)
          svcA.rebuild(points: pointsA, originMeters: origin, sizeMeters: size),
        if (pointsB.isNotEmpty)
          svcB.rebuild(points: pointsB, originMeters: origin, sizeMeters: size),
      ]);

      resultA = svcA.currentResult;
      resultB = svcB.currentResult;

      // Dispose the service wrappers now that we've extracted the results.
      // The ui.Image objects inside HeatmapResult remain valid until the
      // results themselves are replaced.
      //
      // NOTE: rebuild() is fully awaited above, so _isProcessing is false
      // and notifyListeners() will not be called after dispose() — no
      // use-after-dispose assertion risk.
      svcA.dispose();
      svcB.dispose();
    }

    // Discard if a newer render was requested while we were processing.
    if (!mounted || gen != _renderGeneration) return;

    // Dispose previous image resources before replacing.
    _resultA?.image.dispose();
    _resultB?.image.dispose();

    setState(() {
      _pointsA = pointsA;
      _pointsB = pointsB;
      _floorplan = floorplan;
      _imageSize = imageSize;
      _resultA = resultA;
      _resultB = resultB;
      _repeatabilityScore = _computeRepeatability(pointsA, pointsB);
      _rendering = false;
    });
  }

  /// Spatial repeatability: average |RSSI_A − RSSI_B| for co-located pairs
  /// (within 1.5 m). Returns null when fewer than 3 pairs are found.
  double? _computeRepeatability(
      List<SamplePoint> a, List<SamplePoint> b) {
    if (a.isEmpty || b.isEmpty) return null;
    final diffs = <double>[];
    for (final pa in a) {
      for (final pb in b) {
        final dx = pa.x - pb.x;
        final dy = pa.y - pb.y;
        if (dx * dx + dy * dy <= 1.5 * 1.5) {
          diffs.add((pa.rssiDbm - pb.rssiDbm).abs());
          break;
        }
      }
    }
    if (diffs.length < 3) return null;
    return diffs.reduce((a, b) => a + b) / diffs.length;
  }

  @override
  void dispose() {
    // Only dispose image resources we own. The HeatmapService instances are
    // always disposed inside _renderComparison() right after rebuild() awaits,
    // so there is no live service to clean up here.
    _resultA?.image.dispose();
    _resultB?.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('COMPARE SCANS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.length < 2
              ? _buildNotEnoughScans(theme)
              : _buildCompareView(theme),
    );
  }

  Widget _buildNotEnoughScans(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.compare_arrows,
                size: 64,
                color: theme.colorScheme.primary.withOpacity(0.4)),
            const SizedBox(height: 24),
            Text('Not enough scans',
                style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              'Complete at least two scans of this space to compare results.',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompareView(ThemeData theme) {
    return Column(
      children: [
        // Session selector row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: _SessionPicker(
                  label: 'Baseline',
                  color: const Color(0xFF2196F3),
                  sessions: _sessions,
                  selected: _sessionA,
                  exclude: _sessionB,
                  onChanged: (s) async {
                    setState(() => _sessionA = s);
                    await _renderComparison();
                  },
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.compare_arrows, color: Colors.white38),
              const SizedBox(width: 8),
              Expanded(
                child: _SessionPicker(
                  label: 'Candidate',
                  color: const Color(0xFF00E676),
                  sessions: _sessions,
                  selected: _sessionB,
                  exclude: _sessionA,
                  onChanged: (s) async {
                    setState(() => _sessionB = s);
                    await _renderComparison();
                  },
                ),
              ),
            ],
          ),
        ),

        // A / B toggle.
        if (_sessionA != null && _sessionB != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('Baseline'),
                    icon: Icon(Icons.looks_one)),
                ButtonSegment(
                    value: true,
                    label: Text('Candidate'),
                    icon: Icon(Icons.looks_two)),
              ],
              selected: {_showB},
              onSelectionChanged: (v) =>
                  setState(() => _showB = v.first),
            ),
          ),

        // Heatmap display.
        Expanded(
          child: _rendering
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Building comparison\u2026'),
                    ],
                  ),
                )
              : _floorplan == null || _floorplan!.imagePath.isEmpty
                  ? const Center(child: Text('No floor plan available.'))
                  : FloorplanCanvas(
                      imagePath: _floorplan!.imagePath,
                      overlay: _buildOverlay(),
                    ),
        ),

        // Stats comparison panel.
        if (_sessionA != null && _sessionB != null && !_rendering)
          _CompareStatsPanel(
            sessionA: _sessionA!,
            sessionB: _sessionB!,
            pointsA: _pointsA,
            pointsB: _pointsB,
            repeatability: _repeatabilityScore,
          ),
      ],
    );
  }

  Widget? _buildOverlay() {
    final result = _showB ? _resultB : _resultA;
    if (result == null || _floorplan == null || _imageSize == null) {
      return null;
    }
    return HeatmapOverlay(
      result: result,
      floorplan: _floorplan!,
      imageSize: _imageSize!,
      opacity: 0.70,
    );
  }
}

// ── Session picker ────────────────────────────────────────────────────────────

class _SessionPicker extends StatelessWidget {
  final String label;
  final Color color;
  final List<ScanSession> sessions;
  final ScanSession? selected;
  final ScanSession? exclude;
  final void Function(ScanSession) onChanged;

  const _SessionPicker({
    required this.label,
    required this.color,
    required this.sessions,
    required this.selected,
    required this.exclude,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = sessions.where((s) => s.id != exclude?.id).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white54)),
          ],
        ),
        const SizedBox(height: 4),
        DropdownButton<String>(
          isExpanded: true,
          value: selected?.id,
          style: theme.textTheme.bodyMedium,
          dropdownColor: const Color(0xFF1F2937),
          underline: Container(height: 1, color: Colors.white24),
          items: available
              .map((s) => DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      _formatSession(s),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (id) {
            if (id == null) return;
            final s = available.firstWhere((s) => s.id == id);
            onChanged(s);
          },
        ),
      ],
    );
  }

  String _formatSession(ScanSession s) {
    final dt = s.endTime ?? s.startTime;
    final date =
        '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date · ${s.networkId}';
  }
}

// ── Stats comparison panel ────────────────────────────────────────────────────

class _CompareStatsPanel extends StatelessWidget {
  final ScanSession sessionA;
  final ScanSession sessionB;
  final List<SamplePoint> pointsA;
  final List<SamplePoint> pointsB;
  final double? repeatability;

  const _CompareStatsPanel({
    required this.sessionA,
    required this.sessionB,
    required this.pointsA,
    required this.pointsB,
    required this.repeatability,
  });

  double? _avg(List<SamplePoint> pts) {
    if (pts.isEmpty) return null;
    return pts.map((p) => p.rssiDbm).reduce((a, b) => a + b) / pts.length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avgA = _avg(pointsA);
    final avgB = _avg(pointsB);
    final delta = (avgA != null && avgB != null) ? avgB - avgA : null;

    return Container(
      color: const Color(0xFF111827),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Comparison Summary',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: Colors.white54)),
          const SizedBox(height: 10),
          Row(
            children: [
              _StatCol(
                label: 'Baseline avg',
                value: avgA != null
                    ? '${avgA.toStringAsFixed(1)} dBm'
                    : '—',
                subLabel: avgA != null ? tierForRssi(avgA).label : '',
                color: const Color(0xFF2196F3),
              ),
              const SizedBox(width: 12),
              _StatCol(
                label: 'Candidate avg',
                value: avgB != null
                    ? '${avgB.toStringAsFixed(1)} dBm'
                    : '—',
                subLabel: avgB != null ? tierForRssi(avgB).label : '',
                color: const Color(0xFF00E676),
              ),
              const SizedBox(width: 12),
              _StatCol(
                label: 'Change',
                value: delta != null
                    ? '${delta > 0 ? '+' : ''}${delta.toStringAsFixed(1)} dBm'
                    : '—',
                subLabel: delta != null
                    ? (delta > 1.5
                        ? 'Improved'
                        : delta < -1.5
                            ? 'Degraded'
                            : 'Similar')
                    : '',
                color: delta == null
                    ? Colors.white38
                    : delta > 1.5
                        ? const Color(0xFF00E676)
                        : delta < -1.5
                            ? Colors.red
                            : Colors.amber,
              ),
            ],
          ),
          if (repeatability != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.repeat, size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Repeatability: ±${repeatability!.toStringAsFixed(1)} dBm avg '
                    '— ${repeatability! <= 3.0 ? 'Consistent' : repeatability! <= 6.0 ? 'Moderate variation' : 'High variation'}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.white54),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatCol extends StatelessWidget {
  final String label;
  final String value;
  final String subLabel;
  final Color color;

  const _StatCol({
    required this.label,
    required this.value,
    required this.subLabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.white38)),
          const SizedBox(height: 2),
          Text(value,
              style: theme.textTheme.titleMedium?.copyWith(color: color)),
          if (subLabel.isNotEmpty)
            Text(subLabel,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white38)),
        ],
      ),
    );
  }
}
