# Local File Casting

Guide to casting local video files (especially MPEG-TS) with dart_cast.

## Problem

Chromecast's Default Media Receiver **cannot play raw `.ts` files**. Its MPEG-TS
demuxer only exists for processing HLS segments — it expects a parent HLS
playlist to set up the pipeline. Feeding it a bare TS URL results in a
`MEDIA_ERROR_DECODE` or silent failure.

DLNA devices, by contrast, play `.ts` files directly with no issues.

This means local `.ts` files (common from anime/TV downloads) need special
handling before they can be cast to a Chromecast.

## Approaches

Listed in order of recommendation.

### 1. Remux to MP4 (Recommended)

Re-wrap the TS container into MP4 without re-encoding:

```bash
ffmpeg -fflags +genpts -i input.ts -map 0 -map -0:d -c copy \
       -movflags +faststart output.mp4
```

**Why this works:**
- No re-encoding — just moves packets from TS to MP4 container
- Takes ~3-5 seconds for a 24-minute episode
- MP4 is natively supported by Chromecast, DLNA, AirPlay, and virtually
  every device
- `-movflags +faststart` moves the moov atom to the front so streaming
  starts immediately
- `-map 0 -map -0:d` copies all streams except data streams (which can
  cause MP4 muxer errors)
- `-fflags +genpts` regenerates timestamps, fixing files with broken PTS

**Integration with dart_cast:**

Implement a custom `MediaTransformer` that shells out to ffmpeg. See the
example app's `FfmpegMediaTransformer` for a complete reference
implementation:

```dart
final session = await device.connect(
  mediaTransformer: FfmpegMediaTransformer(),
);
```

**Best practice:** Remux at download time, not at cast time. If your app
downloads `.ts` files, remux them to `.mp4` immediately after download
completes. This avoids any delay when the user hits play.

### 2. TsHlsMediaTransformer (Built-in Fallback)

dart_cast includes `TsHlsMediaTransformer`, which splits a local `.ts` file
into virtual HLS segments at keyframe boundaries. No external tools needed.

```dart
final session = await device.connect(
  mediaTransformer: TsHlsMediaTransformer(),
);
```

**Known issues:**
- **Per-segment buffering** — Chromecast buffers each HLS segment
  independently, causing brief pauses at segment boundaries
- **Subtitle drift** — VBR content accumulates timing errors over long files
- **Slow seeking** — seeking far from the current position requires
  downloading intervening segment headers
- **PTS sensitivity** — files with non-zero starting PTS or damaged first
  PES packet may have A/V desync
- **HEVC incompatibility** — Chromecast does not support HEVC (H.265) in
  HLS; use H.264 only

**When to use:** Quick testing, DLNA targets (which handle TS natively
anyway), short clips, or environments where ffmpeg is unavailable.

### 3. Full Transcode (Heavy)

Re-encode the video to H.264 + AAC in an MP4 container:

```bash
ffmpeg -i input.ts -c:v libx264 -c:a aac -movflags +faststart output.mp4
```

**When to use:** Only when the source codec is incompatible with the target
device (e.g., HEVC source targeting Chromecast, or VP9 source targeting
DLNA).

This is not implemented in dart_cast. Use ffmpeg externally or via
`ffmpeg_kit_flutter_new` on mobile platforms.

## Using a Custom MediaTransformer

The `MediaTransformer` interface has a single method:

```dart
abstract class MediaTransformer {
  Future<TransformedMedia> transform(CastMedia media, MediaProxy proxy);
}
```

Here is a minimal ffmpeg-remux transformer:

```dart
import 'dart:io';
import 'package:dart_cast/dart_cast.dart';
import 'package:path/path.dart' as p;

class FfmpegRemuxTransformer extends DefaultMediaTransformer {
  @override
  Future<TransformedMedia> transform(CastMedia media, MediaProxy proxy) async {
    // Only remux local .ts files; delegate everything else.
    if (!media.isLocalFile || media.type != CastMediaType.mpegTs) {
      return super.transform(media, proxy);
    }

    final mp4Path = p.setExtension(media.url, '.mp4');

    if (!File(mp4Path).existsSync()) {
      final result = await Process.run('ffmpeg', [
        '-fflags', '+genpts',
        '-i', media.url,
        '-map', '0', '-map', '-0:d',
        '-c', 'copy',
        '-movflags', '+faststart',
        mp4Path,
      ]);
      if (result.exitCode != 0) {
        // Remux failed — fall back to serving the .ts directly
        File(mp4Path).deleteSync(recursive: false);
        return super.transform(media, proxy);
      }
    }

    final proxyUrl = proxy.registerFile(mp4Path);
    return TransformedMedia(proxyUrl: proxyUrl, effectiveType: CastMediaType.mp4);
  }
}
```

For a production-ready version with progress callbacks and mobile platform
support, see `example/lib/ffmpeg_media_transformer.dart`.

## References

- [Google Cast Supported Media](https://developers.google.com/cast/docs/media)
  — official list of codecs and containers supported by Chromecast
- [go-chromecast](https://github.com/vishen/go-chromecast) — Go-based
  Chromecast CLI that transcodes local files via ffmpeg
- [VLC Chromecast support](https://wiki.videolan.org/Chromecast/) —
  transcodes to Matroska/WebM before casting
- [CATT](https://github.com/skorokithakis/catt) — Cast All The Things,
  Python CLI (no local file support)
- [RFC 8216 (HLS spec)](https://tools.ietf.org/html/rfc8216) — HTTP Live
  Streaming specification
