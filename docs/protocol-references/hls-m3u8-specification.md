# HLS M3U8 Specification Reference (RFC 8216)

A comprehensive reference for implementing an m3u8 proxy with URL rewriting, based on RFC 8216 (HTTP Live Streaming).

---

## 1. Master (Multivariant) Playlist Format

A master playlist declares the available renditions (video qualities, audio tracks, subtitle tracks) and points to their respective media playlists.

### Structure Example

```m3u8
#EXTM3U
#EXT-X-VERSION:4

#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en/playlist.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Japanese",LANGUAGE="ja",DEFAULT=NO,AUTOSELECT=YES,URI="audio/ja/playlist.m3u8"

#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subs/en/playlist.m3u8"

#EXT-X-STREAM-INF:BANDWIDTH=2000000,AVERAGE-BANDWIDTH=1800000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=29.970,AUDIO="aac",SUBTITLES="subs"
720p/playlist.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4500000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=29.970,AUDIO="aac",SUBTITLES="subs"
1080p/playlist.m3u8

#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401f",RESOLUTION=1280x720,URI="720p/iframes.m3u8"
```

### #EXT-X-STREAM-INF Attributes

| Attribute | Required | Description |
|-----------|----------|-------------|
| `BANDWIDTH` | **Yes** | Peak segment bit rate in bits/s |
| `AVERAGE-BANDWIDTH` | No | Average segment bit rate in bits/s |
| `CODECS` | Recommended | Comma-separated list of RFC 6381 codec strings |
| `RESOLUTION` | Recommended | Pixel resolution (widthxheight) |
| `FRAME-RATE` | No | Maximum frame rate (decimal floating-point) |
| `AUDIO` | No | GROUP-ID of an audio #EXT-X-MEDIA group |
| `VIDEO` | No | GROUP-ID of a video #EXT-X-MEDIA group |
| `SUBTITLES` | No | GROUP-ID of a subtitles #EXT-X-MEDIA group |
| `CLOSED-CAPTIONS` | No | GROUP-ID or NONE |

**KEY POINT:** The URI for `#EXT-X-STREAM-INF` is on the **NEXT LINE** after the tag. It is NOT an attribute of the tag itself.

```m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
720p/playlist.m3u8     <-- THIS LINE is the URI
```

### #EXT-X-I-FRAME-STREAM-INF

Unlike `#EXT-X-STREAM-INF`, I-frame stream info carries the URI **as an attribute**:

```m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="720p/iframes.m3u8"
```

Attributes: same as `#EXT-X-STREAM-INF` plus `URI` (required), minus `FRAME-RATE`, `AUDIO`, `SUBTITLES`, `CLOSED-CAPTIONS`.

### #EXT-X-MEDIA

Declares alternative renditions (audio tracks, subtitle tracks, camera angles).

| Attribute | Required | Description |
|-----------|----------|-------------|
| `TYPE` | **Yes** | `AUDIO`, `VIDEO`, `SUBTITLES`, or `CLOSED-CAPTIONS` |
| `URI` | No* | URI of the media playlist for this rendition |
| `GROUP-ID` | **Yes** | Group identifier referenced by stream tags |
| `LANGUAGE` | No | RFC 5646 language tag |
| `NAME` | **Yes** | Human-readable description |
| `DEFAULT` | No | `YES` or `NO` (default: `NO`) |
| `AUTOSELECT` | No | `YES` or `NO` (default: `NO`) |
| `FORCED` | No | `YES` or `NO` — only for `TYPE=SUBTITLES` |
| `CHANNELS` | No | Audio channel count string |

*`URI` is required for `TYPE=SUBTITLES`. It is optional for `AUDIO` and `VIDEO` (when absent, the media data is muxed into the variant stream). It MUST NOT be present for `TYPE=CLOSED-CAPTIONS`.

---

## 2. Media (Variant) Playlist Format

A media playlist lists the individual media segments that compose a rendition.

### Structure Example

```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD

#EXTINF:9.009,
segment000.ts
#EXTINF:9.009,
segment001.ts
#EXTINF:9.009,
segment002.ts
#EXTINF:3.003,
segment003.ts

#EXT-X-ENDLIST
```

### Key Tags

#### #EXT-X-TARGETDURATION (required)

Maximum segment duration in seconds (integer, rounded up). Every `#EXTINF` duration MUST be less than or equal to this value.

