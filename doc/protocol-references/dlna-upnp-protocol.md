# DLNA/UPnP Protocol Reference

This document is a complete protocol reference for implementing a DLNA/UPnP casting client. It covers device discovery, description retrieval, transport control, volume control, metadata formatting, and subtitle delivery. All XML templates and header values are exact and copy-pasteable.

---

## 1. SSDP Discovery

SSDP (Simple Service Discovery Protocol) uses UDP multicast to find UPnP devices on the local network.

### Network Parameters

| Parameter          | Value              |
|--------------------|--------------------|
| Multicast address  | `239.255.255.250`  |
| Port               | `1900`             |
| Protocol           | UDP                |
| TTL                | 4 (recommended)    |

### M-SEARCH Request

Send this datagram to the multicast address to discover devices:

```
M-SEARCH * HTTP/1.1\r\n
HOST: 239.255.255.250:1900\r\n
MAN: "ssdp:discover"\r\n
ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n
MX: 3\r\n
\r\n
```

**Header details:**

| Header | Value | Description |
|--------|-------|-------------|
| `HOST` | `239.255.255.250:1900` | Always this exact value. |
| `MAN` | `"ssdp:discover"` | Must include the double quotes. |
| `ST` | (see below) | Search target — what you are looking for. |
| `MX` | `3` | Maximum wait time in seconds before a device must respond. 1-5 is typical. |

**Useful ST (Search Target) values:**

| ST Value | What it finds |
|----------|---------------|
| `ssdp:all` | Every UPnP device and service on the network. |
| `upnp:rootdevice` | All root devices. |
| `urn:schemas-upnp-org:device:MediaRenderer:1` | Media renderers (TVs, speakers, etc.). This is the primary target for casting. |
| `urn:schemas-upnp-org:service:AVTransport:1` | Devices exposing the AVTransport service directly. |

### M-SEARCH Response

Each responding device sends a unicast UDP reply back to your source port:

```
HTTP/1.1 200 OK\r\n
CACHE-CONTROL: max-age=1800\r\n
DATE: Thu, 14 Mar 2026 12:00:00 GMT\r\n
EXT:\r\n
LOCATION: http://192.168.1.50:49152/description.xml\r\n
SERVER: Linux/4.9 UPnP/1.0 MediaRenderer/1.0\r\n
ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n
USN: uuid:12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n
\r\n
```

**Critical field:** `LOCATION` — this is the URL to the device description XML. Extract it with a case-insensitive header search:

```
LOCATION: http://<device-ip>:<port>/description.xml
```

### NOTIFY Advertisement Messages

Devices also periodically send unsolicited multicast NOTIFY messages:

```
NOTIFY * HTTP/1.1\r\n
HOST: 239.255.255.250:1900\r\n
CACHE-CONTROL: max-age=1800\r\n
LOCATION: http://192.168.1.50:49152/description.xml\r\n
NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n
NTS: ssdp:alive\r\n
SERVER: Linux/4.9 UPnP/1.0 MediaRenderer/1.0\r\n
USN: uuid:12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n
\r\n
```

`NTS` values:
- `ssdp:alive` — device is available.
- `ssdp:byebye` — device is leaving the network.

Listen for NOTIFY messages by binding to the multicast group to passively discover devices without sending M-SEARCH.

### Dart Socket Setup

```dart
import 'dart:io';

Future<RawDatagramSocket> createSsdpSocket() async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4, // 0.0.0.0
    0, // OS-assigned port for receiving unicast replies
  );

  socket.broadcastEnabled = true;
  socket.multicastHops = 4;

  // Join multicast group to receive NOTIFY advertisements
  try {
    socket.joinMulticast(InternetAddress('239.255.255.250'));
  } catch (e) {
    // Some platforms need the interface specified
    final interfaces = await NetworkInterface.list();
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          try {
            socket.joinMulticast(
              InternetAddress('239.255.255.250'),
              interface,
            );
            break;
          } catch (_) {}
        }
      }
    }
  }

  return socket;
}
```

**iOS Workaround:** On iOS, `joinMulticast` can fail silently. Use `setRawOption` to set `IP_ADD_MEMBERSHIP` at the socket level:

