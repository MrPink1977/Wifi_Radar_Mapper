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
/// Strategy (from spec):
///   - Start from a known user-selected anchor.
///   - Step detection via accelerometer magnitude peak detection.
///   - Heading from compass (first) and gyroscope integration (fallback).
///   - Confidence decays with time and step count; user can correct via
///     manual anchor taps.
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
  StreamSubscription<CompassEvent>? _compassSub;

  // Step detection state
  static const double _stepThreshold = 11.0; // m/s²
  static const double _stepCooldownMs = 300;
  double _prevMagnitude = 0;
  DateTime? _lastStepTime;
  int _stepCount = 0;

  // Heading
  double _headingDeg = 0;

  // Drift tracking
  DateTime? _startTime;
  static const double _confidenceDecayRate = 0.002; // per second

  bool _isRunning = false;

  /// Reset position to the origin (call when user sets the start anchor).
  void resetToOrigin() {
    _stepCount = 0;
    _startTime = DateTime.now();
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
  void correctPosition(double x, double y) {
    _position = _position.copyWith(x: x, y: y, confidence: 1.0);
    _startTime = DateTime.now(); // reset drift timer
    notifyListeners();
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _startTime = DateTime.now();
    _subscribeAccelerometer();
    _subscribeCompass();
  }

  void stop() {
    _accelSub?.cancel();
    _compassSub?.cancel();
    _accelSub = null;
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

  void _subscribeCompass() {
    final stream = FlutterCompass.events;
    if (stream == null) return;
    _compassSub = stream.listen((event) {
      if (event.heading != null) {
        _headingDeg = event.heading!;
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

    // Advance position by one stride in current heading direction.
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
