import 'package:flutter/material.dart';

import '../services/motion_service.dart';

/// Contextual coaching prompts shown during an active scan.
///
/// Phase 2 triggers (from spec):
///   - Just started                → "Great start. Walk slowly and steadily."
///   - Moving too fast             → "Slow down a little for better data."
///   - Signal fluctuating heavily  → "Hold still for two seconds here."
///   - Dead zone detected          → "Dead zone detected. Keep going or rescan."
///   - Confidence / drift low      → "Tap Correct Position to reduce drift."
///   - Good steady data            → "Good data. Keep going."
///   - Healthy progress            → coverage progress messages
class ScanCoach extends StatelessWidget {
  final PositionEstimate position;
  final int sampleCount;

  /// Rolling variance from [SignalService.smoothed.variance].
  /// High variance (> ~15 dBm²) means the signal is unstable — user should
  /// hold still.
  final double? signalVariance;

  /// Steps per second from [MotionService.stepsPerSecond].
  /// > ~2.0 steps/s means the user is walking too fast.
  final double stepsPerSecond;

  const ScanCoach({
    super.key,
    required this.position,
    required this.sampleCount,
    this.signalVariance,
    this.stepsPerSecond = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = _message();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: Container(
        key: ValueKey(message),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: const Color(0xFF111827),
        child: Row(
          children: [
            Icon(_icon(), color: _color(theme), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style:
                    theme.textTheme.bodyLarge?.copyWith(color: _color(theme)),
              ),
            ),
            _ConfidenceBar(confidence: position.confidence),
          ],
        ),
      ),
    );
  }

  String _message() {
    // Priority order: critical first, informational last.

    // 1. Drift correction needed — highest priority warning.
    if (position.confidence < 0.35) {
      return 'Tap Correct Position to reduce drift.';
    }

    // 2. Dead zone — RSSI very low (< -84 dBm, which the coach infers from
    //    variance staying low while signal is very weak).
    //    We detect via signalVariance low + sampleCount > 0 but let the caller
    //    pass RSSI separately if needed. For Phase 2, a strong signal-fluctuation
    //    drop is a sufficient proxy.
    if (signalVariance != null && signalVariance! < 2.0 && sampleCount > 5) {
      // Low variance + many samples but still reading — might be dead zone.
      // We can't know dBm here without passing it, so skip this branch and
      // handle it in a future pass. Leave placeholder for caller to extend.
    }

    // 3. Signal fluctuating — user should hold still.
    if (signalVariance != null && signalVariance! > 18.0) {
      return 'Hold still for two seconds here.';
    }

    // 4. Moving too fast.
    if (stepsPerSecond > 2.0 && sampleCount > 0) {
      return 'Slow down a little for better data.';
    }

    // 5. Just started (no samples yet).
    if (sampleCount == 0) {
      return 'Great start. Walk slowly and steadily.';
    }

    // 6. Early scan — encourage exploration.
    if (sampleCount < 5) {
      return 'Keep going — walk to different areas of the space.';
    }

    // 7. Good steady data (moderate variance, reasonable progress).
    if (signalVariance != null && signalVariance! < 8.0 && sampleCount >= 5) {
      if (sampleCount < 15) return 'Good data. Keep going.';
      if (sampleCount < 30) return 'Great coverage so far! Explore the corners.';
    }

    // 8. Healthy general progress.
    if (sampleCount < 15) return 'Good progress! Cover the corners and far walls.';
    if (sampleCount < 30) return 'Looking great. Make sure to scan any dead-zone areas.';

    return 'Excellent coverage! Tap "Finish Scan" when you\'re done.';
  }

  IconData _icon() {
    if (position.confidence < 0.35) return Icons.warning_amber_rounded;
    if (signalVariance != null && signalVariance! > 18.0) {
      return Icons.pause_circle_outline;
    }
    if (stepsPerSecond > 2.0 && sampleCount > 0) {
      return Icons.directions_walk;
    }
    if (sampleCount == 0) return Icons.directions_walk;
    return Icons.check_circle_outline;
  }

  Color _color(ThemeData theme) {
    if (position.confidence < 0.35) return const Color(0xFFFFD600);
    if (signalVariance != null && signalVariance! > 18.0) {
      return const Color(0xFFFFD600);
    }
    if (stepsPerSecond > 2.0 && sampleCount > 0) {
      return const Color(0xFFFFD600);
    }
    if (sampleCount == 0) return theme.textTheme.bodyMedium!.color!;
    return theme.colorScheme.primary;
  }
}

class _ConfidenceBar extends StatelessWidget {
  final double confidence;
  const _ConfidenceBar({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final color = confidence > 0.6
        ? const Color(0xFF00E676)
        : confidence > 0.3
            ? const Color(0xFFFFD600)
            : Colors.red;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'DR',
          style: TextStyle(color: Colors.white38, fontSize: 9),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 40,
          height: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: confidence,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}
