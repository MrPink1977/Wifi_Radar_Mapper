import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/recommendation.dart';
import '../models/scan_session.dart';
import '../services/scan_controller.dart';
import '../utils/constants.dart';
import '../widgets/floorplan_canvas.dart';
import '../widgets/heatmap_painter.dart';

class ResultsScreen extends StatelessWidget {
  final String sessionId;
  const ResultsScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ScanController>();
    final session = controller.session;
    final theme = Theme.of(context);

    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('RESULTS')),
        body: const Center(child: Text('No session data found.')),
      );
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
            _HeatmapTab(controller: controller, session: session),
            _RecommendationsTab(session: session),
          ],
        ),
        bottomNavigationBar: _BottomBar(session: session),
      ),
    );
  }
}

class _HeatmapTab extends StatelessWidget {
  final ScanController controller;
  final ScanSession session;
  const _HeatmapTab({required this.controller, required this.session});

  @override
  Widget build(BuildContext context) {
    final floorplan = controller.floorplan;
    if (floorplan == null || floorplan.imagePath.isEmpty) {
      return const Center(child: Text('No floor plan available.'));
    }

    return Column(
      children: [
        Expanded(
          child: FloorplanCanvas(
            imagePath: floorplan.imagePath,
            markers: [
              // Recommendation pins
              ...session.recommendations.map((rec) {
                final px = floorplan.metersToPixels(rec.position);
                return CanvasMarker(
                  position: px,
                  color: _colorForRecType(rec.type),
                  label: rec.markerLabel,
                  radius: 14,
                );
              }),
            ],
            overlay: controller.heatmap.currentResult != null
                ? HeatmapOverlay(
                    result: controller.heatmap.currentResult!,
                    floorplan: floorplan,
                  )
                : null,
          ),
        ),
        _RssiLegend(),
      ],
    );
  }

  Color _colorForRecType(RecommendationType type) {
    switch (type) {
      case RecommendationType.bestGateway:
        return const Color(0xFF00E676);
      case RecommendationType.bestMeshExtender:
        return Colors.blue;
      case RecommendationType.deadZone:
        return Colors.red;
      case RecommendationType.comparisonTrust:
        return Colors.purple;
    }
  }
}

class _RecommendationsTab extends StatelessWidget {
  final ScanSession session;
  const _RecommendationsTab({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recs = session.recommendations;

    if (recs.isEmpty) {
      return const Center(
          child: Text('No recommendations generated.\nTry scanning more of the space.'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ScanSummaryCard(session: session),
        const SizedBox(height: 8),
        ...recs.map((rec) => _RecommendationCard(rec: rec)),
      ],
    );
  }
}

class _ScanSummaryCard extends StatelessWidget {
  final ScanSession session;
  const _ScanSummaryCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avg = session.averageRssi;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scan Summary', style: theme.textTheme.titleLarge),
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
          ],
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

class _RecommendationCard extends StatelessWidget {
  final Recommendation rec;
  const _RecommendationCard({required this.rec});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Text(rec.markerLabel, style: const TextStyle(fontSize: 28)),
        title: Text(rec.title, style: theme.textTheme.titleMedium),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(rec.description, style: theme.textTheme.bodyMedium),
        ),
        trailing: _ScoreChip(score: rec.score),
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

class _BottomBar extends StatelessWidget {
  final ScanSession session;
  const _BottomBar({required this.session});

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
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  // Navigate back to setup to run another scan.
                  context.go('/setup?projectId=${session.projectId}');
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
