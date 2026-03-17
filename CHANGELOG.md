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