```m3u8
#EXT-X-TARGETDURATION:10
```

#### #EXT-X-MEDIA-SEQUENCE

The media sequence number of the first segment in the playlist. Defaults to 0 if absent. Each subsequent segment increments by 1.

```m3u8
#EXT-X-MEDIA-SEQUENCE:142
```

#### #EXTINF

Specifies the duration of the segment whose URI follows on the next line.

```
#EXTINF:<duration>,[<title>]
<URI>
```

- `duration`: Decimal floating-point (version >= 3) or integer (version < 3) in seconds.
- `title`: Optional human-readable title string.
- **The segment URI is on the NEXT LINE.**

```m3u8
#EXTINF:9.009,
https://cdn.example.com/seg001.ts
```

#### #EXT-X-BYTERANGE

Indicates that the segment is a sub-range of the resource at the URI.

```
#EXT-X-BYTERANGE:<length>[@<offset>]
```

If offset is absent, the range starts at the byte after the end of the previous sub-range. Example:

```m3u8
#EXTINF:9.009,
#EXT-X-BYTERANGE:500000@0
combined.ts
#EXTINF:9.009,
#EXT-X-BYTERANGE:500000@500000
combined.ts
```

#### #EXT-X-DISCONTINUITY

Indicates an encoding discontinuity between the segment that follows it and the one before it (different codecs, timestamps, etc.).

```m3u8
#EXTINF:9.009,
segment005.ts
#EXT-X-DISCONTINUITY
#EXTINF:9.009,
ad-segment001.ts
```

#### #EXT-X-PLAYLIST-TYPE

Constrains playlist mutability:

| Value | Meaning |
|-------|---------|
| `EVENT` | Server may append segments but MUST NOT remove or alter existing ones |
| `VOD` | Playlist will not change — all segments are present |

If absent, the playlist is a live (sliding window) playlist and segments may be removed from the beginning.

#### #EXT-X-ENDLIST

Indicates no more segments will be added. Present in VOD and completed EVENT playlists.

---

## 3. Encryption — #EXT-X-KEY

Specifies how media segments are encrypted. Applies to all subsequent segments until the next `#EXT-X-KEY` tag.

```m3u8
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/key1.bin",IV=0x00000000000000000000000000000001
```

### Attributes

| Attribute | Required | Description |
|-----------|----------|-------------|
| `METHOD` | **Yes** | `NONE`, `AES-128`, or `SAMPLE-AES` |
| `URI` | Yes* | Quoted URI of the key resource |
| `IV` | No | 128-bit hex initialization vector (0x prefix + 32 hex chars) |
| `KEYFORMAT` | No | Key format identifier (default: identity) |
| `KEYFORMATVERSIONS` | No | Slash-separated integers for key format version |

*`URI` is required unless `METHOD=NONE`. When `METHOD=NONE`, `URI`, `IV`, `KEYFORMAT`, and `KEYFORMATVERSIONS` MUST NOT be present.

### Encryption Modes

- **AES-128:** Full segment encryption. Each segment is encrypted with AES-128-CBC. If `IV` is absent, the media sequence number is used as the IV (zero-padded to 16 bytes, big-endian).
- **SAMPLE-AES:** Individual media samples (NAL units for H.264, audio frames for AAC) are encrypted.

### Proxy Requirement

The `URI` attribute is a quoted string pointing to the decryption key. **This URI MUST be proxied** to avoid exposing the original key server and to maintain session continuity.

```
Original:  #EXT-X-KEY:METHOD=AES-128,URI="https://keys.cdn.com/k1",IV=0x...
Proxied:   #EXT-X-KEY:METHOD=AES-128,URI="https://proxy.example.com/key?url=https%3A%2F%2Fkeys.cdn.com%2Fk1",IV=0x...
```

---

## 4. #EXT-X-MAP — Initialization Segments

Specifies how to obtain the initialization section (e.g., fMP4 moov box) required to parse subsequent media segments.

```m3u8
#EXT-X-MAP:URI="init.mp4"
#EXT-X-MAP:URI="init.mp4",BYTERANGE="812@0"
```

### Attributes

| Attribute | Required | Description |
|-----------|----------|-------------|
| `URI` | **Yes** | Quoted URI of the initialization segment |
| `BYTERANGE` | No | Byte range in format `"<length>[@<offset>]"` |

The `URI` is a quoted string and **must be rewritten** by the proxy.

