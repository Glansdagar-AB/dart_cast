import 'dart:io';

import '../core/cast_device.dart';

/// Represents a discovered mDNS service with its TXT records.
///
/// Shared infrastructure for both Chromecast and AirPlay device discovery.
class MdnsServiceInfo {
  /// The mDNS service name.
  final String name;

  /// The resolved host address.
  final String host;

  /// The service port.
  final int port;

  /// TXT record key-value pairs from the mDNS advertisement.
  final Map<String, String> txtRecords;

  const MdnsServiceInfo({
    required this.name,
    required this.host,
    required this.port,
    required this.txtRecords,
  });

  /// Human-readable device name.
  ///
  /// Uses the Chromecast `fn` TXT field if present, otherwise falls back
  /// to the mDNS service [name].
  String get friendlyName => txtRecords['fn'] ?? name;

  /// Unique device identifier.
  ///
  /// Uses Chromecast `id` or AirPlay `deviceid` TXT field.
  String get deviceId => txtRecords['id'] ?? txtRecords['deviceid'] ?? '';

  /// Device model string.
  ///
  /// Uses Chromecast `md` or AirPlay `model` TXT field.
  String get model => txtRecords['md'] ?? txtRecords['model'] ?? '';

  /// Whether the given AirPlay features bitmask indicates video support.
  ///
  /// The [features] string can be single-part (`"0x5A7FFFF7"`) or
  /// two-part (`"0x5A7FFFF7,0x1E"`) where the first part is the lower
  /// 32 bits and the second is the upper 32 bits.
  ///
  /// Video support is indicated by bit 0 (0x01) of the lower 32 bits.
  static bool supportsVideo(String features) {
    if (features.isEmpty) return false;

    try {
      final parts = features.split(',');
      final lower = parts[0].trim();
      final value = int.parse(
          lower.replaceFirst('0x', '').replaceFirst('0X', ''),
          radix: 16);
      return (value & 0x01) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Creates a [CastDevice] configured for the Chromecast protocol.
  CastDevice toChromecastDevice() {
    return CastDevice(
      id: deviceId,
      name: friendlyName,
      protocol: CastProtocol.chromecast,
      address: InternetAddress(host),
      port: port,
      metadata: Map<String, String>.from(txtRecords),
    );
  }

  /// Creates a [CastDevice] configured for the AirPlay protocol.
  CastDevice toAirplayDevice() {
    return CastDevice(
      id: deviceId,
      name: friendlyName,
      protocol: CastProtocol.airplay,
      address: InternetAddress(host),
      port: port,
      metadata: Map<String, String>.from(txtRecords),
    );
  }
}

/// Function type for performing mDNS service discovery.
///
/// Returns a stream of [MdnsServiceInfo] entries found on the network.
typedef MdnsLookup = Stream<MdnsServiceInfo> Function(String serviceType);

/// Constants and utilities for mDNS-based device discovery.
class MdnsDiscovery {
  MdnsDiscovery._();

  /// mDNS service type for Chromecast devices.
  static const String chromecastServiceType = '_googlecast._tcp.local';

  /// mDNS service type for AirPlay devices.
  static const String airplayServiceType = '_airplay._tcp.local';
}
