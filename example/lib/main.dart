import 'package:flutter/material.dart';

import 'device_discovery_page.dart';

void main() {
  runApp(const DartCastExampleApp());
}

/// Root widget for the dart_cast example application.
///
/// Demonstrates how to integrate dart_cast into a Flutter app for
/// discovering and casting media to Chromecast, AirPlay, and DLNA devices.
class DartCastExampleApp extends StatelessWidget {
  const DartCastExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart_cast Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const DeviceDiscoveryPage(),
    );
  }
}
