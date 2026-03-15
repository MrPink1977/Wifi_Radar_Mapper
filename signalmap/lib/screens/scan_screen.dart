import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/scan_session.dart';
import '../services/motion_service.dart';
import '../services/scan_controller.dart';
import '../services/signal_service.dart';
import '../utils/constants.dart';
import '../widgets/floorplan_canvas.dart';
import '../widgets/heatmap_painter.dart';
import '../widgets/rssi_indicator.dart';
import '../widgets/scan_coach.dart';

class ScanScreen extends StatefulWidget {
  final String sessionId;
  const ScanScreen({super.key, required this.sessionId});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginScan());
  }

  Future<void> _beginScan() async {
    final controller = context.read<ScanController>();
    await controller.startScan();
    if (mounted) setState(() => _started = true);
  }

  Future<void> _finishScan() async {
    final controller = context.read<ScanController>();
    await controller.finishScan();
    if (mounted) {
      context.pushReplacement(
          '/results?sessionId=${controller.session!.id}');
    }
  }

  Future<bool> _onWillPop() async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Discard scan?'),
            content: const Text(
                'Leaving will discard this scan. Are you sure?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep scanning')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<ScanController>();
    final session = controller.session;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _onWillPop()) {
          if (mounted) context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SCANNING'),
          automaticallyImplyLeading: false,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SampleCounter(count: session?.sampleCount ?? 0),
            ),
          ],
        ),
        body: Column(
          children: [
            // Live RSSI bar
            Consumer<SignalService>(
              builder: (_, signal, __) => RssiIndicator(
                rssiDbm: signal.latestRssi,
                ssid: signal.connectedSsid,
              ),
            ),

            // Floor plan with live heatmap + position dot
            Expanded(
              child: _buildMap(controller),
            ),

            // Scan coach — consumes motion and signal for contextual prompts
            Consumer2<MotionService, SignalService>(
              builder: (_, motion, signal, __) => ScanCoach(
                position: motion.position,
                sampleCount: session?.sampleCount ?? 0,
                signalVariance: signal.smoothed?.variance,
                stepsPerSecond: motion.stepsPerSecond,
              ),
            ),

            // Controls
            _buildControls(theme, controller),
          ],
        ),
      ),
    );
  }

  Widget _buildMap(ScanController controller) {
    final floorplan = controller.floorplan;
    final session = controller.session;

    if (floorplan == null || floorplan.imagePath.isEmpty) {
      return const Center(child: Text('No floor plan loaded'));
    }

    return Consumer2<MotionService, ScanController>(
      builder: (_, motion, ctrl, __) {
        final pos = motion.position;

        // Convert real-world position to pixel coords for the dot.
        final posPixels = floorplan.metersToPixels(
            Offset(pos.x, pos.y));

        return Stack(
          children: [
            FloorplanCanvas(
              imagePath: floorplan.imagePath,
              markers: [
                // Router anchor icon at scan start position.
                if (ctrl.routerAnchorMeters != null)
                  CanvasMarker(
                    position: floorplan
                        .metersToPixels(ctrl.routerAnchorMeters!),
                    color: const Color(0xFF2196F3),
                    label: 'R',
                    radius: 12,
                  ),
                // Live position dot (pulsing).
                CanvasMarker(
                  position: posPixels,
                  color: Theme.of(context).colorScheme.primary,
                  label: '',
                  isPulse: true,
                ),
                // Committed sample points as small coloured dots.
                if (session != null)
                  ...session.samplePoints.map((p) {
                    final px = floorplan.metersToPixels(Offset(p.x, p.y));
                    return CanvasMarker(
                      position: px,
                      color: tierForRssi(p.rssiDbm).color,
                      label: '',
                      radius: 4,
                    );
                  }),
              ],
              overlay: ctrl.heatmap.currentResult != null
                  ? HeatmapOverlay(
                      result: ctrl.heatmap.currentResult!,
                      floorplan: floorplan,
                    )
                  : null,
              onTap: (pixelPos) {
                // Let user manually anchor their position.
                final meters = floorplan.pixelsToMeters(pixelPos);
                ctrl.applyManualAnchor(meters);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls(ThemeData theme, ScanController controller) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                if (await _onWillPop() && mounted) context.pop();
              },
              icon: const Icon(Icons.close),
              label: const Text('Discard'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: (controller.session?.sampleCount ?? 0) >= 3
                  ? _finishScan
                  : null,
              icon: const Icon(Icons.check_circle),
              label: const Text('Finish Scan'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SampleCounter extends StatelessWidget {
  final int count;
  const _SampleCounter({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3)),
      ),
      child: Text(
        '$count pts',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }
}
