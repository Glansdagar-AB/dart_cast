/// HLS playlist parser with URL rewriting for proxy support.
///
/// Handles both master (multivariant) and media playlists per RFC 8216.
class HlsParser {
  HlsParser._();

  /// Tags where the URI appears on the next line (Pattern A).
  static const _nextLineUriTags = [
    '#EXT-X-STREAM-INF:',
    '#EXTINF:',
  ];

  /// Tags where the URI is a quoted attribute (Pattern B).
  static const _attributeUriTags = [
    '#EXT-X-KEY:',
    '#EXT-X-MAP:',
    '#EXT-X-MEDIA:',
    '#EXT-X-I-FRAME-STREAM-INF:',
    '#EXT-X-SESSION-KEY:',
    '#EXT-X-SESSION-DATA:',
  ];

  /// Regex matching `URI="<value>"` attribute in a tag line.
  static final _uriAttributeRegex = RegExp(r'URI="([^"]*)"');

  /// Detects whether [content] is a master (multivariant) playlist.
  ///
  /// Returns true if it contains `#EXT-X-STREAM-INF` or
  /// `#EXT-X-I-FRAME-STREAM-INF`.
  static bool isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF') ||
        content.contains('#EXT-X-I-FRAME-STREAM-INF');
  }

  /// Resolves [url] against [baseUrl] per RFC 3986.
  ///
  /// Handles absolute URLs, protocol-relative, absolute-path, and
  /// relative-path references.
  static String resolveUrl(String url, String baseUrl) {
    // Absolute URL — has scheme
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    final base = Uri.parse(baseUrl);

    // Protocol-relative
    if (url.startsWith('//')) {
      return '${base.scheme}:$url';
    }

    // Absolute path
    if (url.startsWith('/')) {
      return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$url';
    }

    // Relative path — resolve against base
    return base.resolve(url).toString();
  }

  /// Rewrites all URLs in an HLS playlist to go through the proxy.
  ///
  /// [content] is the raw m3u8 text.
  /// [baseUrl] is the URL from which the playlist was fetched.
  /// [proxyBaseUrl] is the proxy server's base URL (e.g. `http://192.168.1.5:8234`).
  /// [token] is the proxy route token for this media session.
  static String rewritePlaylist(
    String content,
    String baseUrl,
    String proxyBaseUrl,
    String token,
  ) {
    final lines = content.split('\n');
    final result = <String>[];
    var expectUri = false;

    for (final line in lines) {
      // Empty lines pass through
      if (line.trim().isEmpty) {
        result.add(line);
        continue;
      }

      // Check Pattern A: tags where next line is the URI
      if (_isNextLineUriTag(line)) {
        result.add(line);
        expectUri = true;
        continue;
      }

      // #EXT-X-BYTERANGE can appear between #EXTINF and the segment URI
      if (line.startsWith('#EXT-X-BYTERANGE:') && expectUri) {
        result.add(line);
        continue;
      }

      // Check Pattern B: tags with URI="..." attribute
      if (_isAttributeUriTag(line)) {
        result.add(_rewriteUriAttribute(line, baseUrl, proxyBaseUrl, token));
        continue;
      }

      // Non-tag, non-empty line while expecting URI — this is a segment/variant URI
      if (expectUri && !line.startsWith('#')) {
        final resolved = resolveUrl(line.trim(), baseUrl);
        result.add(_buildProxyUrl(proxyBaseUrl, token, resolved));
        expectUri = false;
        continue;
      }

      // Any other line (tags, comments)
      result.add(line);
      expectUri = false;
    }

    return result.join('\n');
  }

  static bool _isNextLineUriTag(String line) {
    for (final tag in _nextLineUriTags) {
      if (line.startsWith(tag)) return true;
    }
    return false;
  }

  static bool _isAttributeUriTag(String line) {
    for (final tag in _attributeUriTags) {
      if (line.startsWith(tag)) return true;
    }
    return false;
  }

  /// Rewrites the `URI="..."` attribute in a tag line.
  static String _rewriteUriAttribute(
    String line,
    String baseUrl,
    String proxyBaseUrl,
    String token,
  ) {
    final match = _uriAttributeRegex.firstMatch(line);
    if (match == null)
      return line; // No URI attribute (e.g. #EXT-X-MEDIA without URI)

    final originalUri = match.group(1)!;
    final resolved = resolveUrl(originalUri, baseUrl);
    final proxied = _buildProxyUrl(proxyBaseUrl, token, resolved);
    return line.replaceFirst(
      'URI="$originalUri"',
      'URI="$proxied"',
    );
  }

  /// Extract segment URLs from a media playlist.
  ///
  /// Parses `#EXTINF` lines and collects the next-line URIs,
  /// resolving them against [baseUrl].
  static List<String> extractSegmentUrls(String content, String baseUrl) {
    final lines = content.split('\n');
    final segments = <String>[];
    var expectUri = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('#EXTINF:')) {
        expectUri = true;
        continue;
      }

      // #EXT-X-BYTERANGE can appear between #EXTINF and the segment URI
      if (trimmed.startsWith('#EXT-X-BYTERANGE:') && expectUri) {
        continue;
      }

      if (expectUri && !trimmed.startsWith('#')) {
        segments.add(resolveUrl(trimmed, baseUrl));
        expectUri = false;
        continue;
      }

      if (trimmed.startsWith('#')) {
        // Other tags reset expectUri unless it's a byterange
        if (!trimmed.startsWith('#EXT-X-BYTERANGE:')) {
          expectUri = false;
        }
        continue;
      }

      expectUri = false;
    }

    return segments;
  }

  /// Given a master playlist, extract variant playlist URLs sorted by
  /// bandwidth (highest first).
  static List<({String url, int bandwidth})> extractVariants(
    String content,
    String baseUrl,
  ) {
    final lines = content.split('\n');
    final variants = <({String url, int bandwidth})>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        // Extract BANDWIDTH
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        final bandwidth = bwMatch != null ? int.parse(bwMatch.group(1)!) : 0;

        // Next non-empty, non-comment line is the URI
        for (var j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          if (nextLine.isEmpty) continue;
          if (nextLine.startsWith('#')) continue;
          variants.add((
            url: resolveUrl(nextLine, baseUrl),
            bandwidth: bandwidth,
          ));
          break;
        }
      }
    }

    // Sort by bandwidth descending (highest quality first)
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants;
  }

  /// Constructs a proxy URL for the given original URL.
  static String _buildProxyUrl(
    String proxyBaseUrl,
    String token,
    String originalUrl,
  ) {
    return '$proxyBaseUrl/stream/$token?url=${Uri.encodeComponent(originalUrl)}';
  }
}