```dart
import 'dart:typed_data';

void joinMulticastiOS(RawDatagramSocket socket, String multicastAddr, String interfaceAddr) {
  // IP_ADD_MEMBERSHIP = level IPPROTO_IP (0), option 12
  // struct ip_mreq { struct in_addr multiaddr; struct in_addr interface; }
  final mreq = Uint8List(8);
  // Multicast address bytes
  final multicastParts = multicastAddr.split('.').map(int.parse).toList();
  mreq[0] = multicastParts[0];
  mreq[1] = multicastParts[1];
  mreq[2] = multicastParts[2];
  mreq[3] = multicastParts[3];
  // Interface address bytes (0.0.0.0 = any)
  final ifaceParts = interfaceAddr.split('.').map(int.parse).toList();
  mreq[4] = ifaceParts[0];
  mreq[5] = ifaceParts[1];
  mreq[6] = ifaceParts[2];
  mreq[7] = ifaceParts[3];

  socket.setRawOption(RawSocketOption(
    RawSocketOption.levelIPv4,   // IPPROTO_IP = 0
    12,                          // IP_ADD_MEMBERSHIP
    mreq,
  ));
}
```

**Sending the M-SEARCH:**

```dart
void sendMSearch(RawDatagramSocket socket) {
  const mSearch = 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      'MX: 3\r\n'
      '\r\n';

  socket.send(
    mSearch.codeUnits,
    InternetAddress('239.255.255.250'),
    1900,
  );
}
```

**Receiving responses:**

```dart
socket.listen((event) {
  if (event == RawSocketEvent.read) {
    final datagram = socket.receive();
    if (datagram != null) {
      final response = String.fromCharCodes(datagram.data);
      final locationMatch = RegExp(
        r'LOCATION:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(response);
      if (locationMatch != null) {
        final location = locationMatch.group(1)!.trim();
        // Fetch device description from this URL
      }
    }
  }
});
```

---

## 2. Device Description XML

Once you have the `LOCATION` URL from SSDP, perform an HTTP GET to retrieve the device description XML.

### Request

```
GET /description.xml HTTP/1.1
Host: 192.168.1.50:49152
```

No special headers required. A simple HTTP GET is sufficient.

### Response XML Structure

```xml
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <URLBase>http://192.168.1.50:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room TV</friendlyName>
    <manufacturer>Samsung</manufacturer>
    <modelName>UE55</modelName>
    <UDN>uuid:12345678-1234-1234-1234-123456789abc</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <SCPDURL>/ConnectionManager/scpd.xml</SCPDURL>
        <controlURL>/ConnectionManager/control</controlURL>
        <eventSubURL>/ConnectionManager/event</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>
```

### Key Elements to Extract

| Element | Description |
|---------|-------------|
| `friendlyName` | Human-readable device name to display in the UI. |
| `deviceType` | Must contain `MediaRenderer` for casting targets. |
| `UDN` | Universally unique device name. Use this as the device identifier. |
| `controlURL` | The path to POST SOAP actions to. Found under each `<service>`. |
| `eventSubURL` | For subscribing to state change events (optional). |
| `SCPDURL` | Service description — lists supported actions (optional). |

### Extracting Service URLs

You need two services:

1. **AVTransport** — controls playback (play, pause, stop, seek, set media URI).
2. **RenderingControl** — controls volume and mute.

Find them by matching `<serviceType>`:

- AVTransport: `urn:schemas-upnp-org:service:AVTransport:1`
- RenderingControl: `urn:schemas-upnp-org:service:RenderingControl:1`

**Resolving the control URL:**

The `controlURL` may be absolute or relative. If relative, resolve it against the `URLBase` element (if present) or the `LOCATION` URL:

```
If controlURL = "/AVTransport/control"
   and URLBase = "http://192.168.1.50:49152"
Then full URL = "http://192.168.1.50:49152/AVTransport/control"

If controlURL = "http://192.168.1.50:49152/AVTransport/control"
Then use it as-is.
```

### XML Namespace

The description XML uses namespace `urn:schemas-upnp-org:device-1-0`. When parsing with an XML library that is namespace-aware, query elements in this namespace.

---

## 3. SOAP AVTransport Actions

All AVTransport control is done via SOAP (XML over HTTP POST) to the AVTransport `controlURL`.

### Common HTTP Headers

Every SOAP request uses these headers:

```
POST /AVTransport/control HTTP/1.1
Host: 192.168.1.50:49152
Content-Type: text/xml; charset="utf-8"
SOAPAction: "urn:schemas-upnp-org:service:AVTransport:1#ActionName"
Content-Length: <body-length>
```

