import 'dart:io';
import 'dart:typed_data';

import '../utils/logger.dart';

/// Scans an MPEG-TS file for keyframe (IDR) positions.
///
/// Used to create HLS byte-range playlists with segments that start at
/// keyframe boundaries, which is required for correct playback on cast devices.
class TsKeyframeScanner {
  /// Scans [file] and returns byte offsets of TS packets containing keyframes.
  ///
  /// Uses two detection methods:
  /// 1. `random_access_indicator` in the adaptation field (fast, but not always set)
  /// 2. H.264 IDR NAL unit type 5 in PES payloads (reliable fallback)
  ///
  /// Always includes offset 0 (start of file) in the result.
  static List<int> findKeyframeOffsets(File file) {
    final offsets = <int>[0];
    final fileLength = file.lengthSync();
    if (fileLength < 188) return offsets;

    final raf = file.openSync();
    try {
      // Read in large chunks for performance
      const chunkSize = 188 * 1024; // ~192KB chunks
      final chunk = Uint8List(chunkSize);
      int fileOffset = 0;

      // Find initial sync byte
      final syncBuf = Uint8List(1);
      while (fileOffset < fileLength) {
        raf.readIntoSync(syncBuf);
        if (syncBuf[0] == 0x47) break;
        fileOffset++;
      }
      if (fileOffset >= fileLength) return offsets;
      raf.setPositionSync(fileOffset);

      while (fileOffset < fileLength) {
        final remaining = fileLength - fileOffset;
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final bytesRead = raf.readIntoSync(chunk, 0, toRead);
        if (bytesRead < 188) break;

        // Process each TS packet in the chunk
        for (int pos = 0; pos + 188 <= bytesRead; pos += 188) {
          if (chunk[pos] != 0x47) continue; // Skip if not sync byte

          final packetOffset = fileOffset + pos;

          // Method 1: Check random_access_indicator in adaptation field
          final adaptCtrl = (chunk[pos + 3] >> 4) & 0x03;
          if (adaptCtrl >= 2) {
            final adaptLen = chunk[pos + 4];
            if (adaptLen > 0) {
              final rai = (chunk[pos + 5] >> 6) & 0x01;
              if (rai == 1 && packetOffset > 0) {
                offsets.add(packetOffset);
                continue;
              }
            }
          }

          // Method 2: Check for H.264 IDR NAL unit in payload
          // Only check packets with payload (adaptCtrl == 1 or 3)
          // and payload_unit_start_indicator set (new PES packet)
          if (adaptCtrl == 1 || adaptCtrl == 3) {
            final pusi = (chunk[pos + 1] >> 6) & 0x01;
            if (pusi == 1) {
              // Find payload start
              int payloadStart = pos + 4;
              if (adaptCtrl == 3) {
                payloadStart += 1 + chunk[pos + 4]; // skip adaptation field
              }

              // Check for PES header (0x00 0x00 0x01) followed by video stream
              if (payloadStart + 9 < pos + 188) {
                if (chunk[payloadStart] == 0x00 &&
                    chunk[payloadStart + 1] == 0x00 &&
                    chunk[payloadStart + 2] == 0x01) {
                  final streamId = chunk[payloadStart + 3];
                  // Video stream IDs: 0xE0-0xEF
                  if (streamId >= 0xE0 && streamId <= 0xEF) {
                    // Scan payload for H.264 NAL start code + IDR type
                    for (int j = payloadStart + 9; j + 4 < pos + 188; j++) {
                      if (chunk[j] == 0x00 &&
                          chunk[j + 1] == 0x00 &&
                          chunk[j + 2] == 0x01) {
                        final nalType = chunk[j + 3] & 0x1F;
                        // NAL type 5 = IDR slice (keyframe)
                        if (nalType == 5 && packetOffset > 0) {
                          offsets.add(packetOffset);
                          break;
                        }
                      }
                      // Also check 4-byte start code (0x00 0x00 0x00 0x01)
                      if (j + 5 < pos + 188 &&
                          chunk[j] == 0x00 &&
                          chunk[j + 1] == 0x00 &&
                          chunk[j + 2] == 0x00 &&
                          chunk[j + 3] == 0x01) {
                        final nalType = chunk[j + 4] & 0x1F;
                        if (nalType == 5 && packetOffset > 0) {
                          offsets.add(packetOffset);
                          break;
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        fileOffset += bytesRead;
      }
    } finally {
      raf.closeSync();
    }

    // Deduplicate (a packet might match both methods)
    final unique = offsets.toSet().toList()..sort();

    CastLogger.debug(
        'TsKeyframeScanner: found ${unique.length} keyframes in '
        '${(fileLength / 1024 / 1024).toStringAsFixed(1)}MB file');

    return unique;
  }
}
