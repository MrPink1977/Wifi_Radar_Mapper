import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/home_screen.dart';
import 'screens/floorplan_setup_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/results_screen.dart';

class SignalMapApp extends StatelessWidget {
  const SignalMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SignalMap',
      theme: _buildTheme(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }

  ThemeData _buildTheme() {
    const primaryGreen = Color(0xFF00E676);
    const darkBg = Color(0xFF0A0E1A);
    const surfaceDark = Color(0xFF111827);
    const cardDark = Color(0xFF1F2937);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: primaryGreen,
        secondary: Color(0xFF76FF03),
        surface: surfaceDark,
        onPrimary: Colors.black,
        onSecondary: Colors.black,
      ),
      scaffoldBackgroundColor: darkBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBg,
        foregroundColor: primaryGreen,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: primaryGreen,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
      cardTheme: const CardThemeData(
        color: cardDark,
        elevation: 2,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryGreen,
          side: const BorderSide(color: primaryGreen),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 28),
        headlineMedium: TextStyle(
            color: Colors.white, fontWeight: FontWeight.w600, fontSize: 22),
        titleLarge: TextStyle(color: Colors.white, fontSize: 18),
        titleMedium: TextStyle(color: primaryGreen, fontSize: 15),
        bodyLarge: TextStyle(color: Color(0xFFD1D5DB)),
        bodyMedium: TextStyle(color: Color(0xFF9CA3AF)),
        labelLarge: TextStyle(
            color: primaryGreen, fontWeight: FontWeight.w600, fontSize: 14),
      ),
    );
  }
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => const HomeScreen(),
    ),
    GoRoute(
      path: '/setup',
      builder: (context, state) {
        final projectId = state.uri.queryParameters['projectId'] ?? '';
        return FloorplanSetupScreen(projectId: projectId);
      },
    ),
    GoRoute(
      path: '/scan',
      builder: (context, state) {
        final sessionId = state.uri.queryParameters['sessionId'] ?? '';
        return ScanScreen(sessionId: sessionId);
      },
    ),
    GoRoute(
      path: '/results',
      builder: (context, state) {
        final sessionId = state.uri.queryParameters['sessionId'] ?? '';
        return ResultsScreen(sessionId: sessionId);
      },
    ),
  ],
);
