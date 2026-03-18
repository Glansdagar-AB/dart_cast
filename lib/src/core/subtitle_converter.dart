/// Converts between subtitle formats (SRT <-> VTT).
class SubtitleConverter {
  /// Converts SRT content to WebVTT format.
  ///
  /// SRT format:
  /// ```
  /// 1
  /// 00:00:01,000 --> 00:00:04,000
  /// Hello world
  /// ```
  ///
  /// VTT format:
  /// ```
  /// WEBVTT
  ///
  /// 00:00:01.000 --> 00:00:04.000
  /// Hello world
  /// ```
  static String srtToVtt(String srt) {
    final lines = srt.split('\n');
    final vtt = StringBuffer('WEBVTT\n\n');

    for (final line in lines) {
      // Replace SRT comma timestamps with VTT dot timestamps
      // SRT: 00:00:01,000 --> 00:00:04,000
      // VTT: 00:00:01.000 --> 00:00:04.000
      if (line.contains(' --> ')) {
        vtt.writeln(line.replaceAll(',', '.'));
      } else if (RegExp(r'^\d+$').hasMatch(line.trim())) {
        // Skip sequence numbers (SRT has them, VTT doesn't need them)
        continue;
      } else {
        vtt.writeln(line);
      }
    }
    return vtt.toString();
  }

  /// Detects if content is SRT format (starts with a number, not WEBVTT).
  static bool isSrt(String content) {
    final trimmed = content.trimLeft();
    return !trimmed.startsWith('WEBVTT') &&
        RegExp(r'^\d+\s*\n').hasMatch(trimmed);
  }

  /// Strips `X-TIMESTAMP-MAP` from VTT content.
  ///
  /// HLS subtitle segments use this header to map MPEG-TS PTS timestamps
  /// to local VTT timestamps. When serving VTT as a sidecar track (not
  /// as HLS segments), this header causes cast devices like Chromecast
  /// (Shaka Player) to apply an incorrect offset, making subtitles out
  /// of sync. Removing it ensures timestamps are used as-is.
  static String stripTimestampMap(String vtt) {
    return vtt.replaceAll(
      RegExp(r'X-TIMESTAMP-MAP[^\n]*\n?', caseSensitive: false),
      '',
    );
  }
}