Replace `ActionName` with the specific action name (e.g., `SetAVTransportURI`, `Play`, etc.).

### SOAP Envelope Structure

Every request body follows this structure:

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:ActionName xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <!-- action arguments here -->
    </u:ActionName>
  </s:Body>
</s:Envelope>
```

---

### SetAVTransportURI

Sets the media URL to play. Must be called before Play.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>http://example.com/video.mp4</CurrentURI>
      <CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot; xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot;&gt;&lt;item id=&quot;0&quot; parentID=&quot;-1&quot; restricted=&quot;1&quot;&gt;&lt;dc:title&gt;My Video&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;res protocolInfo=&quot;http-get:*:video/mp4:*&quot;&gt;http://example.com/video.mp4&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>
```

**Important:** The `CurrentURIMetaData` value is XML-escaped DIDL-Lite (see Section 4). Many devices work with an empty string `""` for `CurrentURIMetaData`, but providing proper metadata improves compatibility and enables the device to display title/thumbnail information. Some devices (especially Samsung) require valid DIDL-Lite.

**Response (success):**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
    </u:SetAVTransportURIResponse>
  </s:Body>
</s:Envelope>
```

---

### Play

Starts playback. Call after SetAVTransportURI.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#Play"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>
```

---

### Pause

Pauses playback.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#Pause"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Pause>
  </s:Body>
</s:Envelope>
```

**Note:** Not all devices support Pause. If a device returns a SOAP fault with error code 701 (`Transition not available`), the device does not support pausing. Fall back to Stop + Play with a saved position.

---

### Stop

Stops playback completely.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#Stop"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>
```

---

### Seek

Seeks to a specific position in the currently playing media.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#Seek"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Unit>REL_TIME</Unit>
      <Target>00:25:30</Target>
    </u:Seek>
  </s:Body>
</s:Envelope>
```

**Unit values:**

| Unit | Target format | Description |
|------|---------------|-------------|
| `REL_TIME` | `HH:MM:SS` | Seek to an absolute position from the start. This is the most widely supported mode. |
| `ABS_TIME` | `HH:MM:SS` | Absolute time (usually same as REL_TIME for single-track playback). |
| `ABS_COUNT` | integer | Absolute counter position (rarely used). |
| `REL_COUNT` | integer | Relative counter position (rarely used). |

Always use `REL_TIME`. The `Target` value must be in `HH:MM:SS` format (see Section 5).

---

### GetPositionInfo

Returns current playback position, duration, and track URI. Poll this periodically (every 1-2 seconds) to update the UI.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>
```

**Response body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>01:42:30</TrackDuration>
      <TrackMetaData>&lt;DIDL-Lite ...&gt;...&lt;/DIDL-Lite&gt;</TrackMetaData>
      <TrackURI>http://example.com/video.mp4</TrackURI>
      <RelTime>00:25:30</RelTime>
      <AbsTime>00:25:30</AbsTime>
      <RelCount>2147483647</RelCount>
      <AbsCount>2147483647</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>
```

**Key response fields:**

| Field | Description |
|-------|-------------|
| `TrackDuration` | Total duration of the media in `HH:MM:SS` format. May be `NOT_IMPLEMENTED` if unknown. |
| `RelTime` | Current playback position in `HH:MM:SS` format. This is what you use for the progress bar. |
| `AbsTime` | Absolute time position. Usually the same as `RelTime`. |
| `TrackURI` | The URI currently being played. |
| `TrackMetaData` | XML-escaped DIDL-Lite metadata (may be empty). |

**Special values:** Some devices return `NOT_IMPLEMENTED` or `00:00:00` for fields they do not support. Handle these gracefully.

---

### GetTransportInfo

Returns the current playback state. Poll this alongside GetPositionInfo.

**SOAPAction:** `"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetTransportInfo>
  </s:Body>
</s:Envelope>
```

**Response body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>PLAYING</CurrentTransportState>
      <CurrentTransportStatus>OK</CurrentTransportStatus>
      <CurrentSpeed>1</CurrentSpeed>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>
```

**CurrentTransportState values:**

