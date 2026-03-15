# Chromecast CASTV2 Protocol Reference

A complete protocol reference for implementing a Chromecast casting client in pure Dart. This document covers discovery, connection, message framing, every namespace and command, and the full session lifecycle.

---

## 1. mDNS Discovery

Chromecast devices advertise themselves via mDNS (multicast DNS) on the local network.

- **Service type:** `_googlecast._tcp.local`
- **Default port:** `8009` (TCP, TLS)
- **Multicast address:** `224.0.0.251:5353` (IPv4) / `ff02::fb:5353` (IPv6)

### TXT Record Fields

| Field | Description | Example |
|-------|-------------|---------|
| `id`  | Unique device identifier (UUID) | `f2cb34c8-a347-4e53-a5b8-123456789abc` |
| `fn`  | Friendly name (user-visible) | `Living Room TV` |
| `md`  | Model description | `Chromecast`, `Google Home`, `Chromecast Ultra` |
| `ve`  | Protocol version | `05` |
| `ca`  | Capabilities bitmask | `2052` |
| `st`  | Device status (0 = idle, 1 = busy) | `0` |
| `rs`  | Resource name | (empty or app name) |
| `bs`  | Build string | `1234567` |
| `ic`  | Icon path | `/setup/icon.png` |
| `nf`  | Network flags | `1` |

### Dart Discovery Example

Use the `multicast_dns` package or raw UDP sockets:

```dart
import 'package:multicast_dns/multicast_dns.dart';

Future<List<CastDevice>> discoverDevices() async {
  final devices = <CastDevice>[];
  final client = MDnsClient();
  await client.start();

  await for (final ptr in client.lookup<PtrResourceRecord>(
    ResourceRecordQuery.serverPointer('_googlecast._tcp.local'),
  )) {
    await for (final srv in client.lookup<SrvResourceRecord>(
      ResourceRecordQuery.service(ptr.domainName),
    )) {
      await for (final ip in client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
      )) {
        devices.add(CastDevice(
          host: ip.address.address,
          port: srv.port,
          name: ptr.domainName,
        ));
      }
    }
  }

  client.stop();
  return devices;
}
```

---

## 2. CASTV2 Protocol Framing

### Connection

All communication uses TLS over TCP to port 8009. The Chromecast uses a self-signed certificate, so certificate verification must be disabled.

```dart
final socket = await SecureSocket.connect(
  host,
  8009,
  onBadCertificate: (_) => true, // Chromecast uses self-signed certs
  timeout: const Duration(seconds: 5),
);
```

### Message Framing

Every message on the wire follows this format:

```
+-------------------+-------------------------------+
| 4 bytes           | N bytes                       |
| (big-endian u32)  | (protobuf-encoded CastMessage)|
| = N               |                               |
+-------------------+-------------------------------+
```

1. Read 4 bytes as a big-endian unsigned 32-bit integer. This is the length of the following protobuf payload.
2. Read exactly that many bytes. Decode as a `CastMessage` protobuf.

### Sending a Message (Dart)

```dart
void sendMessage(SecureSocket socket, CastMessage message) {
  final messageBytes = message.writeToBuffer();
  final length = messageBytes.length;

  // 4-byte big-endian length prefix
  final header = ByteData(4);
  header.setUint32(0, length, Endian.big);

  socket.add(header.buffer.asUint8List());
  socket.add(messageBytes);
}
```

### Receiving Messages (Dart)

```dart
Stream<CastMessage> receiveMessages(SecureSocket socket) async* {
  final buffer = BytesBuilder();

  await for (final chunk in socket) {
    buffer.add(chunk);

    while (buffer.length >= 4) {
      final bytes = buffer.toBytes();
      final length = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4)))
          .getUint32(0, Endian.big);

      if (bytes.length < 4 + length) break; // Wait for more data

      final messageBytes = bytes.sublist(4, 4 + length);
      final remaining = bytes.sublist(4 + length);

      buffer.clear();
      buffer.add(remaining);

      yield CastMessage.fromBuffer(messageBytes);
    }
  }
}
```

