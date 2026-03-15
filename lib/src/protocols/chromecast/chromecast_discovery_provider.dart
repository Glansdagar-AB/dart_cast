import 'dart:async';

import '../../core/cast_device.dart';
import '../../core/discovery_provider.dart';
import '../../utils/mdns_discovery.dart';

/// Discovers Chromecast devices via mDNS (_googlecast._tcp.local).
///
/// Queries the local network for Chromecast services, parses TXT records
/// via [MdnsServiceInfo], and emits [CastDevice] lists as devices are found.
class ChromecastDiscoveryProvider implements DeviceDiscoveryProvider {
  final MdnsLookup _mdnsLookup;
  StreamController<List<CastDevice>>? _controller;
  StreamSubscription<MdnsServiceInfo>? _subscription;
  final Map<String, CastDevice> _devices = {};

  /// Creates a [ChromecastDiscoveryProvider].
  ///
  /// An optional [mdnsLookup] can be provided for testing.
  ChromecastDiscoveryProvider({MdnsLookup? mdnsLookup})
      : _mdnsLookup = mdnsLookup ?? _defaultMdnsLookup;

  @override
  CastProtocol get protocol => CastProtocol.chromecast;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopDiscovery();
    _devices.clear();
    _controller = StreamController<List<CastDevice>>();

    final stream = _mdnsLookup(MdnsDiscovery.chromecastServiceType);
    _subscription = stream.listen(
      (info) {
        final device = info.toChromecastDevice();
        if (!_devices.containsKey(device.id)) {
          _devices[device.id] = device;
          if (_controller?.isClosed == false) {
            _controller!.add(_devices.values.toList());
          }
        }
      },
      onError: (Object error) {
        if (_controller?.isClosed == false) {
          _controller!.addError(error);
        }
      },
      onDone: () {
        if (_controller?.isClosed == false) {
          _controller!.close();
        }
      },
    );

    // Close after timeout
    Timer(timeout, () {
      stopDiscovery();
    });

    return _controller!.stream;
  }

  @override
  void stopDiscovery() {
    _subscription?.cancel();
    _subscription = null;
    if (_controller?.isClosed == false) {
      _controller?.close();
    }
    _controller = null;
  }

  @override
  void dispose() {
    stopDiscovery();
  }

  /// Default mDNS lookup using the multicast_dns package.
  ///
  /// This is a placeholder that returns an empty stream — real implementations
  /// would use `MDnsClient` from the `multicast_dns` package.
  static Stream<MdnsServiceInfo> _defaultMdnsLookup(String serviceType) {
    // In production, this would use MDnsClient to query the network.
    // For now, consumers must provide their own lookup or use the
    // multicast_dns package directly.
    return const Stream.empty();
  }
}