| State | Meaning |
|-------|---------|
| `STOPPED` | Playback is stopped. No media is playing. |
| `PLAYING` | Media is currently playing. |
| `PAUSED_PLAYBACK` | Playback is paused. |
| `TRANSITIONING` | Device is buffering or preparing to play. Treat as a loading state. |
| `NO_MEDIA_PRESENT` | No media URI has been set. |

**CurrentTransportStatus values:**
- `OK` — normal operation.
- `ERROR_OCCURRED` — something went wrong. Check device logs or retry.

---

### RenderingControl: GetVolume

**SOAPAction:** `"urn:schemas-upnp-org:service:RenderingControl:1#GetVolume"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
    </u:GetVolume>
  </s:Body>
</s:Envelope>
```

**Response body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <CurrentVolume>45</CurrentVolume>
    </u:GetVolumeResponse>
  </s:Body>
</s:Envelope>
```

`CurrentVolume` is an integer from 0 to 100.

---

### RenderingControl: SetVolume

**SOAPAction:** `"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
      <DesiredVolume>60</DesiredVolume>
    </u:SetVolume>
  </s:Body>
</s:Envelope>
```

---

### RenderingControl: GetMute

**SOAPAction:** `"urn:schemas-upnp-org:service:RenderingControl:1#GetMute"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
    </u:GetMute>
  </s:Body>
</s:Envelope>
```

**Response body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetMuteResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <CurrentMute>0</CurrentMute>
    </u:GetMuteResponse>
  </s:Body>
</s:Envelope>
```

`CurrentMute`: `0` = not muted, `1` = muted.

---

### RenderingControl: SetMute

**SOAPAction:** `"urn:schemas-upnp-org:service:RenderingControl:1#SetMute"`

**Request body:**

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
      <DesiredMute>1</DesiredMute>
    </u:SetMute>
  </s:Body>
</s:Envelope>
```

`DesiredMute`: `0` = unmute, `1` = mute.

---

### SOAP Error Response

When an action fails, the device returns an HTTP 500 with a SOAP fault:

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>716</errorCode>
          <errorDescription>Resource not found</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>
```

**Common error codes:**

| Code | Meaning |
|------|---------|
| 401 | Invalid action |
| 402 | Invalid arguments |
| 501 | Action failed |
| 701 | Transition not available (e.g., Pause not supported) |
| 716 | Resource not found |

---

## 4. DIDL-Lite Metadata Format

DIDL-Lite (Digital Item Declaration Language - Lite) is the metadata format used in `CurrentURIMetaData` for `SetAVTransportURI` and returned in `GetPositionInfo`.

### Namespaces

```xml
<DIDL-Lite
  xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
  xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"
  xmlns:sec="http://www.sec.co.kr/dlna"
  xmlns:pv="http://www.pv.com/pvns/">
```

### Basic Video Metadata Template

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Episode 1 - The Beginning</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*">http://example.com/video.mp4</res>
  </item>
</DIDL-Lite>
```

### protocolInfo Format

```
<protocol>:<network>:<contentFormat>:<additionalInfo>
```

For HTTP streaming, the format is:

```
http-get:*:<mime-type>:*
```

**Common MIME types:**

| MIME Type | Usage |
|-----------|-------|
| `video/mp4` | MP4 video files (H.264/H.265). Most widely supported. |
| `video/mp2t` | MPEG-2 Transport Stream. Used for HLS segments. |
| `video/x-matroska` | MKV container. Limited device support. |
| `application/vnd.apple.mpegurl` | HLS master playlist (.m3u8). Some DLNA devices support this. |
| `application/x-mpegURL` | Alternative HLS MIME type. |
| `video/avi` | AVI container. |
| `video/x-ms-wmv` | Windows Media Video. |
| `audio/mpeg` | MP3 audio. |
| `audio/mp4` | AAC audio. |
| `image/jpeg` | JPEG image. |

**DLNA-specific protocolInfo with profile:**

For better device compatibility, include DLNA profile information:

```
http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_SD_AAC_MULT5;DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01500000000000000000000000000000
```

The simplified form `http-get:*:video/mp4:*` works with most devices.

### upnp:class Values

| Class | Description |
|-------|-------------|
| `object.item.videoItem` | Generic video. |
| `object.item.videoItem.movie` | Movie. |
| `object.item.audioItem` | Generic audio. |
| `object.item.audioItem.musicTrack` | Music track. |
| `object.item.imageItem` | Image. |

### Subtitle Approaches

There are three methods for delivering subtitles to DLNA renderers. Support varies by manufacturer.

#### Method 1: Samsung sec:CaptionInfoEx (Most Widely Supported)

This is the most compatible approach across Samsung, LG, and many other devices.

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:sec="http://www.sec.co.kr/dlna">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Episode 1</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*">http://example.com/video.mp4</res>
    <sec:CaptionInfoEx sec:type="srt">http://example.com/subtitles.srt</sec:CaptionInfoEx>
    <sec:CaptionInfoEx sec:type="vtt">http://example.com/subtitles.vtt</sec:CaptionInfoEx>
  </item>
</DIDL-Lite>
```

