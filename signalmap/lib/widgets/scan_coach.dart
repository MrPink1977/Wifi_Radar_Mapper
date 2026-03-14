import 'package:flutter/material.dart';

import '../services/motion_service.dart';

/// Contextual coaching prompts shown during an active scan.
///
/// The coach reads the current [PositionEstimate] and sample count to
/// decide which instruction to display.
class ScanCoach extends StatelessWidget {
  final PositionEstimate position;
  final int sampleCount;

  const ScanCoach({
    super.key,
    required this.position,
    required this.sampleCount,
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
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: _color(theme)),
              ),
            ),
            // Confidence bar
            _ConfidenceBar(confidence: position.confidence),
          ],
        ),
      ),
    );
  }

  String _message() {
    if (sampleCount == 0) return 'Walk slowly through your space to collect samples.';
    if (position.confidence < 0.4) {
      return 'Position drift detected — tap your location on the map to correct.';
    }
    if (sampleCount < 5) return 'Keep going — walk to different areas of the space.';
    if (sampleCount < 15) return 'Good progress! Cover the corners and far walls.';
    if (sampleCount < 30) return 'Looking great. Make sure to scan any dead-zone areas.';
    return 'Excellent coverage! Tap "Finish Scan" when you\'re done.';
  }

  IconData _icon() {
    if (position.confidence < 0.4) return Icons.warning_amber_rounded;
    if (sampleCount == 0) return Icons.directions_walk;
    return Icons.check_circle_outline;
  }

  Color _color(ThemeData theme) {
    if (position.confidence < 0.4) return const Color(0xFFFFD600);
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
        Text(
          'GPS',
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
