## 0.2.1

- Fixed Chromecast local file casting — HLS playlists and file routes were being destroyed before the device could fetch them
- Fixed media proxy cleanup to preserve synthetic content and referenced routes when switching media
- CORS preflight (OPTIONS) handler for Chromecast HLS segment requests
- RFC 8216-compliant TARGETDURATION calculation for generated HLS playlists
- Virtual segment URLs replace EXT-X-BYTERANGE for broader Chromecast compatibility
- DLNA duration metadata via DIDL-Lite `<res duration="HH:MM:SS">` attribute
- DLNA-specific HTTP headers (`transferMode.dlna.org`, `DLNA.ORG_OP=01` flags)
- `MediaTransformer` interface for extensible media format preparation
- `TsKeyframeScanner` for keyframe-aligned HLS segment boundaries
- File extension on proxy URLs for HLS player format detection

## 0.2.0

- AirPlay feature flag detection via mDNS TXT records (`AirPlayFeatures` class parses `features`/`ft` bitmask)
- `AirPlayMediaController` with V1/V2 `/play` format auto-negotiation (V1 binary plist → V1 text/parameters → V2 with RTSP SETUP)
- `UnsupportedFeatureException` thrown immediately when a device lacks video support bits (0 and 49)
- `PlaybackException` thrown when all `/play` format attempts are rejected by the device
- Breaking: `HapSession` no longer has `play`, `stop`, `scrub`, or `rate` methods — use `AirPlayMediaController` instead
- Added `docs/PROTOCOL_REFERENCES.md` with links to AirPlay, Chromecast, and DLNA specs
- Added `docs/FUTURE_WORK.md` documenting AirPlay screen mirroring and RAOP audio streaming roadmap

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