Supported subtitle formats via `sec:type`:
- `srt` — SubRip (most widely supported subtitle format)
- `vtt` — WebVTT
- `smi` — SAMI
- `ass` — Advanced SubStation Alpha
- `ssa` — SubStation Alpha

#### Method 2: Separate res Element for Subtitle File

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Episode 1</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*">http://example.com/video.mp4</res>
    <res protocolInfo="http-get:*:text/srt:*">http://example.com/subtitles.srt</res>
  </item>
</DIDL-Lite>
```

MIME types for subtitles:
- `text/srt` — SRT
- `text/vtt` — WebVTT
- `application/x-subrip` — SRT (alternative)

#### Method 3: pv:subtitleFileUri (LG, Sony)

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:pv="http://www.pv.com/pvns/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Episode 1</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*"
         pv:subtitleFileType="srt"
         pv:subtitleFileUri="http://example.com/subtitles.srt">
      http://example.com/video.mp4
    </res>
  </item>
</DIDL-Lite>
```

#### Maximum Compatibility: All Three Methods Combined

For best device coverage, include all three subtitle delivery methods:

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:sec="http://www.sec.co.kr/dlna"
           xmlns:pv="http://www.pv.com/pvns/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Episode 1</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*"
         pv:subtitleFileType="srt"
         pv:subtitleFileUri="http://example.com/subtitles.srt">
      http://example.com/video.mp4
    </res>
    <res protocolInfo="http-get:*:text/srt:*">http://example.com/subtitles.srt</res>
    <sec:CaptionInfoEx sec:type="srt">http://example.com/subtitles.srt</sec:CaptionInfoEx>
  </item>
</DIDL-Lite>
```

### XML Escaping for CurrentURIMetaData

The DIDL-Lite XML must be XML-escaped when placed inside the `<CurrentURIMetaData>` element of the SOAP envelope. Key escapes:

| Character | Escape |
|-----------|--------|
| `<` | `&lt;` |
| `>` | `&gt;` |
| `"` | `&quot;` |
| `'` | `&apos;` |
| `&` | `&amp;` |

---

## 5. Time Format

DLNA uses `HH:MM:SS` format for all time values (duration, position, seek target).

### Format Specification

```
HH:MM:SS
```

- `HH` — hours, zero-padded (00-99)
- `MM` — minutes, zero-padded (00-59)
- `SS` — seconds, zero-padded (00-59)

Some devices also support fractional seconds: `HH:MM:SS.mmm` (milliseconds).

### String to Seconds

```dart
int timeStringToSeconds(String time) {
  // Handle NOT_IMPLEMENTED or empty values
  if (time.isEmpty || time == 'NOT_IMPLEMENTED') return 0;

  final parts = time.split(':');
  if (parts.length != 3) return 0;

  final hours = int.tryParse(parts[0]) ?? 0;
  final minutes = int.tryParse(parts[1]) ?? 0;
  // Handle fractional seconds (e.g., "30.500")
  final seconds = double.tryParse(parts[2])?.truncate() ?? 0;

  return (hours * 3600) + (minutes * 60) + seconds;
}
```

### Seconds to String

```dart
String secondsToTimeString(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  return '${hours.toString().padLeft(2, '0')}:'
         '${minutes.toString().padLeft(2, '0')}:'
         '${seconds.toString().padLeft(2, '0')}';
}
```

---

## 6. Typical Flow

A complete DLNA casting session follows these steps:

1. **Discover devices** — Send an M-SEARCH datagram to `239.255.255.250:1900`. Collect LOCATION URLs from responses. Also listen for NOTIFY advertisements.

2. **Parse LOCATION** — Extract the `LOCATION` header value from each SSDP response. Deduplicate by URL or USN.

