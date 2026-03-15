import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/floorplan.dart';
import '../services/scan_controller.dart';
import '../services/signal_service.dart';
import '../services/storage_service.dart';
import '../widgets/floorplan_canvas.dart';

const _uuid = Uuid();

enum _SetupStep { uploadFloorplan, calibrate, setRouterAnchor, ready }

class FloorplanSetupScreen extends StatefulWidget {
  final String projectId;
  const FloorplanSetupScreen({super.key, required this.projectId});

  @override
  State<FloorplanSetupScreen> createState() => _FloorplanSetupScreenState();
}

class _FloorplanSetupScreenState extends State<FloorplanSetupScreen> {
  _SetupStep _step = _SetupStep.uploadFloorplan;
  Floorplan? _floorplan;
  String? _imagePath;

  // Calibration
  Offset? _calPoint1;
  Offset? _calPoint2;
  final _distanceController = TextEditingController(text: '16.0');
  bool _useFeet = true; // default; overridden from locale in didChangeDependencies

  // Router anchor
  Offset? _routerAnchorPixels;

  final _picker = ImagePicker();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Set unit default once from device locale.
    final locale = Localizations.localeOf(context);
    final shouldUseFeet = locale.countryCode == 'US';
    if (shouldUseFeet != _useFeet) {
      setState(() {
        _useFeet = shouldUseFeet;
        _distanceController.text = _useFeet ? '16.0' : '5.0';
      });
    }
  }

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final file = await _picker.pickImage(source: source, imageQuality: 90);
    if (file == null) return;

    final docDir = await getApplicationDocumentsDirectory();
    final dest = p.join(docDir.path, 'floorplans', '${_uuid.v4()}.jpg');
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(file.path).copy(dest);

    final storage = context.read<StorageService>();
    final projects = await storage.loadProjects();
    final project = projects.firstWhere((pr) => pr.id == widget.projectId);
    var floorplan = await storage.loadFloorplan(project.floorplanId);
    floorplan ??= Floorplan(id: project.floorplanId, imagePath: dest);
    if (floorplan.imagePath != dest) {
      floorplan = Floorplan(
        id: project.floorplanId,
        imagePath: dest,
        anchorPoints: [],
      );
    }
    await storage.saveFloorplan(floorplan);

    setState(() {
      _imagePath = dest;
      _floorplan = floorplan;
      _step = _SetupStep.calibrate;
    });
  }

  void _onCalibrationTap(Offset pixelPosition) {
    setState(() {
      if (_calPoint1 == null) {
        _calPoint1 = pixelPosition;
      } else if (_calPoint2 == null) {
        _calPoint2 = pixelPosition;
      } else {
        _calPoint1 = pixelPosition;
        _calPoint2 = null;
      }
    });
  }

  Future<void> _applyCalibration() async {
    if (_calPoint1 == null || _calPoint2 == null || _floorplan == null) return;
    final rawInput = double.tryParse(_distanceController.text) ??
        (_useFeet ? 16.0 : 5.0);
    // Always store/calculate in metres internally.
    final distMeters = _useFeet ? rawInput * 0.3048 : rawInput;

    final a = AnchorPoint(
        id: 'cal_a', position: _calPoint1!, realWorldX: 0, realWorldY: 0);
    final b = AnchorPoint(
        id: 'cal_b',
        position: _calPoint2!,
        realWorldX: distMeters,
        realWorldY: 0);

    _floorplan!.anchorPoints = [a, b];
    _floorplan!.calibrateScale(a, b, distMeters);

    await context.read<StorageService>().saveFloorplan(_floorplan!);
    setState(() => _step = _SetupStep.setRouterAnchor);
  }

  void _onRouterAnchorTap(Offset pixelPosition) {
    setState(() => _routerAnchorPixels = pixelPosition);
  }

  Future<void> _startScan() async {
    if (_floorplan == null || _routerAnchorPixels == null) return;

    final signalService = context.read<SignalService>();
    await signalService.start();
    final ssid = signalService.connectedSsid ?? 'Unknown Network';

    final controller = context.read<ScanController>();
    final routerMeters = _floorplan!.pixelsToMeters(_routerAnchorPixels!);

    controller.prepare(
      floorplan: _floorplan!,
      projectId: widget.projectId,
      networkId: ssid,
      routerAnchor: routerMeters,
    );

    if (mounted) {
      context.push('/scan?sessionId=${controller.session!.id}');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stepTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step == _SetupStep.uploadFloorplan) {
              context.pop();
            } else {
              setState(() =>
                  _step = _SetupStep.values[_step.index - 1]);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildStepIndicator(),
            Expanded(child: _buildStepContent()),
          ],
        ),
      ),
    );
  }

  String get _stepTitle {
    switch (_step) {
      case _SetupStep.uploadFloorplan:
        return 'Upload Floor Plan';
      case _SetupStep.calibrate:
        return 'Calibrate Scale';
      case _SetupStep.setRouterAnchor:
        return 'Place Your Router';
      case _SetupStep.ready:
        return 'Ready to Scan';
    }
  }

  Widget _buildStepIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: _SetupStep.values.map((s) {
          final active = s.index <= _step.index;
          return Expanded(
            child: Container(
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case _SetupStep.uploadFloorplan:
        return _buildUploadStep();
      case _SetupStep.calibrate:
        return _buildCalibrateStep();
      case _SetupStep.setRouterAnchor:
        return _buildRouterAnchorStep();
      case _SetupStep.ready:
        return _buildReadyStep();
    }
  }

  // ── Step: Upload ───────────────────────────────────────────────────────────

  Widget _buildUploadStep() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  width: 2,
                  style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.surface,
            ),
            child: Column(
              children: [
                Icon(Icons.upload_file,
                    size: 64,
                    color: theme.colorScheme.primary.withOpacity(0.7)),
                const SizedBox(height: 16),
                Text('Upload your floor plan',
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Use a photo, screenshot, or hand-drawn sketch.\nAny image works.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step: Calibrate ────────────────────────────────────────────────────────

  Widget _buildCalibrateStep() {
    final theme = Theme.of(context);
    final unitLabel = _useFeet ? 'ft' : 'm';
    final bothSet = _calPoint1 != null && _calPoint2 != null;

    String instruction;
    if (_calPoint1 == null) {
      instruction = 'Tap the FIRST calibration point on your floor plan.';
    } else if (_calPoint2 == null) {
      instruction = 'Now tap the SECOND calibration point.';
    } else {
      instruction = 'Both points set. Enter the distance below.';
    }

    return Column(
      children: [
        // Explanation card
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.2)),
            ),
            child: Text(
              'Pick two points on your floor plan that you know the real '
              'distance between — for example, tap one end of a hallway '
              'and then the other. Enter how far apart they really are. '
              'This tells the app how big your space is so it can place '
              'signal readings in the right locations.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(instruction,
                    style: theme.textTheme.bodyMedium),
              ),
              const SizedBox(width: 8),
              // Feet / Meters toggle
              SegmentedButton<bool>(
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: true, label: Text('ft')),
                  ButtonSegment(value: false, label: Text('m')),
                ],
                selected: {_useFeet},
                onSelectionChanged: (v) {
                  final nowFeet = v.first;
                  if (nowFeet == _useFeet) return;
                  final current =
                      double.tryParse(_distanceController.text) ?? 0.0;
                  setState(() {
                    _useFeet = nowFeet;
                    if (_useFeet) {
                      // was meters → feet
                      _distanceController.text =
                          (current / 0.3048).toStringAsFixed(1);
                    } else {
                      // was feet → meters
                      _distanceController.text =
                          (current * 0.3048).toStringAsFixed(1);
                    }
                  });
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: FloorplanCanvas(
            imagePath: _imagePath!,
            markers: [
              if (_calPoint1 != null)
                CanvasMarker(
                    position: _calPoint1!, color: Colors.blue, label: 'A'),
              if (_calPoint2 != null)
                CanvasMarker(
                    position: _calPoint2!,
                    color: Colors.orange,
                    label: 'B'),
            ],
            lines: [
              if (_calPoint1 != null && _calPoint2 != null)
                CanvasLine(
                  from: _calPoint1!,
                  to: _calPoint2!,
                  color: Colors.white.withOpacity(0.7),
                  strokeWidth: 2.0,
                  label: '${_distanceController.text} ${_useFeet ? 'ft' : 'm'}',
                ),
            ],
            onTap: _onCalibrationTap,
          ),
        ),
        if (bothSet)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _distanceController,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Distance between A and B',
                      border: const OutlineInputBorder(),
                      suffixText: unitLabel,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: _applyCalibration,
                  child: const Text('Apply'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Step: Router Anchor ────────────────────────────────────────────────────

  Widget _buildRouterAnchorStep() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.2)),
            ),
            child: const Text(
              'Stand next to your router or main Wi-Fi node. Tap your '
              'router\'s position on the map, then tap Confirm. We will '
              'record signal strength as you walk and build your coverage '
              'map in real time.',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            _routerAnchorPixels == null
                ? 'Tap where your router is on the floor plan.'
                : 'Router placed. Stand next to it in real life, then tap Confirm.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: FloorplanCanvas(
            imagePath: _imagePath!,
            markers: [
              if (_routerAnchorPixels != null)
                CanvasMarker(
                  position: _routerAnchorPixels!,
                  color: const Color(0xFF2196F3),
                  label: 'R',
                  radius: 14,
                ),
            ],
            onTap: _onRouterAnchorTap,
          ),
        ),
        if (_routerAnchorPixels != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    setState(() => _step = _SetupStep.ready),
                icon: const Icon(Icons.wifi),
                label: const Text('Confirm Router Position'),
              ),
            ),
          ),
      ],
    );
  }

  // ── Step: Ready ────────────────────────────────────────────────────────────

  Widget _buildReadyStep() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.play_circle_outline,
              size: 80, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text('Ready to scan!', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 16),
          _Tip(
            icon: Icons.directions_walk,
            text: 'Walk slowly and steadily through your space.',
          ),
          _Tip(
            icon: Icons.phone_android,
            text: 'Hold the phone at chest height.',
          ),
          _Tip(
            icon: Icons.pause_circle_outline,
            text: 'Pause briefly at corners and room boundaries.',
          ),
          _Tip(
            icon: Icons.refresh,
            text: 'You can scan multiple times to build confidence.',
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.wifi_find),
              label: const Text('BEGIN SCAN'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Tip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
        ],
      ),
    );
  }
}