---

## 3. CastMessage Protobuf Definition

The following is the protobuf definition from the Chromium source. Generate Dart bindings with:

```bash
protoc --dart_out=lib/generated/ cast_channel.proto
```

Commit the generated files to your repository so the build does not depend on protoc.

### cast_channel.proto

```protobuf
syntax = "proto2";

option optimize_for = LITE_RUNTIME;

package extensions.api.cast_channel;

message CastMessage {
  enum ProtocolVersion {
    CASTV2_1_0 = 0;
  }

  enum PayloadType {
    STRING = 0;
    BINARY = 1;
  }

  required ProtocolVersion protocol_version = 1;

  // source and destination IDs identify the sender and receiver
  required string source_id = 2;
  required string destination_id = 3;

  // namespace determines which channel handler processes the message
  required string namespace = 4;

  required PayloadType payload_type = 5;

  // one of these must be set depending on payload_type
  optional string payload_utf8 = 6;
  optional bytes payload_binary = 7;
}

message AuthChallenge {
  optional SignatureAlgorithm signature_algorithm = 1 [default = RSASSA_PKCS1v15];
  optional bytes sender_nonce = 2;
  optional HashAlgorithm hash_algorithm = 3 [default = SHA256];
}

message AuthResponse {
  required bytes signature = 1;
  required bytes client_auth_certificate = 2;
  repeated bytes intermediate_certificate = 3;
  optional SignatureAlgorithm signature_algorithm = 4 [default = RSASSA_PKCS1v15];
  optional bytes sender_nonce = 5;
  optional HashAlgorithm hash_algorithm = 6 [default = SHA256];
  optional bytes crl = 7;
}

message AuthError {
  enum ErrorType {
    INTERNAL_ERROR = 0;
    NO_TLS = 1;
    SIGNATURE_ALGORITHM_UNAVAILABLE = 2;
  }
  required ErrorType error_type = 1;
}

message DeviceAuthMessage {
  optional AuthChallenge challenge = 1;
  optional AuthResponse response = 2;
  optional AuthError error = 3;
}

enum SignatureAlgorithm {
  UNSPECIFIED = 0;
  RSASSA_PKCS1v15 = 1;
  RSASSA_PSS = 2;
}

enum HashAlgorithm {
  SHA1 = 0;
  SHA256 = 1;
}
```

### Helper to Build a CastMessage (Dart)

```dart
CastMessage buildMessage({
  required String sourceId,
  required String destinationId,
  required String namespace,
  required Map<String, dynamic> payload,
}) {
  return CastMessage()
    ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
    ..sourceId = sourceId
    ..destinationId = destinationId
    ..namespace = namespace
    ..payloadType = CastMessage_PayloadType.STRING
    ..payloadUtf8 = jsonEncode(payload);
}
```

---

## 4. Channel Namespaces

Each namespace acts as a logical channel. Messages are routed by the `namespace` field in `CastMessage`.

### 4.1 Connection — `urn:x-cast:com.google.cast.tp.connection`

Manages virtual connections between sender and receiver applications. You must CONNECT before sending any other messages on a given destination.

#### CONNECT

Sent to establish a virtual connection. Must be sent to `receiver-0` first (the platform receiver), and then separately to the `transportId` of a launched application.

```json
{
  "type": "CONNECT",
  "origin": {},
  "userAgent": "AnimeHere/1.0",
  "senderInfo": {
    "sdkType": 2,
    "version": "15.0",
    "browserVersion": "44.0",
    "platform": 6,
    "connectionType": 1
  }
}
```

Minimal form (sufficient for most implementations):

```json
{
  "type": "CONNECT",
  "origin": {}
}
```

**Note:** The `requestId` field is NOT required for CONNECT messages, but including it does no harm.

- **source_id:** `sender-0` (or `client-<random>`)
- **destination_id:** `receiver-0` (platform) or `<transportId>` (app)

