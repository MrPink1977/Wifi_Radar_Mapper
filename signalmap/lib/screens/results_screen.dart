import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/recommendation.dart';
import '../models/scan_session.dart';
import '../services/heatmap_service.dart';
import '../services/scan_controller.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../widgets/floorplan_canvas.dart';
import '../widgets/heatmap_painter.dart';

class ResultsScreen extends StatefulWidget {
  final String sessionId;
  const ResultsScreen({super.key, required this.sessionId});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _showingResults = false;
  // Shared selected rank for pin↔card cross-highlighting (null = none).
  int? _selectedRank;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _showingResults = true);
    });
  }

  void _onPinTapped(int rank) {
    setState(() => _selectedRank = _selectedRank == rank ? null : rank);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ScanController>();
    final session = controller.session;

    if (!_showingResults || session == null) {
      return _LoadingScreen(ready: session != null && _showingResults);
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('RESULTS'),
          leading: IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => context.go('/'),
            tooltip: 'Home',
          ),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.map), text: 'Heatmap'),
              Tab(icon: Icon(Icons.recommend), text: 'Recommendations'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _HeatmapTab(
              controller: controller,
              session: session,
              selectedRank: _selectedRank,
              onPinTapped: _onPinTapped,
            ),
            _RecommendationsTab(
              session: session,
              selectedRank: _selectedRank,
              onCardTapped: _onPinTapped,
            ),
          ],
        ),
        bottomNavigationBar: _BottomBar(session: session),
      ),
    );
  }
}

// ── Loading screen ───────────────────────────────────────────────────────────

class _LoadingScreen extends StatefulWidget {
  final bool ready;
  const _LoadingScreen({required this.ready});

