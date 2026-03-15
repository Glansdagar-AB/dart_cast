# dart_cast — Cross-Platform Casting Package Design

**Date:** 2026-03-14
**Status:** Approved
**Scope:** Standalone pure Dart casting package + anime_here integration

## Overview

A pure Dart casting package supporting Chromecast (CASTV2), AirPlay, and DLNA across all platforms (Android, iOS, macOS, Windows, Linux). Includes a built-in local HTTP proxy to handle custom header injection for HLS streams and local file serving. No Flutter dependency in core — Flutter example app serves as UI reference.

## Requirements

### Functional
- Discover cast devices on the local network (Chromecast, AirPlay, DLNA)
- Cast HLS m3u8 streams and direct MP4/TS files to discovered devices
- Inject custom HTTP headers (Referer, Origin, cookies) transparently via local proxy
- Cast downloaded local files (.ts, .mp4) by serving them through the proxy
- Full playback controls: play, pause, stop, seek, volume
- Subtitle support across all protocols
- Quality switching and episode navigation while casting
- Watch progress tracking synced to database during casting
- Remember last-used device for quick reconnect
- Background casting — control connection maintained when app is backgrounded

### Non-Functional
- Pure Dart core — no Flutter dependency, testable in isolation
- TDD — comprehensive test suite with mock servers for each protocol
- Cross-platform — all three protocols work on Android, iOS, macOS, Windows

## Architecture

### Package Structure

```
dart_cast/
├── lib/
│   ├── dart_cast.dart                    # Public API barrel export
│   └── src/
│       ├── core/
│       │   ├── cast_device.dart          # Device model
│       │   ├── cast_session.dart         # Active session state machine
│       │   ├── cast_media.dart           # Media item (URL, headers, subtitles, metadata)
│       │   ├── cast_service.dart         # Main entry point
│       │   ├── discovery_manager.dart    # Unified multi-protocol discovery
│       │   └── media_proxy.dart          # Local HTTP proxy for header injection
│       ├── protocols/
│       │   ├── dlna/
│       │   │   ├── ssdp_discovery.dart
│       │   │   ├── dlna_device.dart
│       │   │   ├── dlna_controller.dart
│       │   │   └── dlna_session.dart
│       │   ├── chromecast/
│       │   │   ├── mdns_discovery.dart
│       │   │   ├── castv2_channel.dart
│       │   │   ├── cast_media_channel.dart
│       │   │   ├── cast_receiver_channel.dart
│       │   │   └── chromecast_session.dart
│       │   └── airplay/
│       │       ├── airplay_discovery.dart
│       │       ├── airplay_client.dart
│       │       ├── airplay_session.dart
│       │       └── plist_codec.dart
│       └── utils/
│           ├── network_utils.dart
│           └── logger.dart
├── test/
│   ├── core/
│   ├── protocols/dlna/
│   ├── protocols/chromecast/
│   ├── protocols/airplay/
│   └── integration/
└── example/                              # Flutter reference UI
    ├── device_discovery_page.dart
    ├── remote_control_page.dart
    └── main.dart
```

### Layer Diagram

```
┌──────────────────────────────────────────────┐
│  Consumer (anime_here app or any Dart app)    │
│  Uses: CastService, CastSession, CastMedia   │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│  Core Layer (protocol-agnostic)               │
│  CastService → DiscoveryManager               │
│             → CastSession (state machine)     │
│             → MediaProxy (header injection)   │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│  Protocol Layer (isolated per protocol)       │
│  ┌──────────┐ ┌────────────┐ ┌──────────┐   │
│  │  DLNA    │ │ Chromecast │ │ AirPlay  │   │
│  │ SSDP     │ │ mDNS       │ │ mDNS     │   │
│  │ SOAP/XML │ │ TLS+Proto  │ │ HTTP     │   │
│  └──────────┘ └────────────┘ └──────────┘   │
└──────────────────────────────────────────────┘
```

## Public API

### CastService — Main Entry Point

