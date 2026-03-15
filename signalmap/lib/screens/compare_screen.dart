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

  // Local HeatmapService instances for each session.
  final _heatA = HeatmapService();
  final _heatB = HeatmapService();

  bool _loading = true;
  bool _rendering = false;
  bool _showB = false; // toggle: false = show A, true = show B
  Size? _imageSize;

  double? _repeatabilityScore; // lower = more consistent

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void dispose() {
    _heatA.dispose();
    _heatB.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final storage = context.read<StorageService>();
    final sessions =
        await storage.loadCompletedSessionsForProject(widget.projectId);

    setState(() {
      _sessions = sessions;
      _loading = false;
      // Auto-select the two most recent sessions.
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
    setState(() => _rendering = true);

    final storage = context.read<StorageService>();

    _pointsA = await storage.loadSamplePoints(_sessionA!.id);
    _pointsB = await storage.loadSamplePoints(_sessionB!.id);

    // Load floorplan from session A (both share the same project floorplan).
    _floorplan = await storage.loadFloorplan(_sessionA!.floorplanId);

    // Load image size for correct heatmap overlay positioning.
    if (_floorplan != null && _floorplan!.imagePath.isNotEmpty) {
      try {
        final bytes = await File(_floorplan!.imagePath).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        _imageSize = Size(
            frame.image.width.toDouble(), frame.image.height.toDouble());
      } catch (_) {}
    }

    // Compute combined bounds so both heatmaps use the same coordinate space.
    final allPoints = [..._pointsA, ..._pointsB];
    if (allPoints.isNotEmpty) {
      final xs = allPoints.map((p) => p.x).toList();
      final ys = allPoints.map((p) => p.y).toList();
      final origin = Offset(
        xs.reduce(min) - 2,
        ys.reduce(min) - 2,
      );
      final size = Size(
        xs.reduce(max) - origin.dx + 2,
        ys.reduce(max) - origin.dy + 2,
      );

      // Render both heatmaps with the same bounds for accurate comparison.
      await Future.wait([
        if (_pointsA.isNotEmpty)
          _heatA.rebuild(
              points: _pointsA, originMeters: origin, sizeMeters: size),
        if (_pointsB.isNotEmpty)
          _heatB.rebuild(
              points: _pointsB, originMeters: origin, sizeMeters: size),
      ]);
    }

    _repeatabilityScore = _computeRepeatability(_pointsA, _pointsB);

    if (mounted) setState(() => _rendering = false);
  }

  /// Compute spatial repeatability: average |RSSI_A − RSSI_B| for pairs of
  /// measurements within 1.5 m of each other. Returns null if not enough
  /// overlapping data.
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
          break; // one nearest match per point
        }
      }
    }
    if (diffs.length < 3) return null;
    return diffs.reduce((a, b) => a + b) / diffs.length;
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
        // Session selector.
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

        // Toggle A / B.
        if (_sessionA != null && _sessionB != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
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
              ],
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
                      overlay: (_imageSize != null)
                          ? _buildOverlay()
                          : null,
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
    final result = _showB ? _heatB.currentResult : _heatA.currentResult;
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
                Text(
                  'Repeatability score: ±${repeatability!.toStringAsFixed(1)} dBm avg '
                  '— ${repeatability! <= 3.0 ? 'Consistent' : repeatability! <= 6.0 ? 'Moderate variation' : 'High variation'}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white54),
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
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
        ],
      ),
    );
  }
}
