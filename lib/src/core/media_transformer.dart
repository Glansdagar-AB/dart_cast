import 'cast_media.dart';
import 'media_proxy.dart';

/// Result of transforming media for casting.
class TransformedMedia {
  /// The proxy URL pointing to the (possibly transformed) media.
  final String proxyUrl;

  /// The effective media type after transformation.
  ///
  /// May differ from the original — e.g., `mpegTs` becomes `hls` after
  /// wrapping in an HLS playlist.
  final CastMediaType effectiveType;

  const TransformedMedia({
    required this.proxyUrl,
    required this.effectiveType,
  });
}

/// Transforms [CastMedia] into a proxy URL ready for casting.
///
/// Implementations handle registering media with the proxy, converting formats,
/// and wrapping content as needed for the target device.
///
/// Built-in implementations:
/// - [DefaultMediaTransformer] — registers with proxy, wraps local TS in HLS
///
/// To add custom logic (e.g., transcoding, custom segmentation), implement
/// this interface and pass it when creating a session.
///
/// ```dart
/// class MyTransformer implements MediaTransformer {
///   @override
///   Future<TransformedMedia> transform(CastMedia media, MediaProxy proxy) async {
///     final url = proxy.registerFile(media.url);
///     return TransformedMedia(proxyUrl: url, effectiveType: media.type);
///   }
/// }
/// ```
abstract class MediaTransformer {
  /// Transforms [media] using [proxy] and returns the result.
  ///
  /// The [proxy] is already started when this is called.
  Future<TransformedMedia> transform(CastMedia media, MediaProxy proxy);
}

/// Default transformer that handles common casting scenarios.
///
/// - Registers remote URLs and local files with the proxy
/// - Wraps local MPEG-TS files in HLS (keyframe-aligned byte-range segments
///   when [CastMedia.useChunkedHls] is true, single-segment otherwise)
/// - Passes through other formats unchanged
///
/// This covers Chromecast (needs HLS for TS), DLNA (protocol session wraps
/// HLS→stream separately), and AirPlay.
class DefaultMediaTransformer implements MediaTransformer {
  /// Whether to wrap remote MPEG-TS URLs in HLS.
  ///
  /// Default `false` — only local TS files are wrapped.
  /// Set to `true` for devices like Chromecast that can't play raw TS at all.
  final bool wrapRemoteTs;

  const DefaultMediaTransformer({this.wrapRemoteTs = false});

  @override
  Future<TransformedMedia> transform(
      CastMedia media, MediaProxy proxy) async {
    // Register media with proxy
    var proxyUrl = media.isLocalFile
        ? proxy.registerFile(media.url)
        : proxy.registerMedia(media.url, headers: media.httpHeaders);

    var effectiveType = media.type;

    // Wrap MPEG-TS in HLS for devices that need it (like Chromecast).
    // Only wraps when wrapRemoteTs is true (Chromecast) or for local files
    // when useChunkedHls is requested. DLNA serves local TS files directly
    // with Content-Length so the TV knows the total duration.
    if (media.type == CastMediaType.mpegTs && wrapRemoteTs) {
      final durationSecs = media.duration?.inMilliseconds != null
          ? media.duration!.inMilliseconds / 1000.0
          : null;

      if (media.useChunkedHls && media.isLocalFile) {
        proxyUrl = proxy.wrapLocalFileAsHls(
          proxyUrl,
          media.url,
          totalDuration: durationSecs,
        );
      } else {
        proxyUrl = proxy.wrapInHlsPlaylist(proxyUrl, duration: durationSecs);
      }
      effectiveType = CastMediaType.hls;
    }

    return TransformedMedia(proxyUrl: proxyUrl, effectiveType: effectiveType);
  }
}