An `#EXT-X-MAP` tag applies to all subsequent segments until the next `#EXT-X-MAP` tag or until the end of the playlist.

---

## 5. URL Resolution Rules (RFC 3986 Section 5)

All URIs in an HLS playlist are resolved against the playlist's own URL as the base URI, following standard RFC 3986 relative resolution.

### Resolution Cases

Given a playlist fetched from: `https://cdn.example.com/streams/master.m3u8`

| URI in Playlist | Type | Resolved URL |
|----------------|------|--------------|
| `https://other.cdn.com/720p/playlist.m3u8` | Absolute URI (has scheme) | `https://other.cdn.com/720p/playlist.m3u8` |
| `//other.cdn.com/720p/playlist.m3u8` | Protocol-relative | `https://other.cdn.com/720p/playlist.m3u8` |
| `/live/720p/playlist.m3u8` | Absolute path | `https://cdn.example.com/live/720p/playlist.m3u8` |
| `720p/playlist.m3u8` | Relative path | `https://cdn.example.com/streams/720p/playlist.m3u8` |
| `../other/playlist.m3u8` | Relative with parent | `https://cdn.example.com/other/playlist.m3u8` |

### Resolution Algorithm

```
function resolveURI(baseURL, uri):
    if uri starts with a scheme (http://, https://):
        return uri                                        # absolute
    if uri starts with "//":
        return baseURL.scheme + ":" + uri                 # protocol-relative
    if uri starts with "/":
        return baseURL.scheme + "://" + baseURL.host + uri  # absolute path
    else:
        basePath = baseURL up to and including last "/"
        return basePath + uri                             # relative path
        (then normalize: resolve ".." and "." segments per RFC 3986 Section 5.2.4)
```

### Base URL for Nested Playlists

When a master playlist references a variant playlist at `720p/playlist.m3u8`, and that variant playlist contains segment URIs, those segments resolve against the variant playlist's resolved URL, NOT the master playlist.

```
Master:   https://cdn.example.com/streams/master.m3u8
Variant:  https://cdn.example.com/streams/720p/playlist.m3u8  (resolved from master)
Segment:  https://cdn.example.com/streams/720p/seg001.ts      (resolved from variant)
```

---

## 6. Complete List of Tags with URIs

### Pattern A: URI on NEXT LINE

These tags do NOT have a URI attribute. The URI is the next non-blank, non-comment line following the tag.

