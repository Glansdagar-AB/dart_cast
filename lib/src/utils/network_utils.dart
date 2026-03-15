import 'dart:io';

/// Network utility methods for casting.
class NetworkUtils {
  NetworkUtils._();

  /// Returns the local non-loopback IPv4 address, or null if none found.
  static Future<String?> getLocalIpAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return null;
  }

  /// Finds an available port by binding to port 0.
  static Future<int> findAvailablePort() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  /// Formats a [Duration] as 'HH:MM:SS'.
  static String formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  /// Parses a 'HH:MM:SS' string into a [Duration].
  static Duration parseDuration(String formatted) {
    final parts = formatted.split(':');
    if (parts.length != 3) return Duration.zero;
    return Duration(
      hours: int.tryParse(parts[0]) ?? 0,
      minutes: int.tryParse(parts[1]) ?? 0,
      seconds: int.tryParse(parts[2]) ?? 0,
    );
  }
}
