## 0.6.0

### Added
- **Alternate-audio HLS support** (`lib/src/core/hls_alt_audio_proxy.dart`, `lib/src/core/ts_alt_audio_remuxer.dart`): pure-Dart MPEG-TS remuxer that combines an HLS source's separate video + audio renditions into a single muxed TS stream the Chromecast Default Media Receiver / Shaka Player can play. Shaka does not implement TS alt-audio, so previously these sources silently returned `LOAD_FAILED`; now they play.
  - `MediaProxy.registerAltAudioMuxed({masterUrl, headers, preferredAudioLanguage})` returns a synthesised single-stream HLS master URL backed by per-segment muxing on demand.
  - DLNA path (`HlsStreamHandler`) routes through the same remuxer when the upstream master is alt-audio, so DLNA renderers also get a continuous TS stream.
  - HLS playlist parser gained `extractAudioRenditions` and a new `audioGroup` field on `extractVariants` entries.
- **MPEG-TS DVB-table stripper** (`lib/src/core/ts_dvb_stripper.dart`): drops DVB-only PIDs (SDT 0x0011, NIT 0x0010, EIT 0x0012, …) from proxied TS bodies. Some providers emit DVB tables before the PAT and Shaka Player only probes the first few packets for the PAT — without stripping, those sources return `LOAD_FAILED` with no diagnostic. Enabled by default for `video/mp2t` upstreams; can be disabled per-route via `registerMedia(stripDvbTables: false)`.
- **`ChromecastSession.enableReceiverDebugNamespaces`** constructor parameter (default `false`): opt-in subscribe to the Default Media Receiver's `com.google.cast.cac` and `com.google.cast.debugoverlay` namespaces, and promote the message-firehose log from `debug` to `info`. Useful for diagnosing `LOAD_FAILED` situations.
- **`MediaLoadFailedException`** propagation from `loadMedia` — receivers' `LOAD_FAILED` / `LOAD_CANCELLED` / `INVALID_*` messages, `IDLE` with `idleReason=ERROR` MEDIA_STATUS, and the 15s timeout now all throw `MediaLoadFailedException` (subclass of `CastException`) with the receiver-reported reason / detailedErrorCode where present, instead of the generic `TimeoutException`.

### Fixed
- **Chromecast LOAD path — BARE → MUXED retry**: remote HLS LOADs first attempt a pass-through (no remuxer, no DVB stripper); on `MediaLoadFailedException` we automatically retry with the alt-audio muxer and DVB stripper enabled. Avoids spending muxer cycles on sources that don't need it while still rescuing the ones that do.
- **Chromecast LOAD path — request/session id filtering**: the LOAD waiter now filters by the actual `requestId` of the LOAD it dispatched, and tracks "deprecated" `mediaSessionId`s from failed retry attempts. Stale `LOAD_FAILED` or late `IDLE+ERROR` MEDIA_STATUS messages from a previous attempt can no longer drag the live state machine backwards.
- **Subtitle track switching**: `ChromecastSession.setSubtitle()` now sends `EDIT_TRACKS_INFO` with the trackId that was actually assigned to that subtitle at LOAD time (was always re-selecting `trackId=1`, so switching subtitles in the UI silently re-activated the first track).
- **Subtitle URL extension**: subtitle proxy URLs now end in `/resource.vtt`. The Chromecast / Shaka URL-extension capability probe consults the path extension during `MediaCapabilities.decodingInfo()`; URLs without `.vtt` were silently failing the probe.
- **Segment URL extension**: HLS playlist rewriting now appends `/seg<n>.ts` to segment URLs. Sources whose segment URLs end in `.jpg` (and similar obfuscated extensions) previously failed Chromecast/Shaka's URL-extension probe with `LOAD_FAILED`.
- **`image/*` → `video/mp2t` Content-Type rewrite**: proxied sub-resource fetches that come back with an `image/*` content type but are actually MPEG-TS now have their Content-Type rewritten to `video/mp2t` so Shaka feeds them into the demuxer instead of refusing them.
- **Content-Length forwarding**: only forwarded when the response body is streamed through unchanged. Previously, MPEG-TS bodies filtered through the DVB stripper or HLS playlists rewritten with proxy URLs had their upstream Content-Length echoed back, causing Dart's `HttpResponse` to raise mid-stream once the actual body fell short.
- **CORS headers**: `Access-Control-Allow-Origin` now echoes the receiver's `Origin` header when present instead of `*`. Cast Application Framework rejects wildcard ACAO when the LOAD message includes a `tracks` array (subtitles), causing subtitle fetches to fail. Allow-Methods / Allow-Headers / Expose-Headers expanded to match Cast's documented requirements.
- **State machine — `loading` and `idle` recovery transitions**: the receiver may legitimately report `BUFFERING`, `PAUSED`, or `IDLE` from `loading`, and may push a fresh playback state directly from `idle` after a failed retry chain. Both transitions were rejected by the strict machine; allowed now.
- **DLNA `loading` recovery**: failed `loadMedia` now flips the state machine back to `idle` instead of leaving the session stuck in `loading`.

