# Play local videos in the example app

## Goal

Let a user of the `dart_cast` example app pick a video file from their device
and cast it, on every platform the example builds (Android, iOS, macOS,
Windows, Linux).

## Background

The package already supports local files: `CastMedia.file(filePath: ...)` sets
`isLocalFile = true`, and every protocol session (Chromecast, AirPlay, DLNA)
serves local files over HTTP through the built-in `MediaProxy`. No package
changes are needed — only the example app, which today can add media solely by
typing a URL into a text field (`device_discovery_page.dart`).

macOS sandbox is already disabled in the example's entitlements and the network
server/client entitlements are present, so the proxy's HTTP server and the file
picker both work with no additional platform wiring.

## Design

### 1. Dependency

Add `file_picker` to `example/pubspec.yaml`. It uses the OS-native picker on all
target platforms and needs no runtime storage permission or per-platform
manifest changes for picking user-selected files.

### 2. UI (`device_discovery_page.dart`)

Add a **"Pick local video"** button alongside the existing custom-URL control.
On tap:

1. Call `FilePicker.platform.pickFiles(type: FileType.video)`.
2. If a file is returned, take `result.files.single.path` (absolute path).
3. Detect `CastMediaType` from the extension via the existing
   `_detectMediaType` helper (lowercases; matches `.m3u8`/`.ts`/`.mkv`, else
   mp4).
4. Build `CastMedia.file(filePath: path, type: type, title: <file name>,
   subtitles: ...)`.
5. Add it to the existing `_customMedia` list.

The existing media-list rendering and cast flow are unchanged — `MediaProxy`
serves the local file automatically for every protocol.

### 3. Subtitles

Reuse the existing custom subtitle-URL text field: if it holds a value when a
file is picked, attach it as a `CastSubtitle`, mirroring the current URL flow.

### 4. Docs

Add a short note to `example/README.md` that local files can now be cast and are
served over HTTP by the built-in proxy.

## Out of scope (YAGNI)

- Local subtitle-file picking (clean follow-up).
- Web platform.
- Thumbnail / duration extraction from the picked file.

## Testing

- `flutter analyze` clean in `example/` (CI fails on info-level too).
- Manual: pick an mp4/mkv/ts file and confirm it appears in the media list and
  casts to a discovered device.
