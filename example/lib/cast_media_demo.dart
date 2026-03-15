import 'package:dart_cast/dart_cast.dart';

/// Provides sample media items for testing cast functionality.
///
/// These are publicly available test streams. Replace with your own
/// media URLs for production use.
class CastMediaDemo {
  CastMediaDemo._();

  /// Sample HLS live stream (Big Buck Bunny).
  static const hlsStream = CastMedia(
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    type: CastMediaType.hls,
    title: 'Big Buck Bunny (HLS)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/220px-Big_buck_bunny_poster_big.jpg',
  );

  /// Sample MP4 video (Elephants Dream).
  static const mp4Video = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    type: CastMediaType.mp4,
    title: 'Elephants Dream (MP4)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Elephants_Dream_s5_both.jpg/220px-Elephants_Dream_s5_both.jpg',
  );

  /// Sample MP4 video with subtitles (Sintel).
  static const videoWithSubtitles = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
    type: CastMediaType.mp4,
    title: 'Sintel (with Subtitles)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Sintel_poster.jpg/220px-Sintel_poster.jpg',
    subtitles: [
      CastSubtitle(
        url:
            'https://raw.githubusercontent.com/nicholasgasior/gcs-test-data/master/sintel-en.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      ),
      CastSubtitle(
        url:
            'https://raw.githubusercontent.com/nicholasgasior/gcs-test-data/master/sintel-es.vtt',
        label: 'Spanish',
        language: 'es',
        format: 'vtt',
      ),
    ],
  );

  /// All available sample media items.
  static const List<CastMedia> allMedia = [
    hlsStream,
    mp4Video,
    videoWithSubtitles,
  ];
}
