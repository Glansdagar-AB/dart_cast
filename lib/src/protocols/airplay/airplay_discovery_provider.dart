import 'dart:async';

import '../../core/cast_device.dart';
import '../../core/discovery_provider.dart';
import '../../utils/logger.dart';
import '../../utils/mdns_discovery.dart';

/// Discovers AirPlay devices via mDNS (_airplay._tcp.local).
///
/// Queries the local network for AirPlay services, parses TXT records
/// via [MdnsServiceInfo], filters by video support, and emits [CastDevice]
/// lists as devices are found.
class AirPlayDiscoveryProvider implements DeviceDiscoveryProvider {
  final MdnsLookup _mdnsLookup;
  StreamController<List<CastDevice>>? _controller;
  StreamSubscription<MdnsServiceInfo>? _subscription;
  final Map<String, CastDevice> _devices = {};

  /// Creates an [AirPlayDiscoveryProvider].
  ///
  /// An optional [mdnsLookup] can be provided for testing.
  AirPlayDiscoveryProvider({MdnsLookup? mdnsLookup})
      : _mdnsLookup = mdnsLookup ?? _defaultMdnsLookup;

  @override
  CastProtocol get protocol => CastProtocol.airplay;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopDiscovery();
    _devices.clear();
    _controller = StreamController<List<CastDevice>>();

    CastLogger.info('AirPlay: starting mDNS discovery');
    final stream = _mdnsLookup(MdnsDiscovery.airplayServiceType);
    _subscription = stream.listen(
      (info) {
        // Filter: only include devices that support video
        final features = info.txtRecords['features'] ?? '';
        if (!MdnsServiceInfo.supportsVideo(features)) {
          CastLogger.debug(
              'AirPlay: skipping "${info.friendlyName}" (no video support, features=$features)');
          return;
        }

        final device = info.toAirplayDevice();
        if (!_devices.containsKey(device.id)) {
          CastLogger.info(
              'AirPlay: found "${device.name}" at ${device.address.address}:${device.port}');
          _devices[device.id] = device;
          if (_controller?.isClosed == false) {
            _controller!.add(_devices.values.toList());
          }
        }
      },
      onError: (Object error) {
        CastLogger.error('AirPlay: discovery error: $error');
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
  static Stream<MdnsServiceInfo> _defaultMdnsLookup(String serviceType) {
    return MdnsDiscovery.discover(serviceType);
  }
}
