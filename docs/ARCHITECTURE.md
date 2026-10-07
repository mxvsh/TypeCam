# Architecture

## Overview

```
 iPhone (TypeCam app)                                    Mac (OBS + obs-typecam)
┌──────────────────────────────────────────┐          ┌──────────────────────────────────────┐
│ AVCaptureSession ──► VideoEncoder (VT)   │          │  usbmux ListDevices (1 Hz poll)      │
│   video frames        H.264 / HEVC       │          │        │ attach/detach (UDID)        │
│                           │              │          │        ▼                             │
│ Audio output ──► DSP ──► AudioEncoder    │          │  TypeCam source (one per OBS source) │
│   mic          lowcut/    AAC or PCM     │          │   usbmuxd Connect(UDID, 7878)        │
│                preset/gain    │          │          │        │                             │
│                           ▼   ▼          │   USB    │        ▼                             │
│                     StreamServer ════════╪══════════╪══► Demuxer ──► VTDecompression ──►   │
│                  NWListener :7878        │ usbmuxd  │        │        obs_source_output_   │
│                  framing + backpressure ◄╪══════════╪═══ stats /     video()               │
│                                          │  tunnel  │    keyframe req                      │
│ SwiftUI UI ◄── SettingsStore             │          │        └─► AudioConverter ──►        │
│ Metal preview + overlays                 │          │            obs_source_output_audio() │
└──────────────────────────────────────────┘          └──────────────────────────────────────┘
```

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| Transport | TCP over the **usbmuxd** tunnel | Built into macOS and used by Xcode. Gives a reliable, low-latency link with no pairing beyond "Trust this computer". The same approach Camo and EpocCam use. |
| Who listens | **Phone** is the server, plugin is the client | usbmuxd can only open connections *to* a device port. |
| Port | `7878` (device side) | Fixed and documented. Not configurable in v1. |
| Video | VideoToolbox hardware H.264 or HEVC, real-time, **no B-frames** | Low latency. Hardware decode on every supported Mac. |
| Audio | 48 kHz PCM s16 (default) or AAC-LC, mono/stereo | PCM has zero codec delay and the cable has bandwidth to spare (about 1.5 Mbps stereo). AAC adds about 45 ms of codec delay but cuts the bitrate. |
| Clock | Capture PTS on host time (`mach_absolute_time` → ns) | Video and audio come from one capture session on the host clock. The plugin re-bases both with **one shared offset** to `os_gettime_ns()` (set on the first media message), so A/V sync needs no OBS offset. |
| Latency target | **< 100 ms** glass-to-OBS at 1080p60 | Short GOP, real-time encoder, small queues, drop frames instead of buffering. |
| Multi-device | Each OBS source picks a device by UDID | Two phones can be two cameras. |
| Host OS | macOS only (v1) | Windows needs the Apple Mobile Device driver and Linux needs libimobiledevice. Both are deferred. |
| iOS dependencies | None (Apple frameworks only) | Keeps the build simple and future-proof. |

## iOS app modules

All modules live in the single `TypeCam` target, organized by folder:

| Folder | Responsibility |
|---|---|
| `App/` | App entry, scene lifecycle, idle-timer and dim management |
| `Capture/` | `CameraController`: session, virtual-device discovery, lens/zoom, focus/exposure/WB, torch, stabilization, rotation |
| `Audio/` | `AudioRouting` (`AVAudioSession` input, data source, polar pattern), `AudioDSP` (gain, presets, low-cut), `AudioPipeline` (conversion, metering, FFT spectrum → encoder) |
| `Encode/` | `VideoEncoder` (`VTCompressionSession`) and `AudioEncoder` (PCM s16le, or AAC-LC via `AVAudioConverter`) |
| `Transport/` | `Wire` (framing, mirrors `protocol.h`), `StreamServer` (`NWListener` on loopback 7878, handshake, heartbeat), `Streamer` (capture → encoder → server policy: config, keyframes, backpressure, pause) |
| `Settings/` | `SettingsStore`: `Codable` settings persisted to `UserDefaults`, plus device-capability clamping |
| `Preview/` | `FrameMailbox` (newest-frame handoff from the capture queue) and `PreviewRenderer` (Metal: NV12 → RGB, rotation, aspect-fill) |
| `Overlays/` | Metal shaders for histogram, zebra and focus peaking, applied to the preview only and never to the stream (M6) |
| `UI/` | Camera screen, settings screens, theme, reusable controls (option pickers, meters) |

