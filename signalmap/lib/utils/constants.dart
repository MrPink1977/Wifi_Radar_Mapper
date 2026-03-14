import 'dart:ui';

/// RSSI interpretation tiers per the product specification.
class RssiTier {
  final String label;
  final String description;
  final Color color;
  final double minDbm;
  final double maxDbm;

  const RssiTier({
    required this.label,
    required this.description,
    required this.color,
    required this.minDbm,
    required this.maxDbm,
  });

  bool contains(double dbm) => dbm >= minDbm && dbm <= maxDbm;
}

const List<RssiTier> rssiTiers = [
  RssiTier(
    label: 'Excellent',
    description: 'Very strong signal. Ideal for critical devices.',
    color: Color(0xFF00E676), // bright green
    minDbm: -55,
    maxDbm: -40,
  ),
  RssiTier(
    label: 'Strong',
    description: 'Reliable for routers, gateways, cameras, and most IoT.',
    color: Color(0xFF76FF03), // light green
    minDbm: -65,
    maxDbm: -56,
  ),
  RssiTier(
    label: 'Usable',
    description: 'Generally workable, less tolerant of interference.',
    color: Color(0xFFFFD600), // amber
    minDbm: -74,
    maxDbm: -66,
  ),
  RssiTier(
    label: 'Risky',
    description: 'Likely to produce instability or retries.',
    color: Color(0xFFFF6D00), // orange
    minDbm: -85,
    maxDbm: -75,
  ),
  RssiTier(
    label: 'Dead Zone',
    description: 'Connection may fail outright or behave unreliably.',
    color: Color(0xFFD50000), // red
    minDbm: -120,
    maxDbm: -86,
  ),
];

RssiTier tierForRssi(double dbm) {
  for (final tier in rssiTiers) {
    if (tier.contains(dbm)) return tier;
  }
  return rssiTiers.last;
}

/// Normalise an RSSI value to 0.0 (dead) → 1.0 (excellent).
double normaliseRssi(double dbm) {
  const min = -100.0;
  const max = -30.0;
  return ((dbm - min) / (max - min)).clamp(0.0, 1.0);
}

/// Heatmap interpolation constants.
const double kDefaultInfluenceRadiusMeters = 3.0; // max IDW influence radius
const double kMinSampleDensityForFullConfidence = 4; // points within radius
const int kRollingWindowSize = 8; // samples for temporal smoothing
const double kOutlierThresholdDb = 10.0; // reject spikes above this delta
const double kCommitDistanceMeters = 0.5; // min travel before next commit
const double kCommitDwellSeconds = 1.5; // min dwell time before commit

/// Dead reckoning constants.
const double kDefaultStrideMeters = 0.75;
const double kDriftCorrectionIntervalSeconds = 30.0;
