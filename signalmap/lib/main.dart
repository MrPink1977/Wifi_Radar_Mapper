import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/heatmap_service.dart';
import 'services/motion_service.dart';
import 'services/scan_controller.dart';
import 'services/signal_service.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = StorageService();
  await storage.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider(create: (_) => SignalService()),
        ChangeNotifierProvider(create: (_) => MotionService()),
        ChangeNotifierProvider(create: (_) => HeatmapService()),
        ChangeNotifierProxyProvider3<SignalService, MotionService,
            HeatmapService, ScanController>(
          create: (ctx) => ScanController(
            signal: ctx.read<SignalService>(),
            motion: ctx.read<MotionService>(),
            heatmap: ctx.read<HeatmapService>(),
            storage: ctx.read<StorageService>(),
          ),
          update: (_, signal, motion, heatmap, prev) =>
              prev ??
              ScanController(
                signal: signal,
                motion: motion,
                heatmap: heatmap,
                storage: _.read<StorageService>(),
              ),
        ),
      ],
      child: const SignalMapApp(),
    ),
  );
}