#### CLOSE

Sent to tear down a virtual connection.

```json
{
  "type": "CLOSE"
}
```

- The Chromecast may also send CLOSE to you if the app stops or the device reboots. Handle this gracefully.

---

### 4.2 Heartbeat — `urn:x-cast:com.google.cast.tp.heartbeat`

Keeps the connection alive. If the Chromecast does not receive a PING within its timeout window (approximately 10 seconds), it closes the TLS connection.

#### PING (sender to device)

Send every **5 seconds**:

```json
{
  "type": "PING"
}
```

- **source_id:** `sender-0`
- **destination_id:** `receiver-0`

#### PONG (device to sender)

Response to PING:

```json
{
  "type": "PONG"
}
```

#### Dart Heartbeat Timer

```dart
Timer.periodic(const Duration(seconds: 5), (_) {
  sendMessage(socket, buildMessage(
    sourceId: 'sender-0',
    destinationId: 'receiver-0',
    namespace: 'urn:x-cast:com.google.cast.tp.heartbeat',
    payload: {'type': 'PING'},
  ));
});
```

---

### 4.3 Receiver — `urn:x-cast:com.google.cast.receiver`

Controls the Chromecast platform: launching/stopping apps, querying status, setting device volume.

- **source_id:** `sender-0`
- **destination_id:** `receiver-0`

#### LAUNCH

Launches an application by `appId`. The Default Media Receiver app ID is `CC1AD845`.

```json
{
  "type": "LAUNCH",
  "appId": "CC1AD845",
  "requestId": 1
}
```

Common app IDs:

| App ID | Description |
|--------|-------------|
| `CC1AD845` | Default Media Receiver |
| `2872939A` | Backdrop (idle screen) |
| `233637DE` | YouTube |

#### GET_STATUS

Requests the current receiver status:

```json
{
  "type": "GET_STATUS",
  "requestId": 2
}
```

#### STOP

Stops a running application:

```json
{
  "type": "STOP",
  "sessionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "requestId": 3
}
```

#### SET_VOLUME (Device Level)

Set volume (0.0 to 1.0):

```json
{
  "type": "SET_VOLUME",
  "volume": {
    "level": 0.5
  },
  "requestId": 4
}
```

Mute/unmute:

```json
{
  "type": "SET_VOLUME",
  "volume": {
    "muted": true
  },
  "requestId": 5
}
```

#### RECEIVER_STATUS Response

Returned in response to LAUNCH, GET_STATUS, STOP, or SET_VOLUME. Also sent unsolicited when state changes.

```json
{
  "type": "RECEIVER_STATUS",
  "requestId": 1,
  "status": {
    "applications": [
      {
        "appId": "CC1AD845",
        "appType": "WEB",
        "displayName": "Default Media Receiver",
        "iconUrl": "",
        "isIdleScreen": false,
        "launchedFromCloud": false,
        "namespaces": [
          {"name": "urn:x-cast:com.google.cast.media"},
          {"name": "urn:x-cast:com.google.cast.tp.connection"},
          {"name": "urn:x-cast:com.google.cast.tp.heartbeat"}
        ],
        "sessionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "statusText": "Ready To Cast",
        "transportId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "universalAppId": "CC1AD845"
      }
    ],
    "isActiveInput": true,
    "isStandBy": false,
    "userEq": {},
    "volume": {
      "controlType": "attenuation",
      "level": 0.47999998927116394,
      "muted": false,
      "stepInterval": 0.05000000074505806
    }
  }
}
```

**Critical:** Extract `transportId` and `sessionId` from `status.applications[0]`. The `transportId` becomes the `destination_id` for all subsequent media commands and requires its own CONNECT.

---

### 4.4 Media — `urn:x-cast:com.google.cast.media`

Controls media playback on a launched media receiver application.

- **source_id:** `sender-0`
- **destination_id:** `<transportId>` (from RECEIVER_STATUS)

#### LOAD

