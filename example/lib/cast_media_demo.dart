import 'package:dart_cast/dart_cast.dart';

/// Provides sample media items for testing cast functionality.
///
/// These are publicly available test streams. Replace with your own
/// media URLs for production use.
class CastMediaDemo {
  CastMediaDemo._();

  /// Sample HLS stream (Big Buck Bunny) — no subtitles.
  static const hlsStream = CastMedia(
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    type: CastMediaType.hls,
    title: 'Big Buck Bunny (HLS)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/220px-Big_buck_bunny_poster_big.jpg',
  );

  /// Sample HLS stream with subtitles (Sintel trailer via Bitmovin).
  static const hlsWithSubtitles = CastMedia(
    url:
        'https://bitmovin-a.akamaihd.net/content/sintel/hls/playlist.m3u8',
    type: CastMediaType.hls,
    title: 'Sintel (HLS + Subtitles)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Sintel_poster.jpg/220px-Sintel_poster.jpg',
    subtitles: [
      CastSubtitle(
        url:
            'https://bitmovin-a.akamaihd.net/content/sintel/subtitles/subtitles_en.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      ),
      CastSubtitle(
        url:
            'https://bitmovin-a.akamaihd.net/content/sintel/subtitles/subtitles_de.vtt',
        label: 'German',
        language: 'de',
        format: 'vtt',
      ),
    ],
  );

  /// Sample MP4 video (Elephants Dream) — no subtitles.
  static const mp4Video = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    type: CastMediaType.mp4,
    title: 'Elephants Dream (MP4)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Elephants_Dream_s5_both.jpg/220px-Elephants_Dream_s5_both.jpg',
  );

  /// Sample MP4 video with subtitles (Tears of Steel).
  static const mp4WithSubtitles = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
    type: CastMediaType.mp4,
    title: 'Tears of Steel (MP4 + Subtitles)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Tears_of_Steel_poster.jpg/220px-Tears_of_Steel_poster.jpg',
    subtitles: [
      CastSubtitle(
        url:
            'https://bitmovin-a.akamaihd.net/content/sintel/subtitles/subtitles_en.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      ),
    ],
  );

  /// All available sample media items.
  static const List<CastMedia> allMedia = [
    hlsStream,
    hlsWithSubtitles,
    mp4Video,
    mp4WithSubtitles,
  ];
}