```dart
class CastService {
  Stream<List<CastDevice>> startDiscovery({
    Set<CastProtocol> protocols = CastProtocol.values,
    Duration timeout = const Duration(seconds: 10),
  });

  void stopDiscovery();

  Future<CastSession> connect(CastDevice device);

  CastDevice? get lastDevice;
  Future<CastSession?> reconnect();

  CastSession? get activeSession;

  void dispose();
}
```

### CastDevice

```dart
enum CastProtocol { chromecast, airplay, dlna }

class CastDevice {
  final String id;
  final String name;
  final CastProtocol protocol;
  final InternetAddress address;
  final int port;
  final Map<String, String> metadata;
}
```

### CastSession

```dart
enum CastSessionState {
  connecting, connected, loading, playing, paused, buffering, idle, disconnected
}

class CastSession {
  final CastDevice device;

  Future<void> loadMedia(CastMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setSubtitle(CastSubtitle? subtitle);

  Stream<CastSessionState> get stateStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<double> get volumeStream;

  CastSessionState get state;
  Duration get position;
  Duration get duration;

  Future<void> disconnect();
}
```

### CastMedia

```dart
class CastMedia {
  final String url;
  final Map<String, String> httpHeaders;
  final String? title;
  final String? imageUrl;
  final Duration? startPosition;
  final List<CastSubtitle> subtitles;
  final CastMediaType type;
}

class CastSubtitle {
  final String url;
  final String label;
  final String language;
  final String format;
}

enum CastMediaType { hls, mp4, mpegTs }
```

## Media Proxy Server

### Purpose

Cast devices (Chromecast, DLNA, AirPlay) cannot send custom HTTP headers with their requests. Video sources from anime providers require specific headers (Referer, Origin, cookies) to avoid 403 errors. The proxy solves this transparently.

### Data Flow

```
┌──────────┐   loadMedia(url, headers)   ┌────────────┐
│  App      │ ─────────────────────────── │ CastService │
└──────────┘                              └─────┬──────┘
                                                │
                                    Starts proxy, rewrites URL
                                                │
                                          ┌─────▼──────┐
┌──────────┐  http://192.168.1.5:8234/s/  │ MediaProxy  │
│  Cast    │ ◄──────────────────────────── │ (dart:io    │
│  Device  │ ──── GET /stream/token ────► │ HttpServer) │
└──────────┘                              └─────┬──────┘
                                                │
                                    Forwards with headers
                                                │
                                          ┌─────▼──────┐
                                          │ Video       │
                                          │ Source      │
                                          └────────────┘
```

### HLS Rewriting

1. Cast device requests proxied master playlist URL
2. Proxy fetches real m3u8 with correct headers
3. Proxy parses m3u8, rewrites every segment/variant URL to point through proxy
4. Returns modified m3u8 to cast device
5. Each subsequent segment request goes through proxy with correct headers

### Local File Serving

For downloaded .ts/.mp4 files, proxy serves them directly over HTTP — no header forwarding needed, just a local file server the cast device can reach.

### Security

- Random tokens per session — URLs not guessable
- Accepts connections from local network only
- Auto-stops when casting session ends

## Protocol Implementations

### DLNA (Build First)

| Aspect | Detail |
|--------|--------|
| Discovery | SSDP UDP multicast on 239.255.255.250:1900 |
| Control | SOAP actions over HTTP (AVTransport service) |
| Actions | SetAVTransportURI, Play, Pause, Stop, Seek, GetPositionInfo, GetTransportInfo, SetVolume, GetVolume |
| Position | Polling GetPositionInfo every ~1 second |
| Subtitles | DIDL-Lite XML metadata with subtitle `<res>` elements |
| Complexity | Low |

### Chromecast (Build Second)

| Aspect | Detail |
|--------|--------|
| Discovery | mDNS query for `_googlecast._tcp.local` |
| Transport | TLS socket to device port 8009, protobuf framing |
| Channels | Connection, Heartbeat (PING/PONG 5s), Receiver (launch app CC1AD845), Media (LOAD/PLAY/PAUSE/SEEK) |
| Position | Push-based — device sends media status updates |
| Subtitles | WebVTT tracks in LOAD message tracks array |
| Complexity | High |