See [Section 5](#5-load-command-details) for full LOAD payloads.

#### PLAY

```json
{
  "type": "PLAY",
  "mediaSessionId": 1,
  "requestId": 10
}
```

#### PAUSE

```json
{
  "type": "PAUSE",
  "mediaSessionId": 1,
  "requestId": 11
}
```

#### STOP (Media)

Stops media playback (does not close the app):

```json
{
  "type": "STOP",
  "mediaSessionId": 1,
  "requestId": 12
}
```

#### SEEK

```json
{
  "type": "SEEK",
  "mediaSessionId": 1,
  "currentTime": 120.5,
  "resumeState": "PLAYBACK_START",
  "requestId": 13
}
```

`resumeState` values:
- `"PLAYBACK_START"` — resume playing after seek
- `"PLAYBACK_PAUSE"` — stay paused after seek
- Omit to keep current state

#### SET_VOLUME (Media Stream Level)

This sets the volume of the media stream, not the device volume:

```json
{
  "type": "SET_VOLUME",
  "mediaSessionId": 1,
  "volume": {
    "level": 0.8,
    "muted": false
  },
  "requestId": 14
}
```

**Note:** For device-level volume, use the Receiver namespace (Section 4.3).

#### GET_STATUS (Media)

```json
{
  "type": "GET_STATUS",
  "mediaSessionId": 1,
  "requestId": 15
}
```

Or without `mediaSessionId` to get status of all media sessions:

```json
{
  "type": "GET_STATUS",
  "requestId": 15
}
```

#### EDIT_TRACKS_INFO

Activate or deactivate subtitle/audio tracks:

```json
{
  "type": "EDIT_TRACKS_INFO",
  "mediaSessionId": 1,
  "activeTrackIds": [1],
  "textTrackStyle": {
    "backgroundColor": "#00000000",
    "customData": {},
    "edgeColor": "#000000FF",
    "edgeType": "DROP_SHADOW",
    "fontFamily": "CASUAL",
    "fontGenericFamily": "CASUAL",
    "fontScale": 1.0,
    "fontStyle": "NORMAL",
    "foregroundColor": "#FFFFFFFF",
    "windowColor": "#00000000",
    "windowRoundedCornerRadius": 0,
    "windowType": "NONE"
  },
  "requestId": 16
}
```

To disable all tracks:

```json
{
  "type": "EDIT_TRACKS_INFO",
  "mediaSessionId": 1,
  "activeTrackIds": [],
  "requestId": 17
}
```

---

## 5. LOAD Command Details

The LOAD command is the most complex message. Below are full examples for different media types.

### MP4 Video with Metadata

```json
{
  "type": "LOAD",
  "requestId": 6,
  "media": {
    "contentId": "https://example.com/video.mp4",
    "contentType": "video/mp4",
    "streamType": "BUFFERED",
    "metadata": {
      "metadataType": 1,
      "title": "Episode 1 - The Beginning",
      "subtitle": "My Anime Title",
      "images": [
        {
          "url": "https://example.com/poster.jpg",
          "width": 480,
          "height": 720
        }
      ]
    },
    "duration": null
  },
  "autoplay": true,
  "currentTime": 0
}
```

### HLS Stream

```json
{
  "type": "LOAD",
  "requestId": 7,
  "media": {
    "contentId": "https://example.com/master.m3u8",
    "contentType": "application/x-mpegURL",
    "streamType": "BUFFERED",
    "metadata": {
      "metadataType": 2,
      "seriesTitle": "My Anime",
      "title": "Episode 5 - The Battle",
      "season": 1,
      "episode": 5,
      "images": [
        {
          "url": "https://example.com/thumb.jpg"
        }
      ]
    }
  },
  "autoplay": true,
  "currentTime": 0
}
```

### HLS with WebVTT Subtitle Tracks

```json
{
  "type": "LOAD",
  "requestId": 8,
  "media": {
    "contentId": "https://example.com/master.m3u8",
    "contentType": "application/x-mpegURL",
    "streamType": "BUFFERED",
    "metadata": {
      "metadataType": 2,
      "seriesTitle": "My Anime",
      "title": "Episode 12 - Final",
      "season": 1,
      "episode": 12,
      "images": [
        {
          "url": "https://example.com/poster.jpg"
        }
      ]
    },
    "tracks": [
      {
        "trackId": 1,
        "type": "TEXT",
        "subtype": "SUBTITLES",
        "trackContentId": "https://example.com/subs/english.vtt",
        "trackContentType": "text/vtt",
        "name": "English",
        "language": "en"
      },
      {
        "trackId": 2,
        "type": "TEXT",
        "subtype": "SUBTITLES",
        "trackContentId": "https://example.com/subs/arabic.vtt",
        "trackContentType": "text/vtt",
        "name": "Arabic",
        "language": "ar"
      }
    ],
    "textTrackStyle": {
      "backgroundColor": "#00000000",
      "edgeColor": "#000000FF",
      "edgeType": "DROP_SHADOW",
      "fontFamily": "CASUAL",
      "fontGenericFamily": "CASUAL",
      "fontScale": 1.0,
      "fontStyle": "NORMAL",
      "foregroundColor": "#FFFFFFFF",
      "windowColor": "#00000000",
      "windowType": "NONE"
    }
  },
  "activeTrackIds": [1],
  "autoplay": true,
  "currentTime": 0
}
```

### contentType Values

| Content Type | Format |
|-------------|--------|
| `video/mp4` | MP4 video |
| `video/webm` | WebM video |
| `audio/mp3` | MP3 audio |
| `audio/mp4` | AAC audio |
| `audio/mpeg` | MPEG audio |
| `application/x-mpegURL` | HLS stream (m3u8) |
| `application/dash+xml` | DASH stream (mpd) |
| `application/vnd.ms-sstr+xml` | Smooth Streaming |
| `image/jpeg` | JPEG image |
| `image/png` | PNG image |
| `text/vtt` | WebVTT subtitles |

### streamType Values

| Value | Description |
|-------|-------------|
| `BUFFERED` | On-demand content with known duration |
| `LIVE` | Live stream, no seek bar |
| `NONE` | Unknown, let receiver decide |

### metadataType Values

| Value | Type | Available Fields |
|-------|------|-----------------|
| `0` | Generic | `title`, `subtitle`, `images` |
| `1` | Movie | `title`, `subtitle`, `studio`, `images` |
| `2` | TV Show | `seriesTitle`, `title`, `season`, `episode`, `originalAirdate`, `images` |
| `3` | Music Track | `title`, `albumName`, `artist`, `albumArtist`, `trackNumber`, `discNumber`, `images` |
| `4` | Photo | `title`, `artist`, `location`, `latitude`, `longitude`, `width`, `height`, `creationDateTime`, `images` |

### Track Object Fields

| Field | Type | Description |
|-------|------|-------------|
| `trackId` | int | Unique ID (must be > 0) |
| `type` | string | `TEXT`, `AUDIO`, `VIDEO` |
| `subtype` | string | `SUBTITLES`, `CAPTIONS`, `DESCRIPTIONS`, `CHAPTERS`, `METADATA` (for type TEXT) |
| `trackContentId` | string | URL of the track content (e.g., VTT file URL) |
| `trackContentType` | string | MIME type (e.g., `text/vtt`) |
| `name` | string | Human-readable track name |
| `language` | string | BCP-47 language code (e.g., `en`, `ar`, `ja`) |

### CORS Requirement for Subtitles

Subtitle URLs **must** be served with proper CORS headers. The Chromecast fetches subtitle files from its own origin, so the subtitle server must respond with:

```
Access-Control-Allow-Origin: *
```

Without this, subtitle loading silently fails. If you control the subtitle server, add the header. If not, you may need to proxy subtitle files through a CORS-enabled endpoint.

---

## 6. MEDIA_STATUS Response

Sent by the Chromecast in response to media commands or unsolicited when playback state changes.

### Full Example

```json
{
  "type": "MEDIA_STATUS",
  "requestId": 6,
  "status": [
    {
      "mediaSessionId": 1,
      "playbackRate": 1,
      "playerState": "PLAYING",
      "currentTime": 42.361,
      "supportedMediaCommands": 274447,
      "volume": {
        "level": 1.0,
        "muted": false
      },
      "activeTrackIds": [1],
      "media": {
        "contentId": "https://example.com/master.m3u8",
        "contentType": "application/x-mpegURL",
        "streamType": "BUFFERED",
        "duration": 1440.5,
        "metadata": {
          "metadataType": 2,
          "seriesTitle": "My Anime",
          "title": "Episode 1",
          "images": [
            {
              "url": "https://example.com/poster.jpg"
            }
          ]
        },
        "tracks": [
          {
            "trackId": 1,
            "type": "TEXT",
            "subtype": "SUBTITLES",
            "trackContentId": "https://example.com/subs/en.vtt",
            "trackContentType": "text/vtt",
            "name": "English",
            "language": "en"
          }
        ]
      },
      "currentItemId": 1,
      "extendedStatus": {
        "playerState": "LOADING",
        "media": {}
      }
    }
  ]
}
```

### playerState Values

| State | Description |
|-------|-------------|
| `IDLE` | No media loaded or media has finished/been stopped |
| `BUFFERING` | Media is buffering (loading data) |
| `PLAYING` | Media is actively playing |
| `PAUSED` | Media is paused |
| `LOADING` | Media is being loaded (between LOAD and first PLAYING) |

### idleReason Values (present when playerState is IDLE)

| Reason | Description |
|--------|-------------|
| `FINISHED` | Playback reached the end of the media |
| `CANCELLED` | User stopped playback |
| `INTERRUPTED` | Playback interrupted (e.g., new LOAD or app crash) |
| `ERROR` | A playback error occurred |

### Important Notes

- `status` is an **array** — it can contain multiple media sessions (though typically just one).
- When `requestId` is `0`, the MEDIA_STATUS is **unsolicited** (a state-change notification, not a response to your command).
- `currentTime` is in **seconds** as a float.
- `duration` may be `null` or absent for live streams.
- `supportedMediaCommands` is a bitmask. Common bits: `1`=PAUSE, `2`=SEEK, `4`=SET_VOLUME, `8`=TOGGLE_MUTE, `16`=SKIP_FORWARD, `32`=SKIP_BACKWARD.

---

## 7. Source/Destination ID Conventions

### Sender ID

Choose one format for your sender and use it consistently throughout the session:

- `sender-0` — simplest, works for single-sender scenarios
- `client-<random>` — e.g., `client-83734` — useful if multiple senders connect simultaneously

### Destination IDs

| ID | Represents | When to Use |
|----|-----------|-------------|
| `receiver-0` | Chromecast platform | Connection, heartbeat, receiver control (LAUNCH, GET_STATUS, SET_VOLUME, STOP) |
| `<transportId>` | Running app instance | Media control (LOAD, PLAY, PAUSE, SEEK, etc.) and app-level CONNECT/CLOSE |

### Extracting transportId from RECEIVER_STATUS

```dart
void handleReceiverStatus(Map<String, dynamic> payload) {
  final status = payload['status'];
  if (status == null) return;

  final apps = status['applications'] as List?;
  if (apps == null || apps.isEmpty) return;

  final app = apps[0] as Map<String, dynamic>;
  final transportId = app['transportId'] as String;  // Use as destination_id for media
  final sessionId = app['sessionId'] as String;       // Use for STOP command

  // Now CONNECT to the app's transportId
  sendMessage(socket, buildMessage(
    sourceId: 'sender-0',
    destinationId: transportId,
    namespace: 'urn:x-cast:com.google.cast.tp.connection',
    payload: {'type': 'CONNECT', 'origin': {}},
  ));
}
```

---

## 8. Full Session Lifecycle

Below is the complete sequence of operations to discover a Chromecast, connect, play media, control playback, and disconnect. Each step shows the exact namespace, source_id, and destination_id.

### Step 1: TLS Connect

```dart
final socket = await SecureSocket.connect(
  '192.168.1.100',  // discovered via mDNS
  8009,
  onBadCertificate: (_) => true,
);
```

### Step 2: CONNECT to Platform Receiver

```
namespace:      urn:x-cast:com.google.cast.tp.connection
source_id:      sender-0
destination_id: receiver-0
```

```json
{
  "type": "CONNECT",
  "origin": {}
}
```

### Step 3: Start Heartbeat Loop

Send PING every 5 seconds. Handle incoming PONG (or ignore it — the important part is sending PING).

```
namespace:      urn:x-cast:com.google.cast.tp.heartbeat
source_id:      sender-0
destination_id: receiver-0
```

```json
{"type": "PING"}
```

### Step 4: LAUNCH Default Media Receiver

```
namespace:      urn:x-cast:com.google.cast.receiver
source_id:      sender-0
destination_id: receiver-0
```

```json
{
  "type": "LAUNCH",
  "appId": "CC1AD845",
  "requestId": 1
}
```

Wait for a `RECEIVER_STATUS` response with an `applications` array.

### Step 5: Extract transportId from RECEIVER_STATUS

Parse the response. The `transportId` is typically a UUID string like `"web-4"` or `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"`. Also save the `sessionId`.

### Step 6: CONNECT to App (transportId)

```
namespace:      urn:x-cast:com.google.cast.tp.connection
source_id:      sender-0
destination_id: <transportId>
```

```json
{
  "type": "CONNECT",
  "origin": {}
}
```

### Step 7: GET_STATUS on Media Namespace

(Optional — checks if media is already loaded)

```
namespace:      urn:x-cast:com.google.cast.media
source_id:      sender-0
destination_id: <transportId>
```

```json
{
  "type": "GET_STATUS",
  "requestId": 2
}
```

### Step 8: LOAD Media

```
namespace:      urn:x-cast:com.google.cast.media
source_id:      sender-0
destination_id: <transportId>
```

```json
{
  "type": "LOAD",
  "requestId": 3,
  "media": {
    "contentId": "https://example.com/master.m3u8",
    "contentType": "application/x-mpegURL",
    "streamType": "BUFFERED",
    "metadata": {
      "metadataType": 2,
      "seriesTitle": "My Anime",
      "title": "Episode 1",
      "images": [{"url": "https://example.com/poster.jpg"}]
    }
  },
  "autoplay": true,
  "currentTime": 0
}
```

Wait for `MEDIA_STATUS` with `playerState: "PLAYING"` or `"BUFFERING"`.

### Step 9: Control Playback

All media commands use:

```
namespace:      urn:x-cast:com.google.cast.media
source_id:      sender-0
destination_id: <transportId>
```

**Pause:**
```json
{"type": "PAUSE", "mediaSessionId": 1, "requestId": 10}
```

**Resume:**
```json
{"type": "PLAY", "mediaSessionId": 1, "requestId": 11}
```

**Seek to 2 minutes:**
```json
{"type": "SEEK", "mediaSessionId": 1, "currentTime": 120.0, "requestId": 12}
```

**Set device volume to 50%:**

```
namespace:      urn:x-cast:com.google.cast.receiver
source_id:      sender-0
destination_id: receiver-0
```

```json
{"type": "SET_VOLUME", "volume": {"level": 0.5}, "requestId": 13}
```

### Step 10: Disconnect

**CLOSE to app:**

```
namespace:      urn:x-cast:com.google.cast.tp.connection
source_id:      sender-0
destination_id: <transportId>
```

```json
{"type": "CLOSE"}
```

**CLOSE to platform:**

```
namespace:      urn:x-cast:com.google.cast.tp.connection
source_id:      sender-0
destination_id: receiver-0
```

```json
{"type": "CLOSE"}
```

Then close the TLS socket:

```dart
await socket.close();
heartbeatTimer.cancel();
```

---

## 9. Reconnecting to an Existing Session

If the sender disconnects but the Chromecast app is still running (e.g., user backgrounded the app and came back), you can reconnect without re-launching.

### Steps

1. **TLS connect** to the Chromecast (same as Step 1).

2. **CONNECT to receiver-0** (same as Step 2).

3. **Start heartbeat** (same as Step 3).

4. **GET_STATUS** on the receiver namespace to check if an app is running:

   ```
   namespace:      urn:x-cast:com.google.cast.receiver
   source_id:      sender-0
   destination_id: receiver-0
   ```

   ```json
   {"type": "GET_STATUS", "requestId": 1}
   ```

5. **Check the RECEIVER_STATUS response.** If `status.applications` contains an app with `appId: "CC1AD845"`, extract its `transportId` and `sessionId`.

6. **CONNECT to the transportId** (same as Step 6).

7. **GET_STATUS on media** to discover the current `mediaSessionId` and playback state:

   ```
   namespace:      urn:x-cast:com.google.cast.media
   source_id:      sender-0
   destination_id: <transportId>
   ```

   ```json
   {"type": "GET_STATUS", "requestId": 2}
   ```

8. **Resume control.** Use the `mediaSessionId` from the MEDIA_STATUS response for PLAY, PAUSE, SEEK, etc.

### Key Differences from Fresh Launch

- Do **not** send LAUNCH — the app is already running.
- The `mediaSessionId` may differ from what you had before reconnecting. Always use the value from the latest MEDIA_STATUS.
- If the app has stopped (no `applications` in RECEIVER_STATUS), fall back to a fresh LAUNCH.

---

## Appendix A: requestId Management

- `requestId` must be a positive integer.
- Each request should use a unique, incrementing `requestId`.
- Responses include the same `requestId` so you can match responses to requests.
- Unsolicited messages (state changes) use `requestId: 0`.
- Dart implementation:

```dart
int _requestId = 0;
int nextRequestId() => ++_requestId;
```

## Appendix B: Error Handling

### Common Error Responses

**INVALID_REQUEST:**
```json
{
  "type": "INVALID_REQUEST",
  "requestId": 5,
  "reason": "INVALID_COMMAND"
}
```

**LOAD_FAILED:**
```json
{
  "type": "LOAD_FAILED",
  "requestId": 6
}
```

**LOAD_CANCELLED:**
```json
{
  "type": "LOAD_CANCELLED",
  "requestId": 7
}
```

### Handling Connection Drops

- The TLS socket may close unexpectedly. Wrap your socket listener in error handling.
- If the heartbeat PONG is not received within 10 seconds, consider the connection dead and reconnect.
- If you receive a CLOSE message on the connection namespace, the app has stopped. Clean up your state.

```dart
socket.listen(
  onData,
  onError: (error) {
    // Connection error — attempt reconnect
    reconnect();
  },
  onDone: () {
    // Socket closed — attempt reconnect
    reconnect();
  },
);
```

## Appendix C: supportedMediaCommands Bitmask

| Bit | Value | Command |
|-----|-------|---------|
| 0 | 1 | PAUSE |
| 1 | 2 | SEEK |
| 2 | 4 | STREAM_VOLUME |
| 3 | 8 | STREAM_MUTE |
| 4 | 16 | SKIP_FORWARD |
| 5 | 32 | SKIP_BACKWARD |
| 6 | 64 | QUEUE_NEXT |
| 7 | 128 | QUEUE_PREV |
| 8 | 256 | QUEUE_SHUFFLE |
| 9 | 512 | SKIP_AD |
| 10 | 1024 | QUEUE_REPEAT_ALL |
| 11 | 2048 | QUEUE_REPEAT_ONE |
| 12 | 4096 | QUEUE_REPEAT |
| 17 | 131072 | EDIT_TRACKS |
| 18 | 262144 | PLAYBACK_RATE |