| Tag | Context | Description |
|-----|---------|-------------|
| `#EXT-X-STREAM-INF` | Master playlist | Variant stream playlist URL |
| `#EXTINF` | Media playlist | Media segment URI |
| *(bare non-# line)* | Media playlist | Segment URI (always follows `#EXTINF` or `#EXT-X-BYTERANGE`) |

**Parsing rule:** After encountering `#EXT-X-STREAM-INF` or `#EXTINF`, read lines until you find a non-empty line that does not start with `#`. That line is the URI.

```
State machine:
  [IDLE] --#EXT-X-STREAM-INF--> [EXPECT_VARIANT_URI]
  [IDLE] --#EXTINF-----------> [EXPECT_SEGMENT_URI]
  [EXPECT_*_URI] --non-empty non-# line--> rewrite URI, return to [IDLE]
  [EXPECT_*_URI] --#EXT-X-BYTERANGE-----> stay in [EXPECT_SEGMENT_URI]
```

### Pattern B: URI as Quoted Attribute (URI="...")

These tags carry the URI **inside the tag line itself** as a quoted attribute value.

| Tag | Context | URI Required? | Description |
|-----|---------|---------------|-------------|
| `#EXT-X-MEDIA` | Master playlist | Optional* | Alternative rendition playlist |
| `#EXT-X-I-FRAME-STREAM-INF` | Master playlist | **Yes** | I-frame-only variant |
| `#EXT-X-KEY` | Media playlist | Yes (unless METHOD=NONE) | Decryption key |
| `#EXT-X-MAP` | Media playlist | **Yes** | Initialization segment |
| `#EXT-X-SESSION-KEY` | Master playlist | Yes (unless METHOD=NONE) | Session-level key (preload hint) |
| `#EXT-X-SESSION-DATA` | Master playlist | Optional** | Session metadata |

*`#EXT-X-MEDIA`: URI is required for `TYPE=SUBTITLES`, optional for `AUDIO`/`VIDEO`, must not be present for `CLOSED-CAPTIONS`.

**`#EXT-X-SESSION-DATA`: Has either `VALUE` or `URI`, not both.

### Rewriting URI Attributes

To rewrite a URI attribute, find the pattern `URI="<value>"` within the tag line and replace `<value>` with the proxied URL. The URI value is always enclosed in double quotes.

```
Regex pattern:  (URI=")([^"]*)(")
Replacement:    $1 + proxyUrl(resolveURI(baseURL, $2)) + $3
```

**Important edge cases:**
- The URI value may contain query strings with `&`, `=`, and other characters.
- The URI value may be URL-encoded.
- Double quotes within the URI value should not occur per the spec, but handle defensively.

---

## 7. Subtitle Playlist Format

### Master Playlist Declaration

```m3u8
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subs/en/playlist.m3u8"
```

### Subtitle Media Playlist

```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD

#EXTINF:10.000,
subs_segment_000.vtt
#EXTINF:10.000,
subs_segment_001.vtt
#EXTINF:10.000,
subs_segment_002.vtt

#EXT-X-ENDLIST
```

### WebVTT Segment Format

Each subtitle segment is a standalone WebVTT file. The first segment SHOULD contain the `X-TIMESTAMP-MAP` header to align WebVTT timestamps with MPEG-TS or fMP4 presentation timestamps.

```vtt
WEBVTT
X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

00:00:01.000 --> 00:00:04.000
This is the first subtitle line.

00:00:05.000 --> 00:00:08.000
This is the second subtitle line.
```

- `MPEGTS` value is in 90kHz clock ticks (MPEG-TS PTS).
- `LOCAL` is the WebVTT timestamp that corresponds to the MPEGTS value.
- Without this header, subtitle synchronization will drift in segmented delivery.

### Proxy Considerations for Subtitles

- The subtitle playlist is a standard media playlist; segment URIs follow the same rewriting rules.
- WebVTT segment files themselves do not contain URIs and do not need rewriting.
- Subtitle playlists may reference segments on different CDN domains than video segments.

---

## 8. Content-Type / MIME Types

### Playlist MIME Types

| Content | MIME Type | File Extensions |
|---------|-----------|-----------------|
| HLS Playlist (preferred) | `application/vnd.apple.mpegurl` | `.m3u8` |
| HLS Playlist (legacy) | `audio/mpegurl` | `.m3u8`, `.m3u` |
| HLS Playlist (also seen) | `application/x-mpegURL` | `.m3u8` |

### Segment MIME Types

| Content | MIME Type | File Extensions |
|---------|-----------|-----------------|
| MPEG-2 Transport Stream | `video/MP2T` | `.ts`, `.tsv`, `.tsa` |
| Fragmented MP4 (video) | `video/mp4` | `.m4s`, `.mp4`, `.m4v` |
| Fragmented MP4 (audio) | `audio/mp4` | `.m4s`, `.m4a` |
| AAC audio (raw) | `audio/aac` | `.aac` |
| AC-3 audio | `audio/ac3` | `.ac3` |
| E-AC-3 audio | `audio/eac3` | `.ec3` |
| Packed audio | `application/octet-stream` | varies |

### Other Resource MIME Types

| Content | MIME Type | File Extensions |
|---------|-----------|-----------------|
| WebVTT subtitles | `text/vtt` | `.vtt` |
| Encryption keys | `application/octet-stream` | `.key`, `.bin`, varies |
| Initialization segments | Same as segment type | `.mp4`, `.m4s` |

### Proxy Response Headers

When serving proxied responses, set these headers:

```
Content-Type: <appropriate MIME type>
Access-Control-Allow-Origin: *
Access-Control-Allow-Headers: Range
Access-Control-Expose-Headers: Content-Range, Content-Length
```

For segment requests, also forward/set:
```
Accept-Ranges: bytes
Content-Range: bytes <start>-<end>/<total>    (if byte-range request)
```

---

## 9. Proxy Implementation Strategy

### High-Level Architecture

```
Client (video player)
    |
    v
[HLS Proxy Server]
    |-- Rewrites m3u8 URIs to point through proxy
    |-- Forwards segment/key/init requests to origin
    |-- Sets correct CORS and Content-Type headers
    |
    v
Origin CDN / Streaming Server
```

### Playlist Proxying Algorithm

```
function proxyPlaylist(playlistURL, requestHeaders):
    1. Fetch original playlist from playlistURL (forward relevant headers)
    2. Determine playlist type (master vs media)
    3. Parse and rewrite line by line
    4. Return rewritten playlist with correct Content-Type
```

### Line-by-Line Parsing

```
function rewritePlaylist(content, playlistBaseURL):
    lines = content.split("\n")
    result = []
    expectURI = false

    for each line in lines:
        if line is empty or line == "#EXTM3U" or line == "#EXT-X-ENDLIST":
            result.append(line)
            continue

        # Pattern A: tags where next line is URI
        if line starts with "#EXT-X-STREAM-INF:":
            result.append(line)
            expectURI = true
            continue

        if line starts with "#EXTINF:":
            result.append(line)
            expectURI = true
            continue

        # A #EXT-X-BYTERANGE can appear between #EXTINF and the URI
        if line starts with "#EXT-X-BYTERANGE:" and expectURI:
            result.append(line)
            continue  # still expecting URI

        # Pattern B: tags with URI attribute
        if line starts with "#EXT-X-KEY:" or
           line starts with "#EXT-X-MAP:" or
           line starts with "#EXT-X-MEDIA:" or
           line starts with "#EXT-X-I-FRAME-STREAM-INF:" or
           line starts with "#EXT-X-SESSION-KEY:" or
           line starts with "#EXT-X-SESSION-DATA:":
            result.append(rewriteURIAttribute(line, playlistBaseURL))
            continue

        # Non-tag, non-empty line
        if expectURI and not line starts with "#":
            resolvedURL = resolveURI(playlistBaseURL, line.trim())
            result.append(buildProxyURL(resolvedURL))
            expectURI = false
            continue

        # Any other tag or comment
        result.append(line)
        expectURI = false  # reset if unexpected tag encountered

    return result.join("\n")
```

### Rewriting URI Attributes

```
function rewriteURIAttribute(line, baseURL):
    match = regex.find(line, /URI="([^"]*)"/)
    if match is null:
        return line   # no URI attribute (e.g., #EXT-X-MEDIA without URI)

    originalURI = match.group(1)
    resolvedURL = resolveURI(baseURL, originalURI)
    proxiedURL = buildProxyURL(resolvedURL)
    return line.replace('URI="' + originalURI + '"', 'URI="' + proxiedURL + '"')
```

### Proxy URL Construction

```
function buildProxyURL(originalURL):
    # URL-encode the original URL and wrap it in the proxy path
    return PROXY_BASE + "/proxy?url=" + urlEncode(originalURL)
    # Alternatively, use base64 encoding to avoid double-encoding issues:
    # return PROXY_BASE + "/proxy/" + base64UrlEncode(originalURL)
```

### Distinguishing Master vs Media Playlists

| Indicator | Master Playlist | Media Playlist |
|-----------|----------------|----------------|
| `#EXT-X-STREAM-INF` | Present | Absent |
| `#EXT-X-I-FRAME-STREAM-INF` | May be present | Absent |
| `#EXT-X-MEDIA` | May be present | Absent |
| `#EXT-X-TARGETDURATION` | Absent | Present |
| `#EXTINF` | Absent | Present |

A simple heuristic: if the playlist contains `#EXT-X-STREAM-INF`, treat it as a master playlist. Otherwise, treat it as a media playlist.

### Segment and Key Proxying

For non-playlist resources (segments, keys, initialization segments):

```
function proxyResource(originalURL, clientRequest):
    headers = {}

    # Forward Range header for byte-range requests
    if clientRequest has "Range" header:
        headers["Range"] = clientRequest.headers["Range"]

    # Forward relevant headers from client
    if clientRequest has "Accept" header:
        headers["Accept"] = clientRequest.headers["Accept"]

    response = fetch(originalURL, headers)

    # Set correct Content-Type based on file extension or origin response
    contentType = determineContentType(originalURL, response)

    # Set CORS headers
    responseHeaders = {
        "Content-Type": contentType,
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Range",
        "Access-Control-Expose-Headers": "Content-Range, Content-Length",
    }

    # Forward Content-Range for byte-range responses
    if response has "Content-Range" header:
        responseHeaders["Content-Range"] = response.headers["Content-Range"]
        responseHeaders["Accept-Ranges"] = "bytes"

    return (response.statusCode, responseHeaders, response.body)
```

### Handling Headers from Origin

Forward these headers from the origin server to the client:

| Header | When |
|--------|------|
| `Content-Type` | Always |
| `Content-Length` | Always (if present) |
| `Content-Range` | Byte-range responses (HTTP 206) |
| `Accept-Ranges` | If origin supports ranges |
| `Cache-Control` | Recommended for CDN behavior |
| `ETag` / `Last-Modified` | For conditional requests |

### Live (Sliding Window) Playlist Handling

For live streams (playlists without `#EXT-X-PLAYLIST-TYPE` or `#EXT-X-ENDLIST`):

- The proxy must NOT cache the playlist aggressively; re-fetch on each client request or respect `Cache-Control` / `#EXT-X-TARGETDURATION` for TTL.
- `#EXT-X-MEDIA-SEQUENCE` changes as old segments are removed.
- The proxy should handle playlist reload intervals: clients will re-request the playlist at intervals roughly equal to `#EXT-X-TARGETDURATION`.

### Error Handling

- If the origin returns a non-2xx status for a playlist, return the same status to the client.
- If the origin is unreachable, return HTTP 502 (Bad Gateway).
- If the playlist content does not start with `#EXTM3U`, it is not a valid HLS playlist; return HTTP 502.
- For segment requests, stream the response body directly to avoid buffering large files in memory.

---

## Appendix A: Quick-Reference Tag Summary

| Tag | Playlist Type | Has URI? | URI Location |
|-----|--------------|----------|--------------|
| `#EXTM3U` | Both | No | -- |
| `#EXT-X-VERSION` | Both | No | -- |
| `#EXT-X-STREAM-INF` | Master | Yes | Next line |
| `#EXT-X-I-FRAME-STREAM-INF` | Master | Yes | Attribute |
| `#EXT-X-MEDIA` | Master | Optional | Attribute |
| `#EXT-X-SESSION-KEY` | Master | Yes* | Attribute |
| `#EXT-X-SESSION-DATA` | Master | Optional | Attribute |
| `#EXTINF` | Media | Yes | Next line |
| `#EXT-X-TARGETDURATION` | Media | No | -- |
| `#EXT-X-MEDIA-SEQUENCE` | Media | No | -- |
| `#EXT-X-KEY` | Media | Yes* | Attribute |
| `#EXT-X-MAP` | Media | Yes | Attribute |
| `#EXT-X-BYTERANGE` | Media | No | -- |
| `#EXT-X-DISCONTINUITY` | Media | No | -- |
| `#EXT-X-DISCONTINUITY-SEQUENCE` | Media | No | -- |
| `#EXT-X-PLAYLIST-TYPE` | Media | No | -- |
| `#EXT-X-ENDLIST` | Media | No | -- |
| `#EXT-X-PROGRAM-DATE-TIME` | Media | No | -- |
| `#EXT-X-DATERANGE` | Media | No | -- |
| `#EXT-X-INDEPENDENT-SEGMENTS` | Both | No | -- |
| `#EXT-X-START` | Both | No | -- |

*Unless `METHOD=NONE`.

## Appendix B: Common Pitfalls

1. **Treating `#EXT-X-STREAM-INF` URI as an attribute.** The URI is always on the next line, never `URI="..."`.

2. **Forgetting `#EXT-X-KEY` URI rewriting.** If the key URI is not proxied, the player will either fail to fetch the key (CORS) or expose the origin server.

3. **Not resolving relative URIs.** Many playlists use relative paths. Always resolve against the playlist's base URL before proxying.

4. **Using the master playlist URL as base for segment URIs.** Segments in a media playlist resolve against the media playlist URL, not the master.

5. **Not forwarding Range headers.** Byte-range requests (`#EXT-X-BYTERANGE`) and player-initiated range requests will fail if the proxy does not forward the `Range` header.

6. **Caching live playlists.** Live playlists change frequently. Cache duration should not exceed `#EXT-X-TARGETDURATION`.

7. **Buffering entire segments in memory.** Stream segment responses to avoid excessive memory consumption for large segments (which can be several megabytes).

8. **Ignoring `#EXT-X-MAP`.** fMP4 streams require the initialization segment. If its URI is not proxied, the player cannot parse any segments.

9. **Missing CORS headers.** Browsers require `Access-Control-Allow-Origin` on all proxied responses for web-based players.

10. **Not handling `#EXT-X-BYTERANGE` between `#EXTINF` and segment URI.** A byte-range tag can appear between the EXTINF and the URI line; the parser must not reset the "expecting URI" state.
