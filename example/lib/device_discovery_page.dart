import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';

import 'remote_control_page.dart';

/// Main page that handles device discovery and connection.
///
/// Demonstrates:
/// - Creating a [CastService] with discovery providers
/// - Starting/stopping device discovery
/// - Displaying discovered devices grouped by protocol
/// - Connecting to a device and navigating to the remote control
class DeviceDiscoveryPage extends StatefulWidget {
  const DeviceDiscoveryPage({super.key});

  @override
  State<DeviceDiscoveryPage> createState() => _DeviceDiscoveryPageState();
}

class _DeviceDiscoveryPageState extends State<DeviceDiscoveryPage> {
  /// The main entry point for dart_cast. Create one per app lifecycle.
  late final CastService _castService;

  List<CastDevice> _devices = [];
  bool _isDiscovering = false;
  StreamSubscription<List<CastDevice>>? _discoverySub;

  @override
  void initState() {
    super.initState();

    // Initialize CastService with all three discovery providers.
    // Each provider scans for its respective protocol on the local network.
    //
    // The sessionFactory creates protocol-specific sessions based on the
    // device's protocol. Each protocol has its own session class:
    //   - ChromecastSession: uses TLS + Cast V2 protocol
    //   - AirPlaySession: uses HTTP-based AirPlay protocol
    //   - DlnaSession: uses SOAP/UPnP (requires a DlnaDeviceDescription)
    //
    // For simplicity, this demo creates Chromecast and AirPlay sessions
    // directly. DLNA requires fetching the device description first, which
    // is handled in _connectToDevice below.
    _castService = CastService(
      discoveryProviders: [
        ChromecastDiscoveryProvider(),
        AirPlayDiscoveryProvider(),
        DlnaDiscoveryProvider(),
      ],
      sessionFactory: (device) {
        switch (device.protocol) {
          case CastProtocol.chromecast:
            return ChromecastSession(device: device);
          case CastProtocol.airplay:
            return AirPlaySession(device);
          case CastProtocol.dlna:
            // DLNA sessions need a device description. When using the
            // sessionFactory, you can provide a minimal description.
            // In production, fetch the full description via
            // DlnaDeviceDescription.fetch() before creating the session.
            throw StateError(
              'DLNA devices require description. '
              'Use direct session creation instead.',
            );
        }
      },
    );
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    // Always dispose the CastService to release network resources.
    _castService.dispose();
    super.dispose();
  }