Key details:
- Uses default media receiver app (CC1AD845) — no custom receiver needed
- Self-signed TLS cert on device — disable cert verification for cast connections only
- Protobuf `CastMessage` definition is small and well-documented

### AirPlay (Build Third)

| Aspect | Detail |
|--------|--------|
| Discovery | mDNS query for `_airplay._tcp.local` |
| Transport | Plain HTTP to device |
| Endpoints | POST /play, POST /scrub, POST /rate, POST /stop, GET /playback-info |
| Position | Polling /playback-info every ~1 second (returns XML plist) |
| Subtitles | Inject via HLS playlist rewriting (add #EXT-X-MEDIA:TYPE=SUBTITLES) |
| Complexity | Medium |

Key details:
- Implements AirPlay 1 video casting only (HTTP-based, stable)
- Skips screen mirroring and audio streaming (RAOP/AirPlay 2) — not needed
- Binary plist encoding/decoding for request/response bodies

## Integration with anime_here

### New Files

- `lib/controllers/cast_controller.dart` — wraps CastService, manages state, persists last device, syncs watch progress
- `lib/screens/cast/remote_control_screen.dart` — full playback controls while casting
- `lib/screens/cast/device_picker_dialog.dart` — device selection UI
- `lib/widgets/cast_button.dart` — cast icon for episode screen + player controls

### Modified Files

- `lib/screens/video_player/streaming_content_video_player.dart` — add cast button, handle transfer-to-cast
- `lib/screens/video_player/downloaded_content_video_player.dart` — add cast button, serve file via proxy
- Episode detail screen — add cast button
- `lib/controllers/video_player_listener.dart` — extend progress tracking for cast position stream

### Cast Button Placement

- **Episode screen:** alongside existing quality/play buttons — user picks cast device before playback, video goes directly to cast device
- **Video player controls:** user can transfer ongoing local playback to a cast device

### Watch Progress Sync

Cast session's `positionStream` feeds into the same database update path as `VideoPlayerListener` — resume position, watched/completed status all work seamlessly across local and cast playback.

### Quality & Episode Switching

While casting, quality switches re-load media at current position. Next/previous episode fetches new qualities from the provider and loads new media on the cast device.

### Background Casting

When app is backgrounded:
- CastService maintains control connection (heartbeat for Chromecast, keep-alive for others)
- MediaProxy continues serving content
- On foreground return, remote control screen refreshes state from device
- If connection lost, offer reconnect via last-device memory

## Testing Strategy

### Unit Tests (~125)

| Area | Tests | Focus |
|------|-------|-------|
| DLNA | ~30 | SSDP parsing, device XML parsing, SOAP generation/parsing, DIDL-Lite metadata |
| Chromecast | ~35 | Protobuf serialization, CASTV2 framing, media/receiver channel JSON, heartbeat logic |
| AirPlay | ~20 | HTTP request formation, plist encoding/decoding, playback-info parsing |
| Media Proxy | ~25 | HLS m3u8 parsing/rewriting, header injection, file serving, token validation, concurrency |
| Core | ~15 | Device model, media construction, session state machine, discovery merging |

### Integration Tests (~15)

Each protocol gets a mock server simulating real device behavior:

| Protocol | Mock |
|----------|------|
| DLNA | UDP socket (SSDP) + dart:io HttpServer (SOAP) |
| Chromecast | SecureServerSocket responding to CASTV2 protobuf |
| AirPlay | dart:io HttpServer handling /play, /scrub, /playback-info |

Full flow tests: discover → connect → load → play → seek → get position → disconnect

### Not Tested (manual testing)

- Actual network multicast (OS-level, flaky in CI)
- Real device quirks (manual testing matrix across TV brands)
- Flutter UI (out of scope for core package)

## Build Order

### Milestone 1: Core + Media Proxy
Core abstractions (CastDevice, CastSession, CastMedia, CastService). Media proxy with HLS rewriting, header injection, local file serving. Unit tests for proxy and core models.

### Milestone 2: DLNA Protocol
SSDP discovery. SOAP AVTransport control. Position polling. Subtitle support via DIDL-Lite. Mock DLNA server + integration tests.

### Milestone 3: Chromecast Protocol
mDNS discovery. CASTV2 TLS channel with protobuf. Heartbeat, connection, receiver, media channels. Default media receiver launch. WebVTT subtitle tracks. Mock server + integration tests.

### Milestone 4: AirPlay Protocol
mDNS discovery (reuse from Chromecast milestone). HTTP control client. Playback-info polling. Subtitle injection via HLS playlist rewriting. Mock server + integration tests.

### Milestone 5: Polish & Example App
Last-device persistence and quick reconnect. Discovery manager merging all protocols. Error handling (device unreachable, network change, backgrounded). Flutter example app. Documentation and pub.dev readiness.

### Milestone 6: anime_here Integration
CastController in the app. Cast buttons in episode screen + player controls. Remote control screen. Watch progress sync. Quality/episode switching while casting. Downloaded content casting. Background casting support.

## Platform Requirements

### iOS
- `Info.plist`:
  - `NSLocalNetworkUsageDescription` — required for local network access (discovery + proxy)
  - `NSBonjourServices` — add `_googlecast._tcp`, `_airplay._tcp` for mDNS discovery
- Minimum iOS 13+

### Android
- `AndroidManifest.xml`:
  - `android.permission.INTERNET`
  - `android.permission.ACCESS_WIFI_STATE`
  - `android.permission.CHANGE_WIFI_MULTICAST_STATE` — required for SSDP multicast
  - `android.permission.ACCESS_NETWORK_STATE`
- Android 12+: `android.permission.NEARBY_WIFI_DEVICES` for device discovery

### macOS
- Entitlements:
  - `com.apple.security.network.client` — outgoing connections
  - `com.apple.security.network.server` — proxy server binding
  - `com.apple.security.device.bluetooth` — may be needed for some discovery paths
- App sandbox multicast: `com.apple.security.network.multicast` (if available, otherwise use `bonsoir` native path)

### Windows
- No special permissions — `dart:io` sockets work directly
- Firewall: users may need to allow the app through Windows Firewall for proxy and multicast

### mDNS Discovery Strategy

The `multicast_dns` pure Dart package uses raw UDP sockets which may be blocked by the app sandbox on Apple platforms (iOS/macOS). To resolve:

- **Discovery is pluggable** — `DiscoveryManager` accepts a `DeviceDiscoveryProvider` interface
- **Default implementation** uses `multicast_dns` (pure Dart, works on Android/Windows/Linux)
- **Apple platforms** use `bonsoir` package (Flutter plugin wrapping native NSNetServiceBrowser) injected by the consumer app
- This keeps the core package pure Dart while allowing native discovery where needed
- The example app demonstrates how to inject `bonsoir`-based discovery

## Error Handling

### Exception Hierarchy

```dart
/// Base exception for all casting errors
class CastException implements Exception {
  final String message;
  final Object? cause;
}

/// Device was found but connection failed (offline, unreachable, refused)
class DeviceUnreachableException extends CastException {}

/// Connection was established but dropped (network change, device sleep, timeout)
class ConnectionLostException extends CastException {}

/// Media could not be loaded on the cast device (unsupported format, URL expired)
class MediaLoadFailedException extends CastException {}

/// Proxy could not fetch upstream content (403, timeout, DNS failure)
class ProxyUpstreamException extends CastException {}

/// Discovery failed (permissions denied, no network, multicast blocked)
class DiscoveryException extends CastException {}

/// Protocol-specific error (invalid SOAP response, protobuf parse failure, etc.)
class ProtocolException extends CastException {
  final CastProtocol protocol;
}
```

### Error Behavior by Method

| Method | Failure | Behavior |
|--------|---------|----------|
| `startDiscovery()` | Permissions denied | Throws `DiscoveryException` |
| `startDiscovery()` | No network | Returns empty stream, no error |
| `connect()` | Device offline | Throws `DeviceUnreachableException` |
| `connect()` | Already connected | Auto-disconnects previous session, connects to new device |
| `loadMedia()` | Upstream 403 | Throws `ProxyUpstreamException` |
| `loadMedia()` | Device rejects format | Throws `MediaLoadFailedException` |
| `loadMedia()` | Called while loading | Cancels previous load, starts new one |
| `play()`/`pause()`/`seek()` | Connection lost | Throws `ConnectionLostException`, sets state to `disconnected` |
| `startDiscovery()` | Called twice | Stops previous discovery, starts new one |
| `reconnect()` | No last device | Returns null |
| `reconnect()` | Last device offline | Throws `DeviceUnreachableException` |

## Session State Machine

```
                  connect()
    ┌─────────── connecting ◄──────────────┐
    │                │                      │
    │           success                reconnect()
    │                │                      │
    │           connected ──────────── disconnected
    │                │                   ▲  ▲
    │           loadMedia()              │  │
    │                │              connection lost
    │           loading ─────────────────┘  │
    │                │                      │
    │       ┌── playing ◄──► paused         │
    │       │     │  ▲          │           │
    │       │     │  │          │           │
    │       │  buffering        │           │
    │       │                   │           │
    │       └── stop() ────► idle           │
    │                          │            │
    │                     loadMedia()       │
    │                     (new episode)     │
    │                          │            │
    │                      loading          │
    │                                       │
    └──── disconnect() from any state ──────┘
```

### Valid Transitions

| From | To | Trigger |
|------|----|---------|
| `connecting` | `connected` | Connection established |
| `connecting` | `disconnected` | Connection failed |
| `connected` | `loading` | `loadMedia()` called |
| `connected` | `disconnected` | `disconnect()` or connection lost |
| `loading` | `playing` | Media starts playing |
| `loading` | `disconnected` | Load failed or connection lost |
| `playing` | `paused` | `pause()` called |
| `playing` | `buffering` | Buffer underrun |
| `playing` | `idle` | `stop()` or media ended |
| `playing` | `disconnected` | Connection lost |
| `paused` | `playing` | `play()` called |
| `paused` | `idle` | `stop()` called |
| `paused` | `disconnected` | Connection lost |
| `buffering` | `playing` | Buffer refilled |
| `buffering` | `disconnected` | Connection lost |
| `idle` | `loading` | `loadMedia()` called (next episode) |
| `idle` | `disconnected` | `disconnect()` called |
| Any state | `disconnected` | `disconnect()` or connection lost |

## Media Proxy Server — Extended Details

### Proxy Binding

The proxy binds to the device's **WiFi interface IP** (not `localhost`, not `0.0.0.0`). Cast devices on the same network need to reach the proxy via this IP.

`network_utils.dart` detects the correct interface:
1. Enumerate network interfaces via `NetworkInterface.list()`
2. Filter for WiFi/Ethernet interfaces with IPv4 addresses
3. Prefer non-loopback, non-link-local addresses
4. Fallback to first available non-loopback address

### HLS Tags Requiring URL Rewriting

The proxy rewrites URLs in these HLS tags:

| Tag | Purpose |
|-----|---------|
| `#EXTINF` segment URIs | Video/audio segment files |
| `#EXT-X-STREAM-INF` variant URIs | Multi-quality variant playlists |
| `#EXT-X-KEY:URI=` | AES-128 decryption keys |
| `#EXT-X-MAP:URI=` | Initialization segments (fMP4) |
| `#EXT-X-MEDIA:URI=` | Alternate audio/subtitle track playlists |

Additional handling:
- Relative URLs resolved to absolute using playlist base URL before rewriting
- `#EXT-X-BYTERANGE` preserved as-is (proxy forwards Range headers)
- Live/event playlists: out of scope (anime content is VOD only)

### Content-Type and Range Requests

The proxy must:
- Forward correct `Content-Type` headers (`application/vnd.apple.mpegurl` for m3u8, `video/mp4` for MP4, `video/mp2t` for TS)
- Support HTTP Range requests for MP4/TS files (Chromecast sends Range headers for seeking)
- Use chunked transfer encoding for large files
- For local file serving, calculate and return `Content-Length`

### Proxy Lifecycle During Quality Switching

When quality is switched while casting:
1. New `proxyUrl()` called for the new quality stream — gets a new token
2. `loadMedia()` sends the new proxy URL to the cast device with `startPosition` at current position
3. Old proxy routes remain valid briefly (grace period) then are cleaned up
4. Each `loadMedia()` call triggers cleanup of routes from the previous media

## CastSession Additional Details

### Volume

`setVolume(double volume)` uses a normalized 0.0 to 1.0 range. The protocol layer translates:
- DLNA: multiplies by 100 (DLNA uses 0-100 integer scale)
- Chromecast: passes through (native 0.0-1.0)
- AirPlay: passes through (native 0.0-1.0)

### Cleanup

`disconnect()` handles all cleanup:
- Sends stop/disconnect commands to the cast device
- Stops heartbeat/polling timers
- Cleans up proxy routes for the session
- Sets state to `disconnected`
- Does NOT stop the proxy server (it may be reused for reconnect)

`CastService.dispose()` stops everything including the proxy server.

### Last-Device Persistence

`CastDevice` is serializable to/from JSON. Persistence is the **consumer's responsibility**:

```dart
// Save
final json = castService.lastDevice?.toJson();
prefs.setString('last_cast_device', jsonEncode(json));

// Restore
final saved = jsonDecode(prefs.getString('last_cast_device')!);
final device = CastDevice.fromJson(saved);
castService.setLastDevice(device);
```

The package provides serialization, the app handles storage (SharedPreferences, database, etc.).

## Integration — VideoPlayerListener Refactoring

The existing `VideoPlayerListener` takes an `AbstractPlayer controller` and subscribes to `controller.stream.position`. Since `CastSession` is not an `AbstractPlayer`, the listener needs a small refactoring:

Extract position tracking into a method that accepts a `Stream<Duration>` and a duration getter:

```dart
// Before: tightly coupled to AbstractPlayer
void setListenerValues(AbstractPlayer controller) { ... }

// After: accepts any position source
void setListenerFromStream({
  required Stream<Duration> positionStream,
  required Duration Function() getDuration,
}) { ... }
```

The existing `setListenerValues` calls this internally with `controller.stream.position`. The cast controller calls it with `session.positionStream`. This is a backward-compatible refactoring.

## AirPlay Limitations

- Targets AirPlay 1 HTTP-based video casting — stable and well-understood
- Works on Apple TV (all tvOS versions) and AirPlay-enabled smart TVs
- Does NOT work on HomePods or other AirPlay 2 audio-only receivers (not relevant for video casting)
- AirPlay 2 encrypted screen mirroring is explicitly out of scope

## Dependencies

### Core Package (dart_cast)
- `protobuf` — Chromecast CASTV2 message serialization (generated from Chromium's `cast_channel.proto`, generated files committed to repo)
- `multicast_dns` — default mDNS discovery (pure Dart, works on Android/Windows/Linux)
- No Flutter dependency in core

### Protobuf Build

The CASTV2 protocol uses Chromium's `cast_channel.proto` definition. The message structure:
```protobuf
message CastMessage {
  required ProtocolVersion protocol_version = 1;
  required string source_id = 2;
  required string destination_id = 3;
  required string namespace = 4;
  required PayloadType payload_type = 5;
  optional string payload_utf8 = 6;
  optional bytes payload_binary = 7;
}
```

Generated Dart files are committed to the repo (not generated via build_runner) to avoid requiring `protoc` toolchain for consumers. Regeneration instructions documented in `CONTRIBUTING.md`.

### Optional Dependencies
- `bonsoir` — native mDNS discovery for Apple platforms (Flutter plugin, injected by consumer)

### Example App
- `flutter` SDK
- `dart_cast` (path dependency)
- `bonsoir` (for Apple platform discovery)

### anime_here Integration
- `dart_cast` (git or pub dependency)
- `bonsoir` (for iOS/macOS discovery)

## Enum Naming

`CastMediaType` values: `hls`, `mp4`, `mpegTs` (renamed from `ts` to avoid TypeScript confusion).
