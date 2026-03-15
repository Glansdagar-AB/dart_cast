/// Media type for casting.
enum CastMediaType {
  hls,
  mp4,
  mpegTs,
}

/// Represents a subtitle track for cast media.
class CastSubtitle {
  /// URL of the subtitle file.
  final String url;

  /// Human-readable label (e.g., "English").
  final String label;

  /// Language code (e.g., "en").
  final String language;

  /// Subtitle format (e.g., "vtt", "srt").
  final String format;

  /// Creates a [CastSubtitle].
  const CastSubtitle({
    required this.url,
    required this.label,
    required this.language,
    required this.format,
  });
}

/// Represents media to be cast to a device.
class CastMedia {
  /// URL of the media content.
  final String url;

  /// Type of the media content.
  final CastMediaType type;

  /// HTTP headers to include when fetching the media.
  final Map<String, String> httpHeaders;

  /// Optional title for the media.
  final String? title;

  /// Optional image/thumbnail URL.
  final String? imageUrl;

  /// Optional start position for playback.
  final Duration? startPosition;

  /// Subtitle tracks for this media.
  final List<CastSubtitle> subtitles;

  /// Creates a [CastMedia].
  const CastMedia({
    required this.url,
    required this.type,
    this.httpHeaders = const {},
    this.title,
    this.imageUrl,
    this.startPosition,
    this.subtitles = const [],
  });
}
