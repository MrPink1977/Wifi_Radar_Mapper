import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';

import '../utils/constants.dart';

/// Current dead-reckoning position estimate.
class PositionEstimate {
  final double x; // metres from anchor
  final double y;
  final double headingDeg;
  final double confidence; // 0.0–1.0, decreases with drift over time
  final int totalSteps;

  const PositionEstimate({
    required this.x,
    required this.y,
    required this.headingDeg,
    required this.confidence,
    required this.totalSteps,
  });

  PositionEstimate copyWith({
    double? x,
    double? y,
    double? headingDeg,
    double? confidence,
    int? totalSteps,
  }) =>
      PositionEstimate(
        x: x ?? this.x,
        y: y ?? this.y,
        headingDeg: headingDeg ?? this.headingDeg,
        confidence: confidence ?? this.confidence,
        totalSteps: totalSteps ?? this.totalSteps,
      );
}

/// Fuses accelerometer, gyroscope, and compass data to estimate the user's
/// position during a scan session (dead reckoning).
///
/// Heading source priority:
///   1. Compass (flutter_compass) provides absolute magnetic north reference.
///   2. Gyroscope Y-axis (yaw when phone held upright in portrait) tracks
///      heading changes between compass events at high frequency.
///
/// This ensures heading updates on every step even if the compass fires slowly
/// or is unavailable (no magnetometer on device).
class MotionService extends ChangeNotifier {
  PositionEstimate _position = const PositionEstimate(
    x: 0,
    y: 0,
    headingDeg: 0,
    confidence: 1.0,
    totalSteps: 0,
  );

  PositionEstimate get position => _position;

  // Subscriptions
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // Step detection state
  static const double _stepThreshold = 11.0; // m/s²
  static const double _stepCooldownMs = 300;
  double _prevMagnitude = 0;
  DateTime? _lastStepTime;
  int _stepCount = 0;

  /// Approximate steps per second based on total steps and elapsed scan time.
  double get stepsPerSecond {
    if (_startTime == null || _stepCount == 0) return 0.0;
    final elapsed =
        DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
    if (elapsed < 2.0) return 0.0;
    return _stepCount / elapsed;
  }

  // Heading
  double _headingDeg = 0;
  DateTime? _lastGyroTime;
  bool _compassAvailable = false;

  /// Whether the heading is coming from an absolute compass source.
  bool get compassAvailable => _compassAvailable;

  // Drift tracking
  DateTime? _startTime;
  static const double _confidenceDecayRate = 0.002; // per second

  bool _isRunning = false;

  /// Reset position to the origin (call when user sets the start anchor).
  void resetToOrigin() {
    _stepCount = 0;
    _startTime = DateTime.now();
    _lastGyroTime = DateTime.now();
    _position = const PositionEstimate(
      x: 0,
      y: 0,
      headingDeg: 0,
      confidence: 1.0,
      totalSteps: 0,
    );
    notifyListeners();
  }

  /// Apply a manual correction anchor at a known real-world position.
  /// Also resets the gyro integration reference to avoid dt spikes.
  void correctPosition(double x, double y) {
    _position = _position.copyWith(x: x, y: y, confidence: 1.0);
    _startTime = DateTime.now(); // reset drift timer
    _lastGyroTime = DateTime.now(); // reset gyro dt to avoid large spike
    notifyListeners();
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _startTime = DateTime.now();
    _lastGyroTime = DateTime.now();
    _subscribeAccelerometer();
    _subscribeGyroscope();
    _subscribeCompass();
  }

  void stop() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _compassSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _compassSub = null;
    _isRunning = false;
  }

  void _subscribeAccelerometer() {
    _accelSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);

      // Simple peak detection for step events.
      if (_prevMagnitude < _stepThreshold && magnitude >= _stepThreshold) {
        _onStep();
      }
      _prevMagnitude = magnitude;
    });
  }

  /// Subscribe to the gyroscope for continuous heading tracking.
  ///
  /// Uses the device Y-axis (vertical when phone held upright in portrait).
  /// Positive Y = turning left (CCW from above) → decreasing heading.
  /// Negative Y = turning right (CW from above) → increasing heading.
  void _subscribeGyroscope() {
    _gyroSub = gyroscopeEventStream().listen((event) {
      final now = DateTime.now();
      if (_lastGyroTime != null) {
        final dt = now.difference(_lastGyroTime!).inMicroseconds / 1e6;
        // Clamp dt to avoid large jumps after pauses.
        final clampedDt = dt.clamp(0.0, 0.1);
        // event.y = yaw rate (rad/s) when phone upright in portrait.
        // Negate: positive Y (left turn) decreases heading toward 0/north.
        final deltaHeading = -event.y * clampedDt * (180.0 / pi);
        _headingDeg = (_headingDeg + deltaHeading) % 360.0;
        if (_headingDeg < 0) _headingDeg += 360.0;
        _position = _position.copyWith(headingDeg: _headingDeg);
        notifyListeners();
      }
      _lastGyroTime = now;
    });
  }

  /// Subscribe to the compass for absolute heading corrections.
  ///
  /// When compass data is available it overrides the accumulated gyro heading,
  /// preventing long-term drift.
  void _subscribeCompass() {
    final stream = FlutterCompass.events;
    if (stream == null) return;
    _compassSub = stream.listen((event) {
      if (event.heading != null) {
        _headingDeg = event.heading!;
        _compassAvailable = true;
        // Reset gyro reference time so the next gyro integration starts
        // cleanly from the compass-corrected heading.
        _lastGyroTime = DateTime.now();
        _position = _position.copyWith(headingDeg: _headingDeg);
        notifyListeners();
      }
    });
  }

  void _onStep() {
    final now = DateTime.now();

    // Enforce cooldown to avoid double-counting.
    if (_lastStepTime != null &&
        now.difference(_lastStepTime!).inMilliseconds < _stepCooldownMs) {
      return;
    }
    _lastStepTime = now;
    _stepCount++;

    // Advance position by one stride in the CURRENT heading direction.
    // _headingDeg is updated continuously by gyroscope (and compass when
    // available), so this reads the correct heading at each step.
    final rad = _headingDeg * pi / 180.0;
    final dx = kDefaultStrideMeters * sin(rad);
    final dy = -kDefaultStrideMeters * cos(rad); // negative: up = north

    // Decay confidence with elapsed time.
    final elapsed = _startTime != null
        ? now.difference(_startTime!).inSeconds.toDouble()
        : 0.0;
    final confidence =
        (1.0 - elapsed * _confidenceDecayRate).clamp(0.1, 1.0);

    _position = _position.copyWith(
      x: _position.x + dx,
      y: _position.y + dy,
      confidence: confidence,
      totalSteps: _stepCount,
    );

    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