  @override
  State<_LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<_LoadingScreen> {
  int _step = 0;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _step = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = [
      'Analysing signal data\u2026',
      'Building your coverage map\u2026',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('RESULTS')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 28),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: Text(
                messages[_step],
                key: ValueKey(_step),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Heatmap tab ──────────────────────────────────────────────────────────────

class _HeatmapTab extends StatefulWidget {
  final ScanController controller;
  final ScanSession session;
  final int? selectedRank;
  final void Function(int rank) onPinTapped;

  const _HeatmapTab({
    required this.controller,
    required this.session,
    required this.selectedRank,
    required this.onPinTapped,
  });

  @override
  State<_HeatmapTab> createState() => _HeatmapTabState();
}

class _HeatmapTabState extends State<_HeatmapTab> {
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    final fp = widget.controller.floorplan;
    if (fp == null || fp.imagePath.isEmpty) return;
    try {
      final bytes = await File(fp.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() => _imageSize =
            Size(frame.image.width.toDouble(), frame.image.height.toDouble()));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Watch HeatmapService so the tab rebuilds when the heatmap finishes
    // rendering (important when loading a saved session).
    final heatmapService = context.watch<HeatmapService>();

    final floorplan = widget.controller.floorplan;
    final session = widget.session;

    if (floorplan == null || floorplan.imagePath.isEmpty) {
      return const Center(child: Text('No floor plan available.'));
    }

    final heatmapResult = heatmapService.currentResult;
    final bestRssi = session.samplePoints.isEmpty
        ? null
        : session.samplePoints
            .map((p) => p.rssiDbm)
            .reduce((a, b) => a > b ? a : b);

    // Placement pins (numbered 1/2/3), sorted by rank.
    final placements = session.recommendations
        .where((r) => r.rank != null)
        .toList()
      ..sort((a, b) => (a.rank ?? 99).compareTo(b.rank ?? 99));

    return Column(
      children: [
        // Router baseline banner.
        if (bestRssi != null)
          Container(
            color: const Color(0xFF1A2744),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.router, color: Color(0xFF2196F3), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Best signal recorded: ${bestRssi.toStringAsFixed(0)} dBm'
                    ' (${tierForRssi(bestRssi).label}) — Your Router',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

        Expanded(
          child: FloorplanCanvas(
            imagePath: floorplan.imagePath,
            markers: [
              // Router position marker.
              if (session.routerX != null && session.routerY != null)
                CanvasMarker(
                  position: floorplan.metersToPixels(
                      Offset(session.routerX!, session.routerY!)),
                  color: const Color(0xFF2196F3),
                  label: 'R',
                  radius: 14,
                ),
              // Numbered placement pins — highlighted when selected.
              ...placements.map((rec) {
                final isSelected = widget.selectedRank == rec.rank;
                return CanvasMarker(
                  position: floorplan.metersToPixels(rec.position),
                  color: isSelected
                      ? Colors.white
                      : _colorForRec(rec),
                  label: rec.markerLabel,
                  radius: isSelected ? 18 : 14,
                );
              }),
              // Dead zone pins.
              ...session.recommendations
                  .where((r) => r.type == RecommendationType.deadZone)
                  .map((rec) => CanvasMarker(
                        position: floorplan.metersToPixels(rec.position),
                        color: Colors.red,
                        label: '!',
                        radius: 12,
                      )),
            ],
            overlay: (heatmapResult != null && _imageSize != null)
                ? HeatmapOverlay(
                    result: heatmapResult,
                    floorplan: floorplan,
                    imageSize: _imageSize!,
                  )
                : null,
            onTap: (pixelPos) {
              // Tapping near a pin highlights it.
              for (final rec in placements) {
                final pinPx = floorplan.metersToPixels(rec.position);
                final dx = pixelPos.dx - pinPx.dx;
                final dy = pixelPos.dy - pinPx.dy;
                if (dx * dx + dy * dy < 40 * 40) {
                  widget.onPinTapped(rec.rank!);
                  return;
                }
              }
            },
          ),
        ),
        _RssiLegend(),
      ],
    );
  }

  Color _colorForRec(Recommendation rec) {
    if (rec.rank == 1) return const Color(0xFF00E676);
    if (rec.rank == 2) return const Color(0xFF2196F3);
    return const Color(0xFFFF9800);
  }
}

// ── Recommendations tab ──────────────────────────────────────────────────────

class _RecommendationsTab extends StatelessWidget {
  final ScanSession session;
  final int? selectedRank;
  final void Function(int rank) onCardTapped;

  const _RecommendationsTab({
    required this.session,
    required this.selectedRank,
    required this.onCardTapped,
  });

  @override
  Widget build(BuildContext context) {
    final recs = session.recommendations;

    if (recs.isEmpty) {
      return const Center(
          child: Text(
              'No recommendations generated.\nTry scanning more of the space.'));
    }

    final placements = recs.where((r) => r.rank != null).toList()
      ..sort((a, b) => (a.rank ?? 99).compareTo(b.rank ?? 99));
    final deadZones =
        recs.where((r) => r.type == RecommendationType.deadZone).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ScanSummaryCard(session: session),
        const SizedBox(height: 8),
        if (placements.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Placement Recommendations',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white54, letterSpacing: 1.1)),
          ),
          ...placements.map((rec) => _PlacementCard(
                rec: rec,
                isSelected: selectedRank == rec.rank,
                onTap: () => onCardTapped(rec.rank!),
              )),
        ],
        if (deadZones.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Weak Zones',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.red.shade300, letterSpacing: 1.1)),
          ),
          ...deadZones.map((rec) => _DeadZoneCard(rec: rec)),
        ],
      ],
    );
  }
}

// ── Cards ────────────────────────────────────────────────────────────────────

class _ScanSummaryCard extends StatefulWidget {
  final ScanSession session;
  const _ScanSummaryCard({required this.session});

  @override
  State<_ScanSummaryCard> createState() => _ScanSummaryCardState();
}

