## 0.2.1

### AirPlay 2
- AirPlay feature flag detection via mDNS TXT records (`AirPlayFeatures` class)
- `AirPlayMediaController` with V1/V2 `/play` format auto-negotiation
- `UnsupportedFeatureException` when device lacks video support
- `PlaybackException` when all `/play` formats are rejected
- AirPlay 2 event channel and RTSP session setup
- HAP encrypted session for authenticated media commands
- Apple binary plist encoder/decoder
- AirPlay PIN pairing dialog in example app
- Breaking: `HapSession` no longer has `play`, `stop`, `scrub`, or `rate` — use `AirPlayMediaController`

### Local file casting
- Local file support with `CastMedia.file()` constructor
- `MediaTransformer` interface for extensible media format preparation
- `TsKeyframeScanner` for keyframe-aligned HLS segment boundaries
- Virtual segment URLs for Chromecast compatibility (replaces EXT-X-BYTERANGE)
- `useChunkedHls` flag for chunked vs single-segment HLS
- Local subtitle support with automatic SRT-to-VTT conversion

### Chromecast fixes
- Fixed local file casting — HLS playlists and file routes were being destroyed by cleanup before the device could fetch them
- CORS preflight (OPTIONS) handler for HLS segment requests
- RFC 8216-compliant TARGETDURATION calculation
- Consistent `application/x-mpegURL` content type across all HLS responses
- File extension on proxy URLs for HLS player format detection
- Volume updates via RECEIVER_STATUS instead of optimistic update

### DLNA improvements
- Duration metadata via DIDL-Lite `<res duration="HH:MM:SS">` attribute
- DLNA-specific HTTP headers (`transferMode.dlna.org`, `DLNA.ORG_OP=01` flags)
- Serve local TS files directly (not piped through HLS)

### Other
- Retry mDNS queries 3 times for slow-responding devices
- Comprehensive logging for all discovery providers and sessions
- Subtitle proxy for Chromecast (CORS + SRT conversion)
- Log viewer and custom media input in example app
- Protocol references and future work documentation

## 0.2.0

- Platform permissions for example app (macOS, iOS, Android)
- Code formatting and cleanup

## 0.1.0

- Initial release
- Chromecast (CASTV2) protocol support with default media receiver
- AirPlay 1 video casting support
- DLNA/UPnP protocol support with AVTransport and RenderingControl
- Built-in HTTP proxy server for custom header injection
- HLS m3u8 playlist URL rewriting through proxy
- Local file serving for downloaded content
- Subtitle support across all protocols (WebVTT, SRT)
- Cross-platform: Android, iOS, macOS, Windows, Linux
- Pluggable device discovery (default: multicast_dns, injectable: bonsoir)
- 366+ tests with mock servers for each protocol
- Flutter example app with device picker and remote control
