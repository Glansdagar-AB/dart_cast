# dart_cast Example

A Flutter app demonstrating how to use the `dart_cast` package for discovering and casting media to Chromecast, AirPlay, and DLNA devices.

<!-- TODO: Add screenshots of the discovery and remote control pages -->

## How to Run

```bash
cd example
flutter run
```

Make sure a cast-capable device (Chromecast, Apple TV, DLNA TV/speaker) is on the same local network as the device running the app.

## Platform Setup

Before running, apply the platform-specific configuration described in the [main README](../README.md#platform-setup) (network permissions, entitlements, etc.).

## Features Demonstrated

- **Device discovery** -- scans for Chromecast, AirPlay, and DLNA devices on the local network
- **Device picker** -- bottom sheet UI grouping devices by protocol
- **Remote control** -- play, pause, stop, and seek controls with reactive state
- **Seek and volume** -- slider controls driven by `positionStream`, `durationStream`, and `volumeStream`
- **Subtitles** -- selecting subtitle tracks on media that provides them

## Key Files

| File | What it demonstrates |
|------|---------------------|
| `lib/main.dart` | App entry point and `MaterialApp` setup |
| `lib/device_discovery_page.dart` | Creating a `CastService`, starting/stopping discovery, connecting to devices (including DLNA-specific description handling) |
| `lib/remote_control_page.dart` | Full remote control UI using `StreamBuilder` for reactive playback state, seek, volume, and subtitle selection |
| `lib/cast_media_demo.dart` | Sample `CastMedia` definitions (HLS stream, MP4 video, video with subtitles) for testing |
