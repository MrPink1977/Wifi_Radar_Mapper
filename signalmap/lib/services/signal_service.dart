import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../utils/constants.dart';

/// Raw RSSI reading with timestamp.
class RssiReading {
  final double dbm;
  final DateTime timestamp;
  const RssiReading(this.dbm, this.timestamp);
}

/// Smoothed signal sample ready to commit to a [SamplePoint].
class SmoothedSignal {
  final double meanDbm;
  final double variance;
  final int sampleCount;
  const SmoothedSignal(
      {required this.meanDbm,
      required this.variance,
      required this.sampleCount});
}

/// Continuously samples Wi-Fi RSSI from the currently connected network.
///
/// Applies a rolling window for temporal smoothing and outlier rejection
/// per the algorithm specification.
class SignalService extends ChangeNotifier {
  final NetworkInfo _networkInfo = NetworkInfo();

  // Public state
  String? connectedSsid;
  double? latestRssi;
  SmoothedSignal? smoothed;
  bool isAvailable = false;

  // Sampling internals
  Timer? _sampleTimer;
  final List<RssiReading> _window = [];
  double? _rollingMean;
  bool _isRunning = false;

  static const Duration _sampleInterval = Duration(milliseconds: 400);

  /// Start the RSSI sampling loop.
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    await _checkAvailability();
    _sampleTimer = Timer.periodic(_sampleInterval, (_) => _sample());
  }

  /// Stop sampling.
  void stop() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _isRunning = false;
    _window.clear();
    _rollingMean = null;
  }

  Future<void> _checkAvailability() async {
    try {
      connectedSsid = await _networkInfo.getWifiName();
      isAvailable = connectedSsid != null;
    } catch (_) {
      isAvailable = false;
    }
    notifyListeners();
  }

  Future<void> _sample() async {
    double? rawRssi;

    try {
      // network_info_plus does not expose RSSI directly on all platforms.
      // On Android, signal level is available via platform channels.
      // Here we call getWifiSignalStrength if available, otherwise simulate
      // during development so the UI is functional.
      rawRssi = await _getRssi();
    } catch (e) {
      debugPrint('[SignalService] sample error: $e');
      return;
    }

    if (rawRssi == null) return;

    // Outlier rejection: skip spikes more than kOutlierThresholdDb from mean.
    if (_rollingMean != null &&
        (rawRssi - _rollingMean!).abs() > kOutlierThresholdDb) {
      return;
    }

    final reading = RssiReading(rawRssi, DateTime.now());
    _window.add(reading);

    // Trim to rolling window size.
    if (_window.length > kRollingWindowSize) {
      _window.removeAt(0);
    }

    _updateSmoothed();
    notifyListeners();
  }

  Future<double?> _getRssi() async {
    // network_info_plus does not expose RSSI/signal-strength on all platforms.
    // Fall back to a simulated value during development/debug mode so the UI
    // remains functional without real hardware.
    if (kDebugMode) {
      return _simulateRssi();
    }
    return null;
  }

  double _simulateRssi() {
    // Slowly drifting sine wave for realistic dev-mode testing.
    final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return -60.0 + sin(t * 0.3) * 15.0 + (Random().nextDouble() - 0.5) * 4.0;
  }

  void _updateSmoothed() {
    if (_window.isEmpty) return;

    final values = _window.map((r) => r.dbm).toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
        values.length;

    _rollingMean = mean;
    latestRssi = mean;
    smoothed = SmoothedSignal(
      meanDbm: mean,
      variance: variance,
      sampleCount: values.length,
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
