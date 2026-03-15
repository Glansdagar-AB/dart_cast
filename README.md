# dart_cast

A pure Dart package for casting media to Chromecast, AirPlay, and DLNA devices.

<!-- Badges placeholder -->
<!-- [![pub package](https://img.shields.io/pub/v/dart_cast.svg)](https://pub.dev/packages/dart_cast) -->
<!-- [![build](https://github.com/abdelaziz-mahdy/dart_cast/actions/workflows/ci.yml/badge.svg)](https://github.com/abdelaziz-mahdy/dart_cast/actions) -->

## Features

- **Chromecast (CASTV2)** -- TLS + protobuf protocol with default media receiver
- **AirPlay 1** -- HTTP-based video casting to Apple TV and AirPlay-enabled TVs
- **DLNA/UPnP** -- SSDP discovery with SOAP AVTransport control
- **Cross-platform** -- Android, iOS, macOS, Windows, Linux
- **Built-in HTTP proxy** -- transparent custom header injection for cast devices
- **HLS rewriting** -- m3u8 playlist URLs rewritten through proxy automatically
- **Subtitle support** -- WebVTT and SRT across all protocols
- **Local file serving** -- cast downloaded content via the proxy server
- **Pluggable discovery** -- swap in native mDNS (e.g., bonsoir) on Apple platforms
- **Thoroughly tested** -- 366+ tests with mock servers for each protocol

## Supported Protocols & Platforms

| Protocol   | Android | iOS | macOS | Windows | Linux |
|------------|---------|-----|-------|---------|-------|
| Chromecast | yes     | yes | yes   | yes     | yes   |
| AirPlay    | yes     | yes | yes   | yes     | yes   |
| DLNA       | yes     | yes | yes   | yes     | yes   |

## Quick Start

```dart
import 'package:dart_cast/dart_cast.dart';

final castService = CastService(
  discoveryProviders: [
    DlnaDiscoveryProvider(),
    ChromecastDiscoveryProvider(),
    AirplayDiscoveryProvider(),
  ],
  sessionFactory: (device) {
    switch (device.protocol) {
      case CastProtocol.dlna:
        return DlnaSession(device);
      case CastProtocol.chromecast:
        return ChromecastSession(device);
      case CastProtocol.airplay:
        return AirplaySession(device);
    }
  },
);

// Discover devices on the local network
final devices = await castService.startDiscovery().first;

// Connect to the first device found
final session = await castService.connect(devices.first);

// Cast an HLS stream with custom headers
await session.loadMedia(CastMedia(
  url: 'https://example.com/video.m3u8',
  type: CastMediaType.hls,
  httpHeaders: {'Referer': 'https://example.com'},
  title: 'My Video',
));

// Control playback
await session.pause();
await session.seek(Duration(minutes: 5));
await session.play();

// Monitor state
session.stateStream.listen((state) => print('State: $state'));
session.positionStream.listen((pos) => print('Position: $pos'));

// Clean up
await session.disconnect();
castService.dispose();
```

## API Overview

### CastService

The main entry point. Manages discovery, connections, and session lifecycle.

```dart
final service = CastService(
  discoveryProviders: [...],
  sessionFactory: (device) => ...,
);
```

- `startDiscovery()` -- returns a `Stream<List<CastDevice>>`
- `connect(device)` -- returns a `Future<CastSession>`
- `reconnect()` -- reconnects to the last-used device
- `activeSession` -- the current session, if any
- `dispose()` -- releases all resources

### CastDevice

A discovered device on the network.

- `id`, `name` -- identity
- `protocol` -- `CastProtocol.chromecast`, `.airplay`, or `.dlna`
- `address`, `port` -- network location
- `toJson()` / `CastDevice.fromJson()` -- serialization for persistence

### CastSession

An active connection to a cast device. Provides full playback control.

- `loadMedia(CastMedia)` -- start playing content
- `play()`, `pause()`, `stop()`, `seek(Duration)` -- playback controls
- `setVolume(double)` -- 0.0 to 1.0
- `setSubtitle(CastSubtitle?)` -- subtitle track selection
- `stateStream`, `positionStream`, `durationStream`, `volumeStream` -- reactive streams
- `disconnect()` -- end the session

### CastMedia

Describes what to play.

```dart
CastMedia(
  url: 'https://example.com/video.m3u8',
  type: CastMediaType.hls,        // hls, mp4, or mpegTs
  httpHeaders: {'Referer': '...'}, // injected via proxy
  title: 'Episode 1',
  imageUrl: 'https://example.com/thumb.jpg',
  startPosition: Duration(seconds: 30),
  subtitles: [
    CastSubtitle(
      url: 'https://example.com/subs.vtt',
      label: 'English',
      language: 'en',
      format: 'vtt',
    ),
  ],
);
```

### MediaProxy

A built-in HTTP proxy server that handles header injection. Used internally by protocol sessions, but also available directly.

- `start()` / `stop()` -- lifecycle
- `registerMedia(url, headers: {...})` -- returns a proxy URL
- `registerFile(filePath)` -- serves a local file over HTTP

### DeviceDiscoveryProvider

An abstract interface for pluggable discovery. Each protocol ships with a default implementation, and you can inject alternatives (e.g., `bonsoir` on Apple platforms).

## Platform Setup

### iOS

Add to `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app discovers cast devices on your local network.</string>
<key>NSBonjourServices</key>
<array>
  <string>_googlecast._tcp</string>
  <string>_airplay._tcp</string>
</array>
```

### Android

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<!-- Android 12+ -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
```

### macOS

Add to your entitlements file:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

### Windows

No special permissions. Users may need to allow the app through Windows Firewall for proxy and multicast traffic.

## How the Proxy Works

Cast devices cannot send custom HTTP headers (like `Referer` or cookies) when fetching media. The built-in `MediaProxy` runs a local HTTP server on the device's WiFi IP, rewrites media URLs to point through itself, and forwards requests to the upstream server with the required headers attached. For HLS streams, the proxy also rewrites all segment and variant URLs inside m3u8 playlists so every subsequent request also goes through the proxy.

## Pluggable Discovery

The default mDNS discovery uses `multicast_dns` (pure Dart), which works on Android, Windows, and Linux. On Apple platforms (iOS/macOS), the app sandbox may block raw UDP multicast. To handle this, inject a `bonsoir`-based discovery provider:

```dart
// In your Flutter app
import 'package:bonsoir/bonsoir.dart';

class BonsoirChromecastProvider implements DeviceDiscoveryProvider {
  @override
  CastProtocol get protocol => CastProtocol.chromecast;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    // Use BonsoirDiscovery to find _googlecast._tcp services
    // and map them to CastDevice instances.
  }

  // ...
}

final service = CastService(
  discoveryProviders: [BonsoirChromecastProvider()],
  sessionFactory: ...,
);
```

## Error Handling

| Exception                    | When                                                      |
|------------------------------|-----------------------------------------------------------|
| `CastException`             | Base class for all casting errors                         |
| `DeviceUnreachableException` | Device found but connection failed (offline, refused)     |
| `ConnectionLostException`    | Connection dropped (network change, device sleep)         |
| `MediaLoadFailedException`   | Device rejected the media (unsupported format, bad URL)   |
| `ProxyUpstreamException`     | Proxy failed to fetch upstream content (403, timeout)     |
| `DiscoveryException`         | Discovery failed (permissions denied, no network)         |
| `ProtocolException`          | Protocol-specific error (bad SOAP response, protobuf err) |

All exceptions carry a `message` and optional `cause`.

## Example

See the [example/](example/) directory for a Flutter app demonstrating device discovery, connection, and a full remote control UI.

## Architecture

```
Consumer App (any Dart/Flutter app)
  Uses: CastService, CastSession, CastMedia
          |
Core Layer (protocol-agnostic)
  CastService -> DiscoveryManager
              -> CastSession (state machine)
              -> MediaProxy (header injection)
          |
Protocol Layer (isolated per protocol)
  DLNA         Chromecast       AirPlay
  SSDP         mDNS             mDNS
  SOAP/XML     TLS+Protobuf     HTTP
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing, and PR guidelines.

## License

MIT -- see [LICENSE](LICENSE) for details.
