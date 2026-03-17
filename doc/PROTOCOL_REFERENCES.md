# Protocol References

Sources used to implement the AirPlay, Chromecast, and DLNA protocols in dart_cast.

## AirPlay

- [Unofficial AirPlay Protocol Specification](https://nto.github.io/AirPlay.html) — Original AirPlay 1 spec (video, audio, photo)
- [OpenAirPlay Spec](https://openairplay.github.io/airplay-spec/) — Community-maintained AirPlay specification
- [OpenAirPlay Spec — Video HTTP Requests](https://openairplay.github.io/airplay-spec/video/http_requests.html) — POST /play, /rate, /scrub, /stop, /playback-info
- [OpenAirPlay Spec — Features](https://openairplay.github.io/airplay-spec/features.html) — Feature bitmask reference
- [AirPlay 2 Internals — Features](https://emanuelecozzi.net/docs/airplay2/features/) — AirPlay 2 feature flags documentation
- [AirPlay 2 Internals — RTSP](https://emanuelecozzi.net/docs/airplay2/rtsp/) — RTSP audio streaming protocol
- [pyatv](https://github.com/postlund/pyatv) — Python Apple TV client library (SRP-6a, HAP pair-setup/verify, RTSP session reference)
- [watson/airplay-protocol](https://github.com/watson/airplay-protocol) — Node.js AirPlay 1 client (V1 text/parameters format reference)
- [openairplay/airplay2-receiver](https://github.com/openairplay/airplay2-receiver) — Python AirPlay 2 receiver (audio only)
- [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) — Objective-C AirPlay 2 sender reference
- [UxPlay](https://github.com/FDH2/UxPlay) — Open-source AirPlay receiver with mirroring and HLS video
- [pyatv Issue #1518](https://github.com/postlund/pyatv/issues/1518) — /play 404 on non-Apple devices (feature flag analysis)
- [pyatv Issue #2204](https://github.com/postlund/pyatv/issues/2204) — Force AirPlay V1/V2 version selection

## Chromecast (CASTV2)

- [nicoretti/cast_channel.proto](https://github.com/nicoretti/cast-channel-protocol) — Chromecast protobuf definitions
- Google Cast SDK documentation — Default Media Receiver (CC1AD845)

## DLNA/UPnP

- [UPnP Device Architecture v1.0](http://upnp.org/specs/arch/UPnP-arch-DeviceArchitecture-v1.0.pdf) — SSDP discovery, SOAP control
- [AVTransport:1 Service](http://upnp.org/specs/av/UPnP-av-AVTransport-v1-Service.pdf) — Play, Pause, Seek, Stop, GetTransportInfo
- [RenderingControl:1 Service](http://upnp.org/specs/av/UPnP-av-RenderingControl-v1-Service.pdf) — Volume control
