# AirPlay Feature Detection + Video/Audio URL Cast (`/play`)

**Date:** 2026-03-16
**Status:** Approved
**Scope:** Sub-project 1 of AirPlay casting improvements

## Problem

AirPlay `/play` returns 404 on devices that don't support video URL cast (e.g., TCL Google TV). Our code currently always attempts RTSP SETUP + RECORD then `/play`, mixing the V2 audio/mirroring RTSP path with V1 video HTTP commands. This fails on devices that only implement screen mirroring and audio streaming.

## Background

AirPlay has three distinct modes, each with different protocol paths:

| Mode | Protocol | Port | Key Endpoint | Feature Bits |
|------|----------|------|-------------|--------------|
| Video URL Cast | HTTP/1.1 | mDNS-advertised | `POST /play` | Bit 0 (V1) or Bit 49 (V2) |
| Audio Streaming | RTSP/1.0 + RTP | mDNS-advertised | ANNOUNCE/SETUP/RECORD | Bit 9 |
| Screen Mirroring | RTSP/1.0 + RTP | mDNS-advertised | SETUP (type 110) | Bit 7 |

Video URL cast and RTSP audio/mirroring are separate protocol paths. `/play` does NOT require RTSP SETUP/RECORD for V1. Third-party AirPlay receivers (Google TV, some LG/Samsung) often implement only mirroring + audio, not `/play`.

### Three `/play` Body Formats

**Legacy text/parameters (original AirPlay spec, widest compatibility):**
- `Content-Type: text/parameters`
- `User-Agent: MediaControl/1.0`
- Body: `Content-Location: <url>\nStart-Position: 0\n`
- `Start-Position` is **relative** (0.0 = beginning, 1.0 = end)
- No RTSP SETUP/RECORD needed

