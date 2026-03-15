import 'dart:async';

import 'cast_device.dart';
import 'discovery_provider.dart';

/// Manages device discovery across multiple protocol providers.
///
/// Merges device lists from all active providers, deduplicates by device ID,
/// and emits a combined list as devices appear or disappear.
class DiscoveryManager {
  final List<DeviceDiscoveryProvider> _providers;
  final List<StreamSubscription<List<CastDevice>>> _subscriptions = [];
  final Set<DeviceDiscoveryProvider> _activeProviders = {};
  StreamController<List<CastDevice>>? _outputController;
  Timer? _timeoutTimer;

  /// Per-provider device lists, keyed by provider index.
  final Map<int, List<CastDevice>> _providerDevices = {};

  /// Creates a [DiscoveryManager] with the given discovery [providers].
  DiscoveryManager(List<DeviceDiscoveryProvider> providers)
      : _providers = List.unmodifiable(providers);

  /// Starts discovery on matching providers and returns a merged stream.
  ///
  /// [protocols] filters which providers to start. Defaults to all.
  /// [timeout] controls how long discovery runs before the stream closes.
  Stream<List<CastDevice>> startDiscovery({
    Set<CastProtocol>? protocols,
    Duration timeout = const Duration(seconds: 10),
  }) {
    // Stop any previous discovery
    stopDiscovery();

    _outputController = StreamController<List<CastDevice>>.broadcast();
    _providerDevices.clear();

    final matchingProviders = protocols == null
        ? _providers
        : _providers.where((p) => protocols.contains(p.protocol)).toList();

    for (var i = 0; i < matchingProviders.length; i++) {
      final provider = matchingProviders[i];
      final providerIndex = i;

      _activeProviders.add(provider);
      final stream = provider.startDiscovery(timeout: timeout);
      final subscription = stream.listen(
        (devices) {
          _providerDevices[providerIndex] = devices;
          _emitCombined();
        },
        onDone: () {
          // Check if all providers are done
          _checkCompletion(matchingProviders.length);
        },
        onError: (Object error) {
          // Ignore individual provider errors; keep other providers running
        },
      );
      _subscriptions.add(subscription);
    }

    // Set up timeout
    _timeoutTimer = Timer(timeout, () {
      stopDiscovery();
    });

    // If no matching providers, close immediately
    if (matchingProviders.isEmpty) {
      _outputController?.close();
    }

    return _outputController!.stream;
  }

  void _emitCombined() {
    final seen = <String>{};
    final combined = <CastDevice>[];

    for (final devices in _providerDevices.values) {
      for (final device in devices) {
        if (seen.add(device.id)) {
          combined.add(device);
        }
      }
    }

    if (_outputController?.isClosed == false) {
      _outputController!.add(combined);
    }
  }

  void _checkCompletion(int totalProviders) {
    // This is called when a provider's stream completes.
    // We don't close the output stream here — let the timeout handle it,
    // or let stopDiscovery close it.
  }

  /// Stops all active discovery scans.
  void stopDiscovery() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    for (final provider in _activeProviders) {
      provider.stopDiscovery();
    }
    _activeProviders.clear();

    if (_outputController?.isClosed == false) {
      _outputController?.close();
    }
    _outputController = null;
  }

  /// Disposes all providers and releases resources.
  void dispose() {
    stopDiscovery();
    for (final provider in _providers) {
      provider.dispose();
    }
  }
}