  /// Starts device discovery and shows results in a bottom sheet.
  void _startDiscovery() {
    setState(() {
      _isDiscovering = true;
      _devices = [];
    });

    _showDeviceSheet();

    // startDiscovery() returns a stream that emits updated device lists
    // as new devices are found on the network. The stream completes
    // after the timeout (default 10 seconds).
    _discoverySub?.cancel();
    _discoverySub = _castService
        .startDiscovery(timeout: const Duration(seconds: 15))
        .listen(
      (devices) {
        setState(() => _devices = devices);
      },
      onDone: () {
        setState(() => _isDiscovering = false);
      },
      onError: (Object error) {
        setState(() => _isDiscovering = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Discovery error: $error')),
          );
        }
      },
    );
  }

  /// Stops an active discovery scan.
  void _stopDiscovery() {
    _discoverySub?.cancel();
    _castService.stopDiscovery();
    setState(() => _isDiscovering = false);
  }

  /// Connects to the selected device and navigates to the remote control page.
  ///
  /// For DLNA devices, we first fetch the device description XML, then
  /// create the session manually. For other protocols, we use the
  /// CastService.connect() convenience method.
  Future<void> _connectToDevice(CastDevice device) async {
    // Close the bottom sheet before navigating.
    if (mounted) Navigator.of(context).pop();

    try {
      CastSession session;

      if (device.protocol == CastProtocol.dlna) {
        // DLNA requires fetching the device description XML first.
        // The description contains AVTransport and RenderingControl URLs
        // needed for SOAP-based playback control.
        final locationUrl = device.metadata['location'] ?? '';
        final description = DlnaDeviceDescription(
          friendlyName: device.name,
          udn: device.id,
          locationUrl: locationUrl,
          avTransportControlUrl:
              device.metadata['avTransportControlUrl'],
          renderingControlUrl:
              device.metadata['renderingControlUrl'],
        );
        session = DlnaSession(device: device, description: description);
      } else {
        // For Chromecast and AirPlay, CastService.connect() uses the
        // sessionFactory to create the appropriate session.
        session = await _castService.connect(device);
      }

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RemoteControlPage(
              session: session,
              device: device,
              castService: _castService,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  /// Shows a modal bottom sheet with discovered devices.
  void _showDeviceSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        // Use StatefulBuilder so the bottom sheet updates as devices arrive.
        return StatefulBuilder(
          builder: (context, setSheetState) {
            // Keep the sheet in sync with the page state by rebuilding
            // when the parent setState is called.
            // We achieve this by reading _devices and _isDiscovering directly.
            return _DeviceListSheet(
              devices: _devices,
              isDiscovering: _isDiscovering,
              onDeviceTap: _connectToDevice,
              onStop: _stopDiscovery,
            );
          },
        );
      },
    ).then((_) {
      // If the sheet is dismissed, stop discovery.
      if (_isDiscovering) _stopDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dart_cast Demo'),
        actions: [
          // Log viewer button
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: 'View logs',
            onPressed: () => Navigator.of(context).pushNamed('/logs'),
          ),
          // Cast button in the AppBar — the standard UX pattern.
          IconButton(
            icon: Icon(
              _isDiscovering ? Icons.cast_connected : Icons.cast,
            ),
            tooltip: 'Discover devices',
            onPressed: _startDiscovery,
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cast,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'dart_cast Demo',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Tap the cast icon above to discover\n'
                'Chromecast, AirPlay, and DLNA devices\n'
                'on your local network.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _startDiscovery,
                icon: const Icon(Icons.search),
                label: const Text('Start Discovery'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Internal widget for the device list bottom sheet.
class _DeviceListSheet extends StatelessWidget {
  final List<CastDevice> devices;
  final bool isDiscovering;
  final ValueChanged<CastDevice> onDeviceTap;
  final VoidCallback onStop;

  const _DeviceListSheet({
    required this.devices,
    required this.isDiscovering,
    required this.onDeviceTap,
    required this.onStop,
  });

  /// Returns an icon for each protocol type.
  IconData _protocolIcon(CastProtocol protocol) {
    switch (protocol) {
      case CastProtocol.chromecast:
        return Icons.cast;
      case CastProtocol.airplay:
        return Icons.airplay;
      case CastProtocol.dlna:
        return Icons.devices_other;
    }
  }

  /// Groups devices by their protocol for organized display.
  Map<CastProtocol, List<CastDevice>> _groupByProtocol() {
    final grouped = <CastProtocol, List<CastDevice>>{};
    for (final device in devices) {
      grouped.putIfAbsent(device.protocol, () => []).add(device);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByProtocol();

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    'Devices',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (isDiscovering)
                    TextButton(
                      onPressed: onStop,
                      child: const Text('Stop'),
                    ),
                ],
              ),
            ),
            if (isDiscovering)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: LinearProgressIndicator(),
              ),
            // Device list
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Text(
                        isDiscovering
                            ? 'Searching for devices...'
                            : 'No devices found.\nMake sure you are on the same network\nas your cast devices.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _buildItems(grouped).length,
                      itemBuilder: (context, index) {
                        return _buildItems(grouped)[index];
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Builds a flat list of widgets: section headers + device tiles.
  List<Widget> _buildItems(Map<CastProtocol, List<CastDevice>> grouped) {
    final items = <Widget>[];
    for (final entry in grouped.entries) {
      // Protocol group header
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(_protocolIcon(entry.key), size: 18),
              const SizedBox(width: 8),
              Text(
                entry.key.name.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
      // Devices in this group
      for (final device in entry.value) {
        items.add(
          ListTile(
            leading: Icon(_protocolIcon(device.protocol)),
            title: Text(device.name),
            subtitle: Text('${device.address.address}:${device.port}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onDeviceTap(device),
          ),
        );
      }
    }
    return items;
  }
}
