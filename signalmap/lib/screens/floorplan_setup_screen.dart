import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/floorplan.dart';
import '../models/scan_session.dart';
import '../services/scan_controller.dart';
import '../services/signal_service.dart';
import '../services/storage_service.dart';
import '../widgets/floorplan_canvas.dart';

const _uuid = Uuid();

enum _SetupStep { uploadFloorplan, calibrate, setAnchor, ready }

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
  final _distanceController = TextEditingController(text: '5.0');

  // Start anchor
  Offset? _startAnchorPixels;

  final _picker = ImagePicker();

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final file = await _picker.pickImage(source: source, imageQuality: 90);
    if (file == null) return;

    // Copy to app documents so the path is stable.
    final docDir = await getApplicationDocumentsDirectory();
    final dest = p.join(docDir.path, 'floorplans', '${_uuid.v4()}.jpg');
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(file.path).copy(dest);

    final storage = context.read<StorageService>();

    // Load existing floorplan for this project or create a fresh one.
    final projects = await storage.loadProjects();
    final project = projects.firstWhere((pr) => pr.id == widget.projectId);
    var floorplan = await storage.loadFloorplan(project.floorplanId);
    floorplan ??= Floorplan(id: project.floorplanId, imagePath: dest);
    floorplan.imagePath != dest
        ? floorplan = Floorplan(
            id: project.floorplanId,
            imagePath: dest,
            anchorPoints: [],
          )
        : null;

    await storage.saveFloorplan(floorplan!);

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
    final dist = double.tryParse(_distanceController.text) ?? 5.0;

    final a = AnchorPoint(
        id: 'cal_a', position: _calPoint1!, realWorldX: 0, realWorldY: 0);
    final b = AnchorPoint(
        id: 'cal_b',
        position: _calPoint2!,
        realWorldX: dist,
        realWorldY: 0);

    _floorplan!.anchorPoints = [a, b];
    _floorplan!.calibrateScale(a, b, dist);

    await context.read<StorageService>().saveFloorplan(_floorplan!);
    setState(() => _step = _SetupStep.setAnchor);
  }

  void _onAnchorTap(Offset pixelPosition) {
    setState(() => _startAnchorPixels = pixelPosition);
  }

  Future<void> _startScan() async {
    if (_floorplan == null || _startAnchorPixels == null) return;

    final signalService = context.read<SignalService>();
    await signalService.start();
    final ssid = signalService.connectedSsid ?? 'Unknown Network';

    final controller = context.read<ScanController>();
    controller.prepare(
      floorplan: _floorplan!,
      projectId: widget.projectId,
      networkId: ssid,
    );

    // Apply the start anchor position.
    final startMeters = _floorplan!.pixelsToMeters(_startAnchorPixels!);
    controller.motion.correctPosition(startMeters.dx, startMeters.dy);

    if (mounted) {
      context.push('/scan?sessionId=${controller.session!.id}');
    }
  }

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
              setState(() {
                _step = _SetupStep.values[_step.index - 1];
              });
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
      case _SetupStep.setAnchor:
        return 'Set Start Point';
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
      case _SetupStep.setAnchor:
        return _buildAnchorStep();
      case _SetupStep.ready:
        return _buildReadyStep();
    }
  }

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
                    size: 64, color: theme.colorScheme.primary.withOpacity(0.7)),
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

  Widget _buildCalibrateStep() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Text(
            _calPoint1 == null
                ? 'Tap the FIRST calibration point on your floor plan.'
                : _calPoint2 == null
                    ? 'Now tap the SECOND calibration point.'
                    : 'Both points set. Enter the real-world distance below.',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
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
                    position: _calPoint2!, color: Colors.orange, label: 'B'),
            ],
            onTap: _onCalibrationTap,
          ),
        ),
        if (_calPoint1 != null && _calPoint2 != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _distanceController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Distance between A and B (metres)',
                      border: OutlineInputBorder(),
                      suffixText: 'm',
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

  Widget _buildAnchorStep() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Text(
            _startAnchorPixels == null
                ? 'Tap where you will START your scan walk on the floor plan.'
                : 'Start point set! Move to that spot in real life, then tap Next.',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: FloorplanCanvas(
            imagePath: _imagePath!,
            markers: [
              if (_startAnchorPixels != null)
                CanvasMarker(
                  position: _startAnchorPixels!,
                  color: Theme.of(context).colorScheme.primary,
                  label: 'START',
                ),
            ],
            onTap: _onAnchorTap,
          ),
        ),
        if (_startAnchorPixels != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => setState(() => _step = _SetupStep.ready),
                icon: const Icon(Icons.check),
                label: const Text('Confirm Start Point'),
              ),
            ),
          ),
      ],
    );
  }

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
            text:
                'You can scan multiple times to build confidence.',
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.wifi_find),
              label: const Text('START SCANNING'),
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
