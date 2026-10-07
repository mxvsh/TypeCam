# OBS Plugin — obs-typecam

macOS only (v1), OBS Studio **31+**, universal binary (arm64 + x86_64). Built from the official
[`obs-plugintemplate`](https://github.com/obsproject/obs-plugintemplate) with CMake. C for core logic,
Objective-C++ (`.mm`) for VideoToolbox and AudioToolbox.

## Source

Registers one source type:

| Field | Value |
|---|---|
| id | `typecam_source` |
| name | "TypeCam (iPhone)" |
| type | `OBS_SOURCE_TYPE_INPUT` |
| flags | `OBS_SOURCE_ASYNC_VIDEO \| OBS_SOURCE_AUDIO \| OBS_SOURCE_DO_NOT_DUPLICATE` |

### Properties

| Property | Type | Default | Notes |
|---|---|---|---|
| Device | list | First available | Lists attached devices by name (from `HELLO_ACK`, cached) or by UDID before the first connect. Selection is saved by UDID. |
| Low latency (unbuffered) | bool | On | `obs_source_set_async_unbuffered()` |
| When paused / disconnected | list | Keep last frame | Keep last frame · Transparent |
| Status | info text | — | Connected device, resolution/fps/codec, bitrate, dropped frames, latency. Refreshed while the properties window is open. |
| Request keyframe | button | — | Debugging aid |

Two sources may not select the same device. The second one shows "In use by another source".

## Threads

- **Device monitor** (process-wide, one thread): holds a usbmuxd `Listen` connection and keeps the attached
  device list (`DeviceID`, `SerialNumber` = UDID). Sources subscribe to attach/detach events.
- **Per source connection thread:** `Connect(DeviceID, 7878)` → `HELLO` → read loop → demux. On disconnect it
  waits for a re-attach or retries every 1 s.
- **Decode:** `VTDecompressionSession` callback (VT's own thread). Output CVPixelBuffers (NV12,
  `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) are wrapped as `obs_source_frame` with
  `VIDEO_FORMAT_NV12`, full range, BT.709, and timestamps re-based to `os_gettime_ns()`, then sent with
  `obs_source_output_video()`.

## Audio

- PCM: converted s16 → float planar and sent with `obs_source_output_audio()`.
- AAC: an `AudioConverter` is created from the `AUDIO_CONFIG` ASC and decodes one frame per packet.
- Timestamps use the same re-base as video, so A/V sync holds without OBS sync offsets.

## Rotation

Mirroring is done on the phone, so the plugin never flips. When `VIDEO_CONFIG.rotation` is non-zero, the plugin
rotates decoded frames with `VTPixelRotationSession` before output. For 90/270 this also swaps the source's
width and height.

## Repo layout

```
obs-plugin/
  CMakeLists.txt
  CMakePresets.json        (from template, macOS preset)
  buildspec.json           (OBS + deps versions)
  src/
    plugin-main.c
    typecam-source.c
    device-monitor.c
    usbmux.c / usbmux.h
    demux.c / demux.h
    vt-decoder.mm
    audio-decoder.mm
    protocol.h             (constants mirroring docs/PROTOCOL.md)
  data/locale/en-US.ini
```

## Build & install

```sh
cd obs-plugin
cmake --preset macos
cmake --build --preset macos
# dev install:
cp -R build_macos/RelWithDebInfo/obs-typecam.plugin \
  ~/Library/Application\ Support/obs-studio/plugins/
```

Distribution (M7): signed and notarized `.pkg` that installs to the per-user plugins folder.

## Requirements for users

- macOS 13+, OBS 31+.
- iPhone with TypeCam open in the foreground, connected by cable, with "Trust This Computer" accepted.
