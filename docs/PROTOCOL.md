# TypeCam Wire Protocol — v1

This is the contract between the iOS app (server) and the OBS plugin (client). Any change here must be made
in both `ios/` and `obs-plugin/` in the same commit, and must bump `protocol_version` if it is not
backward-compatible.

## Connection

1. The phone's app listens on TCP port **7878** whenever it is in the foreground.
2. The plugin opens `/var/run/usbmuxd` and sends `Connect { DeviceID, PortNumber }`. The port must be in
   **network byte order** (`htons(7878)`). Once usbmuxd replies `Result = 0`, the Unix socket becomes a
   raw byte pipe to the phone.
3. The plugin sends `HELLO`. The phone replies `HELLO_ACK`, then `VIDEO_CONFIG`, `AUDIO_CONFIG` (if audio
   is enabled), `STREAM_STATE`, and starts sending media beginning with an IDR frame.
4. **One client per phone.** A new connection replaces the existing one (the newest wins). This handles an
   OBS restart where the old socket is half-open.

## Framing

Every message is a 16-byte header followed by `length` bytes of payload. All integers are **little-endian**.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 2 | `magic` | `0x5443` (`"TC"`) |
| 2 | 1 | `type` | see table below |
| 3 | 1 | `flags` | bit 0 = keyframe (video), others reserved (0) |
| 4 | 4 | `length` | payload bytes, max 8 MiB |
| 8 | 8 | `pts_ns` | capture time in host nanoseconds. 0 for non-media messages. |

On a bad `magic` or an oversized `length`, the receiver closes the connection.

## Message types

| Type | Name | Dir | Payload |
|---|---|---|---|
| `0x01` | `HELLO` | P→I | JSON: `{"protocol_version":1,"client":"obs-typecam","client_version":"1.0.0"}` |
| `0x02` | `HELLO_ACK` | I→P | JSON: `{"protocol_version":1,"device_name":"Monawwar's iPhone","model":"iPhone17,1","app_version":"1.0.0","ok":true}`. On a version mismatch it sends `"ok":false,"error":"..."` and closes. |
| `0x10` | `VIDEO_CONFIG` | I→P | see below. Sent before the first frame and again whenever the codec, resolution or parameter sets change. |
| `0x11` | `VIDEO_FRAME` | I→P | One access unit in **AVCC** form (4-byte big-endian length-prefixed NAL units, as VideoToolbox emits them). `flags.keyframe` is set on IDR. |
| `0x20` | `AUDIO_CONFIG` | I→P | JSON: `{"format":"aac"\|"pcm_s16le","sample_rate":48000,"channels":1\|2,"asc":"<base64 AudioSpecificConfig, aac only>"}` |
| `0x21` | `AUDIO_FRAME` | I→P | AAC: one raw AAC-LC frame (no ADTS). PCM: interleaved s16le samples. `pts_ns` = time of the first sample. |
| `0x30` | `DEVICE_STATUS` | I→P | JSON, about 1 Hz: `{"battery":0.82,"charging":true,"thermal":"nominal"\|"fair"\|"serious"\|"critical","fps":59.9,"bitrate_kbps":12000,"dropped_frames":3,"lens":"wide","zoom":1.0}` |
| `0x31` | `HOST_STATS` | P→I | JSON, about 1 Hz: `{"decoded_fps":59.9,"dropped_frames":0,"latency_ms":62,"obs_version":"31.1.0"}`. Shown on the phone. |
| `0x32` | `KEYFRAME_REQUEST` | P→I | empty |
| `0x40` | `PING` | both | 8-byte sender timestamp (ns) |
| `0x41` | `PONG` | both | echoes the `PING` payload |
| `0x50` | `STREAM_STATE` | I→P | JSON: `{"state":"live"\|"paused"}`. While paused, no media is sent. The plugin applies its "when paused" property. |

Unknown message types must be **ignored** (skip `length` bytes). This allows additive extensions without a version bump.

### `VIDEO_CONFIG` payload

```
offset size field
0      1    codec          1 = H.264, 2 = HEVC
1      1    reserved       0
2      2    width          encoded pixel width
4      2    height         encoded pixel height
6      2    fps_num
8      2    fps_den
10     2    rotation       degrees clockwise the frame must be rotated for display (0/90/180/270)
12     1    ps_count       number of parameter sets that follow
13     ...  repeated ps_count times: u16 length (LE) + raw NAL (SPS/PPS, or VPS/SPS/PPS for HEVC, no start code)
```

The plugin builds its `CMVideoFormatDescription` with
`CMVideoFormatDescriptionCreateFromH264ParameterSets` / `...HEVCParameterSets`.

## Liveness

- Either side sends `PING` every **1 s** when idle.
- If nothing is received for **3 s**, the side closes the connection. The plugin then retries every 1 s
  while the device is attached.
- Latency estimate: the plugin measures PING/PONG round trip. `latency_ms` in `HOST_STATS` is
  `rtt/2 + decode time + queue time`.

## Encoder rules (phone side)

- `kVTCompressionPropertyKey_RealTime = true`, `AllowFrameReordering = false` (no B-frames).
- Use `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` where supported.
- Keyframe interval defaults to 1 s (`MaxKeyFrameIntervalDuration`). Force an IDR on `KEYFRAME_REQUEST`, on a new client, and after any queue drop.
- Send queue limit: about 3 video frames. On overflow, drop pending non-key frames and force an IDR.

## Test vectors

`tools/typecam-recv` (macOS CLI, added in M2) connects through usbmuxd, validates framing, and writes
`out.h264|hevc` + `out.wav` so a stream can be checked with `ffplay` independently of OBS.
