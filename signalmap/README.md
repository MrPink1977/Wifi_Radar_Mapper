# SignalMap

Turn Wi-Fi signal strength into a floor-plan heatmap and device placement recommender.

## What it does

1. Upload a photo of your floor plan (or sketch).
2. Walk your space while the app records Wi-Fi RSSI measurements.
3. See a radar-style color heatmap of signal coverage.
4. Get placement recommendations for routers, mesh nodes, and IoT gateways.

## Getting started

### Prerequisites

- Flutter SDK ≥ 3.3.0
- Android device (API 26+) **or** iOS 14+ device
- Connected to a Wi-Fi network before starting a scan

### Install & run

```bash
cd signalmap
flutter pub get
flutter run
```

### Build release APK (Android)

```bash
flutter build apk --release
```

### Build release IPA (iOS)

```bash
flutter build ipa --release
```

## Architecture

```
lib/
├── main.dart               # App entry point, DI setup
├── app.dart                # Theme + routing (go_router)
├── models/                 # Data objects (Floorplan, ScanSession, SamplePoint, …)
├── services/
│   ├── signal_service.dart     # Wi-Fi RSSI sampling + rolling smoothing
│   ├── motion_service.dart     # Dead-reckoning (accel + gyro + compass)
│   ├── heatmap_service.dart    # IDW interpolation → ui.Image
│   ├── recommendation_service.dart  # Placement recommendations
│   ├── storage_service.dart    # SQLite persistence
│   └── scan_controller.dart    # Orchestrates a live scan session
├── screens/
│   ├── home_screen.dart        # Project list
│   ├── floorplan_setup_screen.dart  # Upload → calibrate → anchor → ready
│   ├── scan_screen.dart        # Live scan with real-time heatmap
│   └── results_screen.dart     # Heatmap + recommendations tabs
├── widgets/
│   ├── floorplan_canvas.dart   # Pinch-to-zoom canvas with marker overlay
│   ├── heatmap_painter.dart    # Renders the IDW heatmap image
│   ├── scan_coach.dart         # Contextual walking instructions
│   └── rssi_indicator.dart     # Live RSSI progress bar
└── utils/
    ├── constants.dart          # RSSI tiers, IDW constants
    └── interpolation.dart      # Core IDW algorithm
```

## RSSI interpretation

| Range | Tier | Color |
|---|---|---|
| -40 to -55 dBm | Excellent | Green |
| -56 to -65 dBm | Strong | Light green |
| -66 to -74 dBm | Usable | Amber |
| -75 to -85 dBm | Risky | Orange |
| Below -86 dBm | Dead zone | Red |

> "Stronger is closer to zero. -50 is stronger than -70."

## Platform notes

### Android
Full RSSI access via `WifiManager`. Location permission is required on Android 10+ to read SSID/BSSID.

### iOS
iOS restricts direct RSSI access. The app uses `NEHotspotHelper` where available. **An Apple Developer entitlement is required** for full functionality — see [Apple's documentation](https://developer.apple.com/documentation/networkextension/nehotspothelper). Basic signal level detection works without the entitlement in development.

## Contributing

See the spec documents in the parent repository for design intent and algorithm details.
