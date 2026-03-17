# Future Work

Features planned but not yet implemented in dart_cast.

## AirPlay Screen Mirroring (Video-as-Mirroring)

Stream video content over AirPlay's screen mirroring protocol instead of URL-based `/play`.

### Why
Many third-party AirPlay receivers (Google TV, some LG/Samsung TVs) implement screen mirroring (feature bit 7) but NOT video URL casting (feature bits 0/49). Streaming video as mirroring frames would work on these devices.

### Architecture
```
URL fetch → Demux → Decode → H.264 Encode → RTP Framing → AES-CTR Encrypt → TCP Stream
```

### Required Components
1. **Video fetcher**: HTTP client to fetch HLS segments or progressive MP4
2. **Demuxer**: Extract H.264/AAC from MP4/TS containers
3. **H.264 encoder**: Re-encode or passthrough H.264 NAL units (FFmpeg via FFI or platform codecs)
4. **RTP framer**: Package H.264 NAL units into RTP packets with AirPlay mirroring headers (128-byte packet header)
5. **AES-CTR encryption**: Encrypt video frames per AirPlay mirroring spec
6. **RTSP SETUP type 110**: Establish mirroring stream channel
7. **Audio sync**: Separate audio RTP stream synchronized with video

### Estimated Effort
Large — requires FFmpeg integration or platform-native video codec access. Cross-platform (Android, iOS, macOS, Windows) adds complexity.

## AirPlay Audio Streaming (RAOP)

Stream raw audio packets over RTSP/RTP.

### Why
Some AirPlay devices support audio streaming but not video URL casting. RAOP allows sending audio directly.

### Required Components
1. **RTSP ANNOUNCE**: Declare audio codec (ALAC, AAC, OPUS, PCM)
2. **RTSP SETUP**: Establish audio stream with control/timing ports
3. **Audio encoder**: PCM → ALAC or AAC encoding
4. **RTP framing**: Audio packets over UDP with encryption
5. **Timing synchronization**: NTP-based timing protocol

### Estimated Effort
Medium — audio encoding is simpler than video. The RTSP session infrastructure already exists.