### Changed
- **Default Chromecast log noise**: per-MEDIA_STATUS, per-segment TS stripper stats, per-segment alt-audio mux details, and the receiver-message firehose all moved from `info` to `debug`. Once-per-load and once-per-session lines (LOAD attempt label, LOAD acknowledged + playable in Nms, alt-audio route registration) stay at `info`. Promote everything back to `info` by passing `enableReceiverDebugNamespaces: true` when debugging.

## 0.5.1

### Fixed
- **Pub points (static analysis)**: Resolved the six pana lints under `lib/` that kept the 0.5.0 static-analysis score at 40/50:
  - `curly_braces_in_flow_control_structures` in `ts_keyframe_scanner.dart` and `airplay/auth/airplay_auth.dart` — single-statement `if` bodies now wrapped in braces.
  - `use_super_parameters` on the two `CastMessage_*` enum constructors — converted to super-parameter syntax.
  - `camel_case_types` on the hand-written `CastMessage_ProtocolVersion` / `CastMessage_PayloadType` bindings in `chromecast/proto/cast_channel.dart` — suppressed via a file-level `// ignore_for_file: camel_case_types`, since these identifiers intentionally mirror the names `protoc --dart_out` would emit for Chromium's `cast_channel.proto`.

## 0.5.0

### Changed
- **protobuf**: Upgraded `protobuf` dependency from `^3.1.0` to `^6.0.0` for the latest performance improvements and bug fixes (#6). Hand-written CastMessage bindings remain compatible; no API changes.
- **Minimum Dart SDK**: Bumped `sdk` constraint from `^3.0.0` to `^3.7.0` (required by `protobuf` 4.1.1+).

## 0.4.3

### Fixed
- **Analyzer warnings**: Resolved pre-existing unused variable warnings in test files
- **Code formatting**: Applied `dart format` to all source files

## 0.4.2

### Fixed
- **Proxy IP selection**: MediaProxy now picks the local interface on the same subnet as the target cast device, fixing casting failures on Android where the proxy would bind to a non-WiFi address unreachable by the cast device
- **Concurrent loadMedia guard**: All protocol sessions (Chromecast, AirPlay, DLNA) now ignore duplicate `loadMedia()` calls while one is already in progress, preventing multiple LOAD messages from being sent to the device
- **Socket disconnect detection**: Chromecast session now handles message stream errors and unexpected closures, transitioning to disconnected state so the app can react (previously the session stayed "connected" after a network drop)

## 0.4.1

### Fixed
- DLNA start position: seek now deferred until TV confirms PLAYING state (immediate seek was ignored by TVs still loading)
- Chromecast subtitles for local files: subtitle files now served via HTTP/1.1 with CORS headers (HTTP/1.0 path lacked `Access-Control-Allow-Origin` required by Shaka Player)
- `Http10FileServer`: returns 416 Range Not Satisfiable for invalid/out-of-bounds ranges
- `SubtitleConverter.vttToSrt()`: uses targeted regex for timestamp dots (no longer corrupts non-timestamp content), expands 2-component MM:SS timestamps to HH:MM:SS
- Removed stray `response.close()` after socket detach in synthetic content handler

### New
- Updated example app with optimistic slider state, keyboard shortcuts, mute toggle, and responsive layout
- Added protocol feature indicators in example device picker
- Updated README with "What Works Where" feature matrix, protocol notes, and DLNA local files guide

## 0.4.0

### Breaking
- DLNA file serving now uses HTTP/1.0 via raw sockets instead of Dart's HttpServer response. This fixes playback on TCL Google TV and other renderers that reject HTTP/1.1.
- Removed DLNA-specific HTTP headers (`transferMode.dlna.org`, `contentFeatures.dlna.org`, `Connection: close`) from file responses — these caused some DLNA renderers to reject content.
- Cleared Dart's default security headers (`x-frame-options`, `x-xss-protection`, `x-content-type-options`) from the proxy server.

### New
- `Http10FileServer` — reusable HTTP/1.0 file server class for DLNA compatibility
- `CastMediaType.mkv` — MKV container support for casting with embedded subtitles
- `SubtitleConverter.vttToSrt()` — WebVTT to SRT conversion
- `SubtitleConverter.toAss()` — VTT/SRT to ASS conversion with customizable styling (font, outline, shadow, margins)
- `MediaProxy.registerSubtitleVariants()` — registers both SRT and VTT subtitle variants for maximum TV compatibility
- DLNA subtitle variants: DIDL-Lite now includes both SRT and VTT subtitle URLs with proper format/type attributes
- DLNA seek instantly updates position without waiting for next polling cycle
- MKV content type detection and proxy URL extension support

### Fixed
- DLNA playback failing on TCL Google TV and similar renderers that reject HTTP/1.1 responses
- DLNA flags mismatch between DIDL-Lite protocolInfo (`21500000`) and HTTP headers (`01700000`) — now aligned to `01700000` matching VLC and MiniDLNA
- Missing `DLNA.ORG_PN` profile name in protocolInfo (`AVC_MP4_HP_HD_AAC` for MP4, `MPEG_TS_HD_NA_ISO` for TS)
- DLNA seeking not working — Range responses now correctly return 206 with Content-Range
- Subtitle file proxy URLs missing file extensions (`.vtt`, `.srt`) — some TVs need extensions to recognize subtitle files
- Synthetic content (subtitle playlists, converted subtitles) now served via HTTP/1.0 for DLNA compatibility

## 0.3.1

- Added protocol status table to README with testing coverage and known limitations
- Documented DLNA MP4 playback issues (TV-dependent, some reject proxy-served MP4)
- Documented DLNA subtitle limitations (`sec:CaptionInfoEx` not universally supported)
- Documented AirPlay video casting limitations (404 on some Google TV devices)
- Recommended Chromecast as the primary tested protocol for local file casting

## 0.3.0

### Breaking changes
- `DefaultMediaTransformer` no longer wraps local TS files in HLS — it
  serves them directly via the proxy. Use `TsHlsMediaTransformer` or
  `FfmpegMediaTransformer` for Chromecast-compatible local TS casting.
- `CastMedia.useChunkedHls` is deprecated and will be removed in a future
  release. `TsHlsMediaTransformer` always uses chunked HLS.
- `ChromecastSession` now defaults to `TsHlsMediaTransformer` instead of
  `DefaultMediaTransformer`.

### New
- `TsHlsMediaTransformer` — wraps local TS files in keyframe-aligned HLS
  playlists for Chromecast compatibility
- `MediaProxy.setPatPmt()` / `MediaProxy.setFirstPts()` — enable correct
  PAT/PMT prepending and PTS offset for virtual HLS segments
- `FfmpegMediaTransformer` reference implementation in example app — remuxes
  TS→MP4 via ffmpeg with progress callbacks and mobile platform support
- `doc/LOCAL_FILE_CASTING.md` — comprehensive guide covering remux, HLS
  wrapping, and transcode approaches with tradeoffs

### Migration guide

Replace direct `DefaultMediaTransformer` usage for local TS files:

```dart
// Before (0.2.x) — DefaultMediaTransformer handled local TS→HLS internally
final session = await device.connect();

// After (0.3.0) — choose your transformer explicitly
// Option A: FFmpeg remux (recommended)
final session = await device.connect(
  mediaTransformer: FfmpegMediaTransformer(),
);

// Option B: Built-in HLS wrapping (no external tools)
final session = await device.connect(
  mediaTransformer: TsHlsMediaTransformer(),
);
```

## 0.2.1

### Local file casting
- Local file support with `CastMedia.file()` constructor
- `MediaTransformer` interface for extensible media format preparation
- `TsKeyframeScanner` for keyframe-aligned HLS segment boundaries
- Virtual segment URLs for Chromecast compatibility (replaces EXT-X-BYTERANGE)
- `useChunkedHls` flag for chunked vs single-segment HLS
- Local subtitle support with automatic SRT-to-VTT conversion

### Chromecast fixes
- Fixed local file casting — HLS playlists and file routes were destroyed by cleanup before the device could fetch them
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