**V1 binary plist (pyatv's V1 implementation):**
- `Content-Type: application/x-apple-binary-plist`
- `User-Agent: MediaControl/1.0`
- Binary plist body: `{Content-Location: <url>, Start-Position: <0.0-1.0>, X-Apple-Session-ID: <uuid>}`
- `Start-Position` is **relative** (0.0 to 1.0)
- `X-Apple-Session-ID` is in the **body**, not a header
- No RTSP SETUP/RECORD needed

**V2 binary plist (pyatv's V2 implementation, Apple TV):**
- `Content-Type: application/x-apple-binary-plist`
- `User-Agent: AirPlay/550.10`
- Headers: `X-Apple-ProtocolVersion: 1`, `X-Apple-Session-ID: <uuid>`, `X-Apple-Stream-ID: 1`
- Binary plist body: `{Content-Location, Start-Position-Seconds, uuid, streamType, mediaType, volume, rate, ...}`
- `Start-Position-Seconds` is **absolute seconds** (not relative)
- Requires RTSP SETUP (base only, no audio stream) + event channel + RECORD before `/play`
- `/play` is sent as HTTP/1.1, NOT RTSP — no CSeq/DACP-ID/Active-Remote headers

## Design

### 1. Feature Detection

Parse the mDNS `features` (or `ft`) TXT record during AirPlay discovery.

**New class: `AirPlayFeatures`**
- Parses feature string formats: `"0x5A7FFFF7"` (32-bit) and `"0x5A7FFFF7,0x1E"` (64-bit, upper + lower halves)
- Input may come from TXT record key `features` or `ft` (discovery provider already handles both)
- Named getters for each relevant flag:
  - `supportsVideo` → bit 0 OR bit 49
  - `supportsVideoV1` → bit 0
  - `supportsVideoV2` → bit 49
  - `supportsAudio` → bit 9
  - `supportsScreen` → bit 7
  - `supportsHLS` → bit 4
  - `requiresHapPairing` → bit 46 OR bit 48
  - `isV2Protocol` → bit 38 (SupportsUnifiedMediaControl) OR bit 48 (SupportsCoreUtilsPairingAndEncryption)
- Stored in `CastDevice.metadata['features']` (already captured as raw string)
- Logged at INFO level during discovery with parsed flags

**Key feature bits:**

| Bit | Name | Usage |
|-----|------|-------|
| 0 | SupportsAirPlayVideoV1 | Video URL cast via `/play` (V1 format) |
| 4 | VideoHTTPLiveStreams | HLS URLs supported |
| 7 | SupportsAirPlayScreen | Screen mirroring (future) |
| 9 | SupportsAirPlayAudio | Audio streaming |
| 38 | SupportsUnifiedMediaControl | V2 protocol (pyatv uses this for version selection) |
| 46 | SupportsHKPairingAndAccessControl | HAP pairing required |
| 48 | SupportsCoreUtilsPairingAndEncryption | HAP pairing, V2 protocol capable |
| 49 | SupportsAirPlayVideoV2 | Video URL cast via `/play` (V2 format) |

### 2. `/play` Implementation

**Refactored class structure:**

`HapSession` (encryption layer only):
- `encrypt()`, `decrypt()`, `sendRequest()` (HTTP/1.1), `sendRtspRequest()` (RTSP/1.0)
- Socket management, key derivation, nonce counters
- `setupRtspSession()`, `readDecryptedData()`, event channel management
- No media-level logic (no `play()`, `stop()`, `scrub()`, etc.)

`AirPlayMediaController` (new class, owns all media protocol logic):
- Takes a `HapSession` and `AirPlayFeatures` in constructor
- `playV1(url, startPosition)` — binary plist with `MediaControl/1.0` User-Agent, no RTSP setup
- `playV1Text(url, startPosition)` — legacy text/parameters format
- `playV2(url, startPosition)` — binary plist with extended fields, RTSP setup first
- `play(url, startPosition)` — auto-selects format based on features, handles fallback
- `pause()`, `resume()`, `seek(position)`, `stop()`, `getPlaybackInfo()`
- Owns RTSP session lifecycle (delegates to HapSession for RTSP commands)
- Owns feedback loop lifecycle
- All playback control commands use `HapSession.sendRequest()` (HTTP/1.1), not RTSP

`AirPlaySession` (orchestrator, public API):
- Connects, authenticates (pair-verify), creates `HapSession` + `AirPlayMediaController`
- Parses `AirPlayFeatures` from `CastDevice.metadata`
- `loadMedia()` checks features, delegates to controller
- Removes the dual-path pattern (`_hapSession != null` vs `_client`) — always uses `AirPlayMediaController` after authentication
- For devices that don't require auth, falls back to `AirPlayClient` (plain HTTP) with V1 text/parameters

**Play decision logic:**
```
play(url, startPosition):
  if not features.supportsVideo:
    throw UnsupportedFeatureException("device does not support video URL cast via AirPlay")

  // Try V1 binary plist first (no RTSP setup needed)
  response = playV1(url, startPosition)
  if response.statusCode == 200:
    startPolling()
    return

  if response.statusCode in [404, 415]:
    // Try legacy text/parameters format
    response = playV1Text(url, startPosition)
    if response.statusCode == 200:
      startPolling()
      return

  if response.statusCode in [404, 415]:
    // V1 not supported, try V2 with RTSP session
    hapSession.setupRtspSession()
    response = playV2(url, startPosition)
    if response.statusCode == 200:
      startPolling()
      return

  throw PlaybackException("device rejected /play: ${response.statusCode}")
```

**V1 binary plist request (tried first):**
```
POST /play HTTP/1.1
Content-Type: application/x-apple-binary-plist
User-Agent: MediaControl/1.0
Content-Length: <len>

<binary plist: {
  Content-Location: <url>,
  Start-Position: <0.0-1.0>,
  X-Apple-Session-ID: <uuid>
}>
```

**V1 text/parameters request (tried second):**
```
POST /play HTTP/1.1
Content-Type: text/parameters
User-Agent: MediaControl/1.0
X-Apple-Session-ID: <uuid>
Content-Length: <len>

Content-Location: http://192.168.6.68:58789/stream/...
Start-Position: 0
```

**V2 binary plist request (tried third, after RTSP setup):**
```
POST /play HTTP/1.1
Content-Type: application/x-apple-binary-plist
User-Agent: AirPlay/550.10
X-Apple-ProtocolVersion: 1
X-Apple-Session-ID: <uuid>
X-Apple-Stream-ID: 1
Content-Length: <len>

<binary plist: {
  Content-Location: <url>,
  Start-Position-Seconds: <seconds>,
  uuid: <uuid>,
  streamType: 1,
  mediaType: "file",
  volume: 1.0,
  rate: 1.0,
  ...extended fields
}>
```

Note: All three formats are sent over the **same encrypted HAP channel** when the device requires pairing. The encryption is transparent at the socket level.

**Playback control (HTTP/1.1 for all, same across V1 and V2):**
- `POST /rate?value=0` — pause
- `POST /rate?value=1` — resume
- `POST /scrub?position=<seconds>` — seek
- `POST /stop` — stop
- `GET /playback-info` — poll position/duration/state (XML plist response)

### 3. Error Handling

- `UnsupportedFeatureException` — device doesn't have video feature bits. Caller (anime_here app) can use this to suggest Chromecast/DLNA instead.
- `PlaybackException` — `/play` rejected after trying all three formats
- `NeedsPairingException` — existing, device requires pair-setup first
- In `AirPlaySession.loadMedia()`: catch `UnsupportedFeatureException` and propagate to the app layer

### 4. Test Strategy

**`AirPlayFeatures` tests:**
- Parse single-part features string (`"0x5A7FFFF7"`)
- Parse two-part features string (`"0x5A7FFFF7,0x1E"`)
- All named flag getters (`supportsVideo`, `supportsVideoV1`, `supportsVideoV2`, `supportsAudio`, `supportsScreen`, `requiresHapPairing`, `isV2Protocol`)
- Edge cases: empty string, `"0x0"`, malformed input, case insensitivity
- Real-world examples: Apple TV flags, Google TV flags (from mDNS capture)
- TXT record key variation (`ft` vs `features`) tested at discovery provider level

**`AirPlayMediaController` tests:**
- `playV1()`: correct binary plist body (`Content-Location`, `Start-Position`, `X-Apple-Session-ID`), `MediaControl/1.0` User-Agent, no RTSP setup called
- `playV1Text()`: correct text/parameters body, correct headers
- `playV2()`: correct extended binary plist body, `AirPlay/550.10` User-Agent, RTSP setup called first, no CSeq/DACP-ID headers on the `/play` request itself
- `play()` auto-selection: tries V1 plist → V1 text → V2, stops at first 200
- `play()` with no video bits: throws `UnsupportedFeatureException`
- `pause()`, `resume()`, `seek()`, `stop()`: sends correct HTTP/1.1 requests
- `getPlaybackInfo()`: parses XML plist response

**Integration tests (encrypted channel):**
- V1 binary plist `/play` over HapSession (server validates format)
- V1 text/parameters `/play` over HapSession
- V2 `/play` over HapSession after RTSP SETUP/RECORD
- Fallback chain: V1 plist 404 → V1 text 404 → V2 attempted

**Updated existing tests:**
- Move media command tests from `HapSession` to `AirPlayMediaController`
- `HapSession` tests remain for encryption, RTSP commands, socket management

### 5. Documentation

**README.md:**
- "AirPlay Capabilities" section: three modes, which are supported now, which are future
- Feature flag detection: how the library auto-detects device capabilities
- "Limitations" section: devices without bit 0/49 need Chromecast/DLNA for video

**CHANGELOG.md:**
- Feature detection via mDNS feature flags
- V1 and V2 `/play` with automatic format negotiation
- `AirPlayMediaController` extracted from `HapSession`
- Breaking: `HapSession` no longer has `play()`/`stop()`/`scrub()`/`rate()` methods

**docs/PROTOCOL_REFERENCES.md:**
- All protocol sources with links

**docs/FUTURE_WORK.md:**
- Sub-project 3: video-as-mirroring (H.264 frame streaming over RTSP type 110)
  - Architecture: URL fetch → demux → decode → H.264 encode → RTP framing → AES-CTR encrypt → TCP stream
  - Requires FFmpeg or platform-native video codecs
  - RTSP SETUP with stream type 110 (mirroring) + encrypted data channel
- RAOP audio streaming (PCM → ALAC/AAC encoding → RTP over UDP)

### 6. Protocol References

- [Unofficial AirPlay Protocol Specification](https://nto.github.io/AirPlay.html)
- [OpenAirPlay Spec](https://openairplay.github.io/airplay-spec/)
- [OpenAirPlay Spec — Video HTTP Requests](https://openairplay.github.io/airplay-spec/video/http_requests.html)
- [OpenAirPlay Spec — Features](https://openairplay.github.io/airplay-spec/features.html)
- [AirPlay 2 Internals — Features](https://emanuelecozzi.net/docs/airplay2/features/)
- [AirPlay 2 Internals — RTSP](https://emanuelecozzi.net/docs/airplay2/rtsp/)
- [pyatv — Apple TV client library](https://github.com/postlund/pyatv)
- [pyatv Issue #1518 — /play 404 on LG TV](https://github.com/postlund/pyatv/issues/1518)
- [pyatv Issue #2204 — Force AirPlay version](https://github.com/postlund/pyatv/issues/2204)
- [watson/airplay-protocol](https://github.com/watson/airplay-protocol) (V1 text/parameters reference)
- [openairplay/airplay2-receiver](https://github.com/openairplay/airplay2-receiver) (AirPlay 2 receiver, no /play handler)
- [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) (AirPlay 2 sender, /play commented out)
- [UxPlay](https://github.com/FDH2/UxPlay) (open-source receiver with /play + mirroring)
