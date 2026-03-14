import 'package:flutter/material.dart';

import '../utils/constants.dart';

/// Live RSSI bar shown at the top of the scan screen.
class RssiIndicator extends StatelessWidget {
  final double? rssiDbm;
  final String? ssid;

  const RssiIndicator({super.key, this.rssiDbm, this.ssid});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (rssiDbm == null) {
      return _buildNoSignal(theme);
    }

    final tier = tierForRssi(rssiDbm!);
    final normalised = normaliseRssi(rssiDbm!);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: const Color(0xFF0A0E1A),
      child: Row(
        children: [
          // Signal bars icon
          Icon(Icons.signal_wifi_4_bar, color: tier.color, size: 20),
          const SizedBox(width: 10),
          // Animated bar
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      ssid ?? 'Wi-Fi',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${rssiDbm!.toStringAsFixed(0)} dBm  •  ${tier.label}',
                      style: TextStyle(
                        color: tier.color,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: normalised,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation(tier.color),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoSignal(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: const Color(0xFF0A0E1A),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, color: Colors.red, size: 20),
          const SizedBox(width: 10),
          Text(
            'No Wi-Fi signal detected',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red),
          ),
        ],
      ),
    );
  }
}
