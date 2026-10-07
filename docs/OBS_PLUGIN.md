# OBS Plugin — obs-typecam

macOS 13+ only (v1), OBS Studio **31+** (built against 31.1.1 headers, tested on 32.0.2), universal binary
(arm64 + x86_64). Built from the official [`obs-plugintemplate`](https://github.com/obsproject/obs-plugintemplate)
with CMake. Plain C throughout: usbmuxd via CoreFoundation plists, and decoding via the VideoToolbox C API.

## Source

Registers one source type:

| Field | Value |
|---|---|
| id | `typecam_source` |
| name | "TypeCam (iPhone)" |
| type | `OBS_SOURCE_TYPE_INPUT` |
| flags | `OBS_SOURCE_ASYNC_VIDEO \| OBS_SOURCE_DO_NOT_DUPLICATE` (`OBS_SOURCE_AUDIO` added in M4) |

### Properties

| Property | Type | Default | Notes |
|---|---|---|---|
| iPhone | list | First available | Attached devices as "Name (…last 6 of UDID)". The name comes from the phone's "Name in OBS" setting, cached once it has connected. Saved by UDID. A remembered device stays listed as "not connected" while unplugged. "First available" picks the first device no other source holds. |
| Refresh | button | — | Rebuilds the device list and status line |
| Status | info text | — | e.g. "Live: Studio cam · 1920x1080 @ 30 fps · HEVC · ~6 ms", or guidance such as "iPhone connected. Open TypeCam on it" |
| Low latency (unbuffered) | bool | On | `obs_source_set_async_unbuffered()` |
| When paused or disconnected | list | Keep last frame | Keep last frame · Show nothing |
| Request keyframe | button | — | Debugging aid |

Two sources can't use the same iPhone: a process-wide registry (`device-registry.c`) tracks which source holds which UDID.

## Threads

- **Per-source connection thread:** list devices (`usbmux_list_devices`) → claim → `Connect(DeviceID, 7878)` →
  `HELLO` → `poll()` read loop that demuxes messages. It sends `PING` and `HOST_STATS` every second and drops
  the connection after 3 s without data. On disconnect it releases the claim, resets the decoder and retries
  every 1 s. The device list is polled rather than watched with usbmuxd `Listen`, which is simpler and cheap at 1 Hz.
- **Decode:** synchronous `VTDecompressionSessionDecodeFrame` on the connection thread. Output CVPixelBuffers
  (NV12 `420f`) are wrapped as `obs_source_frame` (`VIDEO_FORMAT_NV12`, full range, BT.709) with timestamps
  re-based to `os_gettime_ns()` on the first frame, and sent with `obs_source_output_video()`, which copies them.
- **Latency estimate** (shown in Status): PING/PONG RTT/2 plus average decode time. It doesn't include capture
  and encode on the phone.

## Audio (M4)

- PCM: s16 converted to float planar and sent with `obs_source_output_audio()`.
- AAC: an `AudioConverter` built from the `AUDIO_CONFIG` ASC.
- Uses the same timestamp re-base as video, so A/V sync needs no OBS sync offset.

## Rotation

Mirroring is done on the phone, so the plugin never flips. When `VIDEO_CONFIG.rotation` is non-zero, the plugin
rotates decoded frames with `VTPixelRotationSession` before output. For 90/270 this also swaps the source's
width and height.

## Repo layout

```
obs-plugin/
  CMakeLists.txt, CMakePresets.json, buildspec.json   (template; macOS 13 target, metadata)
  cmake/                    (template helpers; buildnumber.cmake patched to default to 1 outside CI)
  src/
    plugin-main.c           module entry, registers the source
    typecam-source.c        source, properties, connection thread, demux
    usbmux.c / usbmux.h     usbmuxd client (ListDevices, Connect)
    device-registry.c / .h  UDID claims + cached device names
    vt-decoder.c / .h       VideoToolbox decode, rotation, OBS frame output
    protocol.h              constants mirroring docs/PROTOCOL.md
  data/locale/en-US.ini
```

## Build & install

```sh
cd obs-plugin
cmake --preset macos          # first run downloads OBS sources + obs-deps into .deps/ (several minutes)
cmake --build --preset macos
# dev install (quit OBS first):
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-typecam.plugin
cp -R build_macos/RelWithDebInfo/obs-typecam.plugin \
  ~/Library/Application\ Support/obs-studio/plugins/
```

If the first `cmake --build` after editing `CMakeLists.txt` fails at link time, run it again: the Xcode
project was being regenerated.

Distribution (M7): signed and notarized `.pkg` that installs to the per-user plugins folder.

## Requirements for users

- macOS 13+, OBS 31+.
- iPhone with TypeCam open in the foreground, connected by cable, with "Trust This Computer" accepted.