class _ScanSummaryCardState extends State<_ScanSummaryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final avg = session.averageRssi;

    // Signal distribution by tier.
    final tierCounts = <String, int>{};
    for (final tier in rssiTiers) {
      tierCounts[tier.label] = 0;
    }
    for (final pt in session.samplePoints) {
      final t = tierForRssi(pt.rssiDbm);
      tierCounts[t.label] = (tierCounts[t.label] ?? 0) + 1;
    }

    return Card(
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Scan Summary',
                        style: theme.textTheme.titleLarge),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white38,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _StatRow(
                  label: 'Samples collected',
                  value: '${session.sampleCount}'),
              _StatRow(
                  label: 'Network scanned',
                  value: session.networkId),
              if (avg != null)
                _StatRow(
                  label: 'Average signal',
                  value:
                      '${avg.toStringAsFixed(0)} dBm (${tierForRssi(avg).label})',
                ),
              if (session.duration != null)
                _StatRow(
                  label: 'Scan duration',
                  value: '${session.duration!.inSeconds}s',
                ),

              // ── Expanded details ─────────────────────────────────────────
              if (_expanded) ...[
                const Divider(height: 24, color: Colors.white12),
                Text('Signal Distribution',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: Colors.white54)),
                const SizedBox(height: 10),
                ...rssiTiers.map((tier) {
                  final count = tierCounts[tier.label] ?? 0;
                  final pct = session.sampleCount > 0
                      ? (count / session.sampleCount * 100).round()
                      : 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: tier.color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 72,
                          child: Text(tier.label,
                              style: theme.textTheme.bodySmall),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: pct / 100.0,
                              backgroundColor: Colors.white12,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(tier.color),
                              minHeight: 6,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text('$pct%',
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.right),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(value,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PlacementCard extends StatelessWidget {
  final Recommendation rec;
  final bool isSelected;
  final VoidCallback onTap;

  const _PlacementCard({
    required this.rec,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinColor = rec.rank == 1
        ? const Color(0xFF00E676)
        : rec.rank == 2
            ? const Color(0xFF2196F3)
            : const Color(0xFFFF9800);

    return Card(
      shape: isSelected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: pinColor, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.white : pinColor,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('${rec.rank}',
                          style: TextStyle(
                              color: isSelected ? pinColor : Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(rec.title,
                        style: theme.textTheme.titleMedium),
                  ),
                  _ScoreChip(score: rec.score),
                ],
              ),
              const SizedBox(height: 10),
              Text(rec.description, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(
                'Tap pin on map to highlight • Recommended: mesh extender, ESP32 hub, or IoT gateway',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeadZoneCard extends StatelessWidget {
  final Recommendation rec;
  const _DeadZoneCard({required this.rec});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(Icons.warning_amber, color: Colors.red, size: 28),
        title: Text(rec.title, style: theme.textTheme.titleMedium),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(rec.description, style: theme.textTheme.bodyMedium),
        ),
      ),
    );
  }
}

class _ScoreChip extends StatelessWidget {
  final double score;
  const _ScoreChip({required this.score});

  @override
  Widget build(BuildContext context) {
    final color = score > 0.7
        ? const Color(0xFF00E676)
        : score > 0.4
            ? const Color(0xFFFFD600)
            : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        '${(score * 100).round()}%',
        style: TextStyle(
            color: color, fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }
}

class _RssiLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111827),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: rssiTiers.map((tier) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: tier.color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 4),
              Text(tier.label,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11)),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _BottomBar extends StatefulWidget {
  final ScanSession session;
  const _BottomBar({required this.session});

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar> {
  int _completedScans = 0;

  @override
  void initState() {
    super.initState();
    _checkScanCount();
  }

  Future<void> _checkScanCount() async {
    final storage = context.read<StorageService>();
    final sessions = await storage.loadCompletedSessionsForProject(
        widget.session.projectId);
    if (mounted) {
      setState(() => _completedScans = sessions.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.home),
                label: const Text('Done'),
              ),
            ),
            const SizedBox(width: 12),
            if (_completedScans >= 2) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push(
                      '/compare?projectId=${widget.session.projectId}'),
                  icon: const Icon(Icons.compare),
                  label: const Text('Compare'),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  context.go('/setup?projectId=${widget.session.projectId}');
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Scan Again'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
