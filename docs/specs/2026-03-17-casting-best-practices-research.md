# Casting Best Practices Research — Media Format Handling Across Protocols

**Date:** 2026-03-17
**Type:** Research findings for dart_cast package improvements

## Executive Summary

Exhaustive research across 20+ Dart/Flutter packages, 5 major casting tools (CATT, VLC, go-chromecast, pychromecast, Jellyfin), and official protocol specifications reveals that **dart_cast is the only Dart package with a built-in media proxy, multi-protocol support, and format conversion**. However, our local TS file casting fails because:

1. **Chromecast cannot play raw `.ts` files** — MP2T is only supported as HLS segments, not standalone files
2. **DLNA shows duration as 0** — we're missing DLNA-specific HTTP headers and DIDL-Lite duration metadata

## Key Findings

### 1. Chromecast + MPEG-TS: The Definitive Answer

**Raw `.ts` files do NOT work on Chromecast**, despite `video/mp2t` being listed as a supported container. The TS demuxer exists only for processing HLS segments. Evidence:
- Chrome browser cannot play raw `.ts` files
- CATT doesn't handle TS files specially — they silently fail
- go-chromecast transcodes unknown formats (including TS) to MP4 via ffmpeg
- VLC transcodes everything to H.264+Vorbis in Matroska (`video/x-matroska`) or WebM

**What works on Chromecast:**
| Format | Content Type | Status |
|--------|-------------|--------|
| MP4 (H.264+AAC) | `video/mp4` | Best supported, universal |
| WebM (VP8/VP9) | `video/webm` | Good support |
| HLS (TS segments) | `application/x-mpegurl` | Excellent, native |
| Raw .ts file | `video/mp2t` | Does NOT work |
| MKV | `video/x-matroska` | Limited support |

**For local `.ts` files, the only reliable options are:**
1. **Wrap in HLS** — but this requires segments to start at keyframe boundaries with PAT/PMT tables
2. **Remux to MP4** — extract H.264/AAC from TS and wrap in MP4 container (no re-encoding, fast)
3. **Transcode via FFmpeg** — full re-encode (slow, requires ffmpeg binary)

### 2. How CATT (Best Reference) Handles Local Files

CATT is the closest analog to our approach:
- Runs HTTP server on ports 45000-47000
- Full Range request support (206 Partial Content)
- MIME type from file extension, defaults to `video/mp4`
- SRT→VTT conversion on the fly
- **No format conversion** — relies on Chromecast-native formats
- CORS: `Access-Control-Allow-Origin: *`

### 3. DLNA Duration: The Missing Pieces

Research shows DLNA TVs determine duration from **three sources** (in priority order):

1. **DIDL-Lite `<res duration="HH:MM:SS">` attribute** — most reliable
2. **HTTP `Content-Length` header** — TV estimates from file size
3. **Container metadata** (moov atom for MP4, PTS timestamps for TS)

**Our current implementation is missing:**

| What | Current | Should Be |
|------|---------|-----------|
| protocolInfo | `http-get:*:video/mp2t:*` | `http-get:*:video/mp2t:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=21500000000000000000000000000000` |
| DIDL-Lite duration | Not set | `duration="HH:MM:SS"` on `<res>` element |
| HTTP headers | Missing | Add `transferMode.dlna.org: Streaming` and `contentFeatures.dlna.org` |
| Content-Length | Set for `/file/` routes | Keep (already correct) |

The `DLNA.ORG_OP=01` flag tells the TV byte-range seeking is supported.
The `DLNA.ORG_FLAGS=21500000...` sets byte-seek + streaming + DLNA v1.5.
The `duration` attribute in DIDL-Lite directly tells the TV the total length.

### 4. Competitive Landscape

**No other Dart/Flutter package provides:**
- Built-in HTTP proxy server for media casting
- Multi-protocol support (Chromecast + AirPlay + DLNA)
- HLS URL rewriting with header injection
- Local file serving with Range requests
- SRT→VTT subtitle conversion
- HLS-to-continuous-TS conversion for DLNA

All other packages either wrap the native Cast SDK (Android/iOS only), provide discovery-only, or offer minimal DLNA `SetAVTransportURI` without media serving.

## Recommended Fixes

### Fix 1: DLNA Duration (High Priority)

In `DlnaSoapBuilder.buildSetAVTransportURI()`:
- Add `duration="HH:MM:SS"` attribute to the `<res>` element when duration is known
- Update `protocolInfo` from `http-get:*:video/mp2t:*` to include `DLNA.ORG_OP=01;DLNA.ORG_FLAGS=21500000000000000000000000000000`

In `MediaProxy._handleFileRequest()`:
- Add `transferMode.dlna.org: Streaming` header
- Add `contentFeatures.dlna.org` header matching the protocolInfo additional-info

### Fix 2: Chromecast Local TS Files (High Priority)

The HLS wrapping approach is correct but our implementation has issues. Based on research:
- **Single-segment HLS is the safest approach** — one `#EXTINF` with the full duration, one segment pointing to the file URL. No byte-range splitting needed.
- The issue is likely that Chromecast's HLS player expects the `.ts` segment URL to end in `.ts` (not `/file/randomtoken`). Try adding a `.ts` extension to the proxy URL path.
- Alternatively, serve the file with `Content-Type: video/mp2t` from the proxy and reference it in the m3u8 — the HLS player may handle it differently than standalone TS.

### Fix 3: Add DLNA-Specific HTTP Headers (Medium Priority)

When serving files to DLNA devices, the proxy should add:
```
transferMode.dlna.org: Streaming
contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=21500000000000000000000000000000
```

### Fix 4: Proxy Request Logging (Done)

Already implemented — request/response logging in MediaProxy for debugging.

## Protocol References

### Chromecast
- [Supported Media for Google Cast](https://developers.google.com/cast/docs/media)
- [Web Receiver Streaming Protocols](https://developers.google.com/cast/docs/media/streaming_protocols)
- [CATT source code](https://github.com/skorokithakis/catt)
- [go-chromecast](https://github.com/vishen/go-chromecast)
- [VLC Chromecast source](https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/cast.cpp)

### DLNA/UPnP
- [UPnP ContentDirectory DIDL-Lite](http://upnp.org/specs/av/UPnP-av-ContentDirectory-v1-Service.pdf)
- [DLNA Guidelines](https://spirespark.com/dlna/guidelines)
- [MiniDLNA source](https://sourceforge.net/projects/minidlna/)
- [Gerbera source](https://github.com/gerbera/gerbera)

### Dart/Flutter Packages
- [cast](https://pub.dev/packages/cast) — Chromecast discovery + raw messages (94 likes)
- [flutter_chrome_cast](https://pub.dev/packages/flutter_chrome_cast) — Native Cast SDK wrapper (29 likes)
- [dlna_dart](https://pub.dev/packages/dlna_dart) — Minimal DLNA client (29 likes)
- [dart_chromecast](https://pub.dev/packages/dart_chromecast) — Pure Dart Chromecast (51 likes)
