/// A [MediaTransformer] that remuxes local MPEG-TS files to MP4 using ffmpeg
/// before casting.
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
/// - **Android / iOS (Flutter):** `Process.run` is not available. Swap
///   [FfmpegRemuxer] internals to use `FFmpegKit.execute` from the
///   `ffmpeg_kit_flutter_new` package instead.
///
/// ## Behaviour
///
/// 1. Non-local or non-TS media is delegated to [DefaultMediaTransformer].
/// 2. If an `.mp4` file already exists next to the `.ts` file, it is used
///    directly (skip remux).
/// 3. Otherwise, [FfmpegRemuxer.remuxToMp4] shells out to ffmpeg to create
///    the `.mp4`.
/// 4. On remux failure, the partial `.mp4` is deleted and the original `.ts`
///    is served directly as a fallback.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:path/path.dart' as p;

/// Callback invoked with a progress message during remux.
typedef RemuxProgressCallback = void Function(String message);

/// Utility that remuxes MPEG-TS files to MP4 using the system `ffmpeg` binary.
///
/// This implementation uses [Process.run], which works on desktop platforms
/// (Windows, Linux, macOS). On mobile platforms (Android/iOS), replace the
/// [Process.run] call with `FFmpegKit.execute` from the
/// `ffmpeg_kit_flutter_new` package.
class FfmpegRemuxer {
  /// Remuxes a TS file to MP4 using ffmpeg.
  ///
  /// Returns the output path on success, `null` on failure.
  /// Cleans up partial output on failure.
  ///
  /// The ffmpeg command copies all streams (no re-encoding), drops data
  /// streams to avoid muxer errors, regenerates PTS timestamps, and moves
  /// the moov atom to the front for streaming.
  static Future<String?> remuxToMp4(
    String inputPath, {
    String? outputPath,
    void Function(String message)? onProgress,
  }) async {
    final mp4Path = outputPath ?? p.setExtension(inputPath, '.mp4');
    final stopwatch = Stopwatch()..start();

    onProgress?.call('Remuxing ${p.basename(inputPath)} → .mp4');

    try {
      final result = await Process.run('ffmpeg', [
        '-fflags', '+genpts',
        '-i', inputPath,
        '-map', '0',
        '-map', '-0:d',
        '-c', 'copy',
        '-movflags', '+faststart',
        '-y',
        mp4Path,
      ]);

      stopwatch.stop();

      if (result.exitCode == 0) {
        final elapsed =
            (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        onProgress?.call('Remux complete (${elapsed}s)');
        return mp4Path;
      }

      final lastLine = result.stderr.toString().split('\n').last;
      onProgress?.call('Remux failed (exit ${result.exitCode}): $lastLine');
      _deletePartial(mp4Path);
      return null;
    } catch (e) {
      onProgress?.call('Remux failed: $e');
      _deletePartial(mp4Path);
      return null;
    }
  }

  /// Deletes a partial output file if it exists.
  static void _deletePartial(String path) {
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

/// A [MediaTransformer] that remuxes local MPEG-TS files to MP4 via ffmpeg.
///
/// Extends [DefaultMediaTransformer] so remote URLs and non-TS local files
/// pass through unchanged. Only local `.ts` files trigger the remux path.
class FfmpegMediaTransformer extends DefaultMediaTransformer {
  /// Optional callback invoked with progress messages during remux.
  ///
  /// Example messages: `"Remuxing file.ts → .mp4"`,
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
    if (!media.isLocalFile || media.type != CastMediaType.mpegTs) {
      return super.transform(media, proxy);
    }

    final mp4Path = p.setExtension(media.url, '.mp4');
    final mp4File = File(mp4Path);

    if (!mp4File.existsSync()) {
      final result = await FfmpegRemuxer.remuxToMp4(
        media.url,
        outputPath: mp4Path,
        onProgress: onProgress,
      );

      if (result == null) {
        onProgress?.call('Remux failed, falling back to .ts');
        return super.transform(media, proxy);
      }
    }

    final proxyUrl = proxy.registerFile(mp4Path);
    return TransformedMedia(
      proxyUrl: proxyUrl,
      effectiveType: CastMediaType.mp4,
    );
  }
}
