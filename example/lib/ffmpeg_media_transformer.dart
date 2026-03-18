/// Reference implementation of a [MediaTransformer] that remuxes local
/// MPEG-TS files to MP4 using ffmpeg before casting.
///
/// ## Why remux?
///
/// Chromecast's Default Media Receiver cannot play raw `.ts` files — its TS
/// demuxer only exists for HLS segment processing. Remuxing to MP4 (no
/// re-encoding) takes ~3-5 seconds for a 24-minute episode and produces a
/// file natively supported by Chromecast, DLNA, and AirPlay.
///
/// ## Usage
///
/// ```dart
/// final session = await device.connect(
///   mediaTransformer: FfmpegMediaTransformer(),
/// );
/// await session.load(CastMedia.file(
///   filePath: '/path/to/episode.ts',
///   type: CastMediaType.mpegTs,
/// ));
/// ```
///
/// ## Platform requirements
///
/// - **Windows / Linux / macOS:** Requires `ffmpeg` on the system PATH.
///   Install via your package manager (e.g., `brew install ffmpeg`,
///   `apt install ffmpeg`, `choco install ffmpeg`).
///
/// - **Android / iOS / macOS (Flutter):** Use the `ffmpeg_kit_flutter_new`
///   package instead of `Process.run`. See the commented-out `_remuxMobile`
///   method below for a ready-to-uncomment implementation.
///
/// ## Behaviour
///
/// 1. Non-local or non-TS media is delegated to [DefaultMediaTransformer].
/// 2. If an `.mp4` file already exists next to the `.ts` file, it is used
///    directly (skip remux).
/// 3. Otherwise, `_remux()` shells out to ffmpeg to create the `.mp4`.
/// 4. On remux failure, the partial `.mp4` is deleted and the original `.ts`
///    is served directly as a fallback.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:path/path.dart' as p;

/// Callback invoked with a progress message during remux.
typedef RemuxProgressCallback = void Function(String message);

/// A [MediaTransformer] that remuxes local MPEG-TS files to MP4 via ffmpeg.
///
/// Extends [DefaultMediaTransformer] so remote URLs and non-TS local files
/// pass through unchanged. Only local `.ts` files trigger the remux path.
class FfmpegMediaTransformer extends DefaultMediaTransformer {
  /// Whether to wrap remote MPEG-TS URLs in HLS.
  ///
  /// Passed through to [DefaultMediaTransformer]. Defaults to `true` so
  /// remote TS streams also work on Chromecast.
  // (inherited from super.wrapRemoteTs)

  /// Optional callback invoked with progress messages during remux.
  ///
  /// Example messages: `"Remuxing /path/to/file.ts → .mp4"`,
  /// `"Remux complete (3.2s)"`, `"Remux failed: ..."`.
  final RemuxProgressCallback? onProgress;

  /// Creates an [FfmpegMediaTransformer].
  ///
  /// [wrapRemoteTs] defaults to `true` — remote TS URLs are wrapped in HLS
  /// for Chromecast compatibility. Set to `false` if you only target DLNA.
  ///
  /// [onProgress] receives human-readable status messages during the remux
  /// process, suitable for displaying in a UI snackbar or log.
  FfmpegMediaTransformer({
    super.wrapRemoteTs = true,
    this.onProgress,
  });

  @override
  Future<TransformedMedia> transform(
    CastMedia media,
    MediaProxy proxy,
  ) async {
    // Only handle local MPEG-TS files; delegate everything else.
    if (!media.isLocalFile || media.type != CastMediaType.mpegTs) {
      return super.transform(media, proxy);
    }

    final mp4Path = p.setExtension(media.url, '.mp4');
    final mp4File = File(mp4Path);

    // If the MP4 already exists (e.g., remuxed at download time), use it.
    if (!mp4File.existsSync()) {
      final success = await _remux(media.url, mp4Path);
      if (!success) {
        // Remux failed — fall back to serving the raw .ts file.
        // This works fine for DLNA; Chromecast will likely fail.
        onProgress?.call('Remux failed, falling back to .ts');
        return super.transform(media, proxy);
      }
    }

    // Serve the MP4 via the proxy.
    final proxyUrl = proxy.registerFile(mp4Path);
    return TransformedMedia(
      proxyUrl: proxyUrl,
      effectiveType: CastMediaType.mp4,
    );
  }

  /// Remuxes [tsPath] to [mp4Path] using ffmpeg.
  ///
  /// Returns `true` on success, `false` on failure (partial file is deleted).
  Future<bool> _remux(String tsPath, String mp4Path) async {
    onProgress?.call('Remuxing ${p.basename(tsPath)} → .mp4');
    final stopwatch = Stopwatch()..start();

    try {
      // Desktop platforms: shell out to ffmpeg via Process.run.
      final result = await Process.run('ffmpeg', [
        '-fflags', '+genpts', // Regenerate PTS for broken files
        '-i', tsPath, // Input TS file
        '-map', '0', // Copy all streams...
        '-map', '-0:d', // ...except data streams (avoids muxer errors)
        '-c', 'copy', // No re-encoding
        '-movflags', '+faststart', // Move moov atom to front for streaming
        '-y', // Overwrite output without asking
        mp4Path,
      ]);

      stopwatch.stop();

      if (result.exitCode == 0) {
        final elapsed = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        onProgress?.call('Remux complete (${elapsed}s)');
        return true;
      }

      // Log stderr for debugging.
      onProgress?.call('Remux failed (exit ${result.exitCode}): '
          '${result.stderr.toString().split('\n').last}');
      _deletePartial(mp4Path);
      return false;
    } catch (e) {
      onProgress?.call('Remux failed: $e');
      _deletePartial(mp4Path);
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Mobile platform support (Android / iOS / macOS via Flutter)
  // -----------------------------------------------------------------------
  // Uncomment the method below and add `ffmpeg_kit_flutter_new` to your
  // pubspec.yaml dependencies to use ffmpeg on mobile platforms:
  //
  //   dependencies:
  //     ffmpeg_kit_flutter_new: ^6.0.3
  //
  // Then replace the `_remux` call in `transform()` with `_remuxMobile`.
  //
  // ```dart
  // import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
  // import 'package:ffmpeg_kit_flutter_new/return_code.dart';
  //
  // Future<bool> _remuxMobile(String tsPath, String mp4Path) async {
  //   onProgress?.call('Remuxing ${p.basename(tsPath)} → .mp4');
  //   final stopwatch = Stopwatch()..start();
  //
  //   try {
  //     final session = await FFmpegKit.execute(
  //       '-fflags +genpts -i "$tsPath" -map 0 -map -0:d '
  //       '-c copy -movflags +faststart -y "$mp4Path"',
  //     );
  //
  //     stopwatch.stop();
  //     final returnCode = await session.getReturnCode();
  //
  //     if (ReturnCode.isSuccess(returnCode)) {
  //       final elapsed =
  //           (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
  //       onProgress?.call('Remux complete (${elapsed}s)');
  //       return true;
  //     }
  //
  //     final logs = await session.getLogsAsString();
  //     onProgress?.call('Remux failed: $logs');
  //     _deletePartial(mp4Path);
  //     return false;
  //   } catch (e) {
  //     onProgress?.call('Remux failed: $e');
  //     _deletePartial(mp4Path);
  //     return false;
  //   }
  // }
  // ```
  // -----------------------------------------------------------------------

  /// Deletes a partial MP4 file if it exists.
  void _deletePartial(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Best-effort cleanup; ignore errors.
    }
  }
}
