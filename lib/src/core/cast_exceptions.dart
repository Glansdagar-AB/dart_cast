import 'cast_device.dart';

/// Base exception for all casting errors.
class CastException implements Exception {
  /// Description of the error.
  final String message;

  /// Optional underlying cause.
  final Object? cause;

  /// Creates a [CastException].
  CastException(this.message, [this.cause]);

  @override
  String toString() => cause != null
      ? 'CastException: $message (cause: $cause)'
      : 'CastException: $message';
}

/// Thrown when a device cannot be reached on the network.
class DeviceUnreachableException extends CastException {
  DeviceUnreachableException(super.message, [super.cause]);
}

/// Thrown when the connection to a device is lost unexpectedly.
class ConnectionLostException extends CastException {
  ConnectionLostException(super.message, [super.cause]);
}

/// Thrown when media fails to load on the cast device.
class MediaLoadFailedException extends CastException {
  MediaLoadFailedException(super.message, [super.cause]);
}

/// Thrown when the media proxy encounters an upstream error.
class ProxyUpstreamException extends CastException {
  ProxyUpstreamException(super.message, [super.cause]);
}

/// Thrown when device discovery encounters an error.
class DiscoveryException extends CastException {
  DiscoveryException(super.message, [super.cause]);
}

/// Thrown when a protocol-specific error occurs.
class ProtocolException extends CastException {
  /// The protocol that encountered the error.
  final CastProtocol protocol;

  ProtocolException(super.message, this.protocol, [super.cause]);

  @override
  String toString() => 'ProtocolException(${protocol.name}): $message';
}
