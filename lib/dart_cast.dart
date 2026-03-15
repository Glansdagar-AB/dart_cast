/// A Dart package for casting media to Chromecast, AirPlay, and DLNA devices.
library;

// Core
export 'src/core/cast_device.dart';
export 'src/core/cast_exceptions.dart';
export 'src/core/cast_media.dart';
export 'src/core/cast_session.dart';
export 'src/core/hls_parser.dart';
export 'src/core/media_proxy.dart';

// Protocols — AirPlay
export 'src/protocols/airplay/airplay_client.dart';
export 'src/protocols/airplay/airplay_session.dart';
export 'src/protocols/airplay/plist_codec.dart';

// Utils
export 'src/utils/logger.dart';
export 'src/utils/mdns_discovery.dart';
export 'src/utils/network_utils.dart';