3. **Fetch device description** — HTTP GET each LOCATION URL. Parse the returned XML.

4. **Filter media renderers** — Check that `deviceType` contains `MediaRenderer`. Extract `friendlyName` for display.

5. **Extract control URLs** — From the `serviceList`, find services with `serviceType` matching:
   - `urn:schemas-upnp-org:service:AVTransport:1` — for playback control
   - `urn:schemas-upnp-org:service:RenderingControl:1` — for volume control

   Resolve each `controlURL` against `URLBase` or the LOCATION URL.

6. **Set media URI** — POST `SetAVTransportURI` to the AVTransport control URL with the video URL and DIDL-Lite metadata. Wait for a success response.

7. **Start playback** — POST `Play` to the AVTransport control URL. Confirm the transport state transitions to `PLAYING` by polling `GetTransportInfo`.

8. **Poll playback state** — Start a periodic timer (every 1-2 seconds) that calls both `GetPositionInfo` and `GetTransportInfo`. Use the responses to update:
   - Progress bar position (`RelTime` / `TrackDuration`)
   - Play/pause button state (`CurrentTransportState`)

9. **User controls** — Respond to UI interactions:
   - Seek: `Seek` with `REL_TIME` and `HH:MM:SS` target.
   - Pause: `Pause` action.
   - Resume: `Play` action.
   - Volume: `SetVolume` on RenderingControl.
   - Mute: `SetMute` on RenderingControl.

10. **Stop** — When the user exits the casting session or playback ends (detected by `CurrentTransportState` becoming `STOPPED`), POST `Stop` and clean up the polling timer.

---

## 7. All Namespaces and URNs

### XML Namespaces

| Prefix | Namespace URI | Used In |
|--------|---------------|---------|
| (default) | `urn:schemas-upnp-org:device-1-0` | Device description XML |
| (default) | `urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/` | DIDL-Lite metadata |
| `s` | `http://schemas.xmlsoap.org/soap/envelope/` | SOAP envelope |
| `u` | `urn:schemas-upnp-org:service:AVTransport:1` | AVTransport SOAP actions |
| `u` | `urn:schemas-upnp-org:service:RenderingControl:1` | RenderingControl SOAP actions |
| `dc` | `http://purl.org/dc/elements/1.1/` | Dublin Core metadata (title, creator) |
| `upnp` | `urn:schemas-upnp-org:metadata-1-0/upnp/` | UPnP metadata (class, genre) |
| `dlna` | `urn:schemas-dlna-org:metadata-1-0/` | DLNA-specific metadata |
| `sec` | `http://www.sec.co.kr/dlna` | Samsung extensions (CaptionInfoEx) |
| `pv` | `http://www.pv.com/pvns/` | LG/Sony extensions (subtitleFileUri) |

### SOAP Encoding

| Attribute | Value |
|-----------|-------|
| `s:encodingStyle` | `http://schemas.xmlsoap.org/soap/encoding/` |

### SOAPAction Header URNs

| Service | SOAPAction Format |
|---------|-------------------|
| AVTransport | `"urn:schemas-upnp-org:service:AVTransport:1#<ActionName>"` |
| RenderingControl | `"urn:schemas-upnp-org:service:RenderingControl:1#<ActionName>"` |

### UPnP Device and Service Type URNs

| URN | Description |
|-----|-------------|
| `urn:schemas-upnp-org:device:MediaRenderer:1` | DLNA media renderer device |
| `urn:schemas-upnp-org:device:MediaServer:1` | DLNA media server device |
| `urn:schemas-upnp-org:service:AVTransport:1` | Audio/Video transport control service |
| `urn:schemas-upnp-org:service:RenderingControl:1` | Volume and mute control service |
| `urn:schemas-upnp-org:service:ConnectionManager:1` | Connection management service |
| `urn:schemas-upnp-org:service:ContentDirectory:1` | Content browsing service (servers only) |

### SSDP URNs

| URN | Description |
|-----|-------------|
| `ssdp:all` | Discover all devices and services |
| `ssdp:alive` | NOTIFY subtype: device available |
| `ssdp:byebye` | NOTIFY subtype: device leaving |
| `upnp:rootdevice` | Discover root devices only |

### UPnP Error Namespace

| Namespace | URI |
|-----------|-----|
| UPnP Error | `urn:schemas-upnp-org:control-1-0` |