**Concurrency:** the project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Capture, audio, encode and
transport work must run off the main actor, on dedicated serial queues or actors marked `nonisolated`
where appropriate. Only UI state is main-actor.

**Rotation:** frames always stay in the sensor's native landscape orientation
(`connection.videoRotationAngle = 0`). Turning the phone never re-rotates the pipeline, never glitches the
preview, and never restarts the encoder. `AVCaptureDevice.RotationCoordinator` provides the horizon-level
angle. `CameraModel` applies the orientation lock to it and sends the result to OBS as
`VIDEO_CONFIG.rotation`, which the plugin applies. The portrait-locked preview rotates by the coordinator's
preview angle. With front-camera mirroring on, quarter-turn angles get an extra 180° so that the mirror
reads left-right instead of upside down.

**Video path:** `AVCaptureVideoDataOutput` (420f biplanar, `alwaysDiscardsLateVideoFrames = true`) sends
each `CMSampleBuffer` to the encoder and, downsampled, to the Metal preview and overlays. The same buffer
feeds both, so the preview shows exactly what is streamed.

**Audio path:** the mic is an `AVCaptureDeviceInput` on the **same capture session** as video, read with
`AVCaptureAudioDataOutput`. Its buffers are about 20 ms long and stamped on the same host clock as video. An
`AVAudioEngine` tap was ruled out because taps deliver at least 100 ms per buffer. `AudioRouting` configures
`AVAudioSession` itself (`automaticallyConfiguresApplicationAudioSession = false`): `playAndRecord` with the
default mode, Bluetooth HFP, and Bluetooth high-quality recording on iOS 26+, plus the preferred input, data
source and polar pattern. `AudioPipeline` converts to float at the target rate and channel count, runs `AudioDSP`
(gain → preset EQ/compressor → low-cut, hand-written biquads), meters peaks, computes a vDSP FFT spectrum
(only while the Audio screen is open), and hands off to `AudioEncoder` (PCM s16le, or AAC-LC via
`AVAudioConverter`, with priming-corrected timestamps).

## OBS plugin modules

| File / unit | Responsibility |
|---|---|
| `usbmux.c` | Client for the `/var/run/usbmuxd` Unix socket (plist protocol): `ListDevices`, `Connect` |
| `device-registry.c` | Process-wide UDID claims (one source per iPhone) and cached device names |
| `typecam-source.c` | `obs_source_info` registration, properties, per-source connection thread, demux |
| `vt-decoder.c` | `VTDecompressionSession` for H.264/HEVC, `VTPixelRotationSession` rotation, NV12 `obs_source_frame` output |
| `audio-decoder.c` | PCM s16le passed straight to `obs_source_output_audio`; AAC-LC decoded to float via `AudioConverter` |

## Failure handling

- **Cable pulled / app backgrounded:** the socket closes. The source keeps the last frame or goes transparent (a property), and the connection thread reconnects automatically when the device reappears or the app returns to the foreground.
- **Decoder error or mid-stream join:** the plugin sends `KEYFRAME_REQUEST`. The phone forces an IDR.
- **Congestion:** if the phone's send queue exceeds its limit, it drops non-key video frames until the next IDR and forces one. Audio is never dropped.
- **Thermal pressure:** the phone reports `thermalState`. At `.serious` it shows a warning; at `.critical` it steps down fps/resolution and tells the user.

## Known platform constraints

- iOS stops camera capture when the app is backgrounded or the screen locks. TypeCam keeps the idle timer disabled and offers a dim/blackout mode instead of locking.
- The USB-C port carries the stream, so a **wired USB-C mic needs a hub** with pass-through. Bluetooth mics use HFP and are lower fidelity. AirPods high-quality recording is only available on iOS 26+ and is enabled conditionally.
- Video stabilization adds latency (Cinematic modes significantly), so v1 offers only Off/Standard.
- The listener binds to loopback only, so usbmux-tunnelled connections work without exposing a port on Wi-Fi.
- iOS hides the real device name from apps (`UIDevice.name` returns "iPhone"), so the name shown in OBS is a user setting.
