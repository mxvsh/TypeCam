# Architecture

## Overview

```
 iPhone (TypeCam app)                                    Mac (OBS + obs-typecam)
┌──────────────────────────────────────────┐          ┌──────────────────────────────────────┐
│ AVCaptureSession ──► VideoEncoder (VT)   │          │  DeviceMonitor (usbmuxd Listen)      │
│   video frames        H.264 / HEVC       │          │        │ attach/detach (UDID)        │
│                           │              │          │        ▼                             │
│ AVAudioEngine ──► DSP ──► AudioEncoder   │          │  TypeCam source (one per OBS source) │
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
| Audio | 48 kHz AAC-LC or raw PCM s16, mono/stereo | PCM has zero codec delay and the cable has bandwidth to spare. AAC is available to keep bitrate down. |
| Clock | Capture PTS on host time (`mach_absolute_time` → ns) | AVCaptureSession and AVAudioEngine both use the host clock, so A/V stay in sync. The plugin re-bases PTS to `os_gettime_ns()` on first frame. |
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
| `Audio/` | `AudioController`: `AVAudioSession` routing (input device, data source, polar pattern), `AVAudioEngine` graph, gain, low-cut, presets, metering, FFT spectrum |
| `Encode/` | `VideoEncoder` (`VTCompressionSession`) and `AudioEncoder` (`AVAudioConverter` → AAC, or PCM passthrough) |
| `Transport/` | `StreamServer` (`NWListener` on 7878), packet framing, send queue with backpressure, ping/telemetry |
| `Settings/` | `SettingsStore`: `Codable` settings persisted to `UserDefaults`, plus device-capability clamping |
| `Overlays/` | Metal shaders for histogram, zebra and focus peaking, applied to the preview only and never to the stream |
| `UI/` | Camera screen, settings screens, theme, reusable controls (pills, segmented, meters) |

**Concurrency:** the project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Capture, audio, encode and
transport work must run off the main actor, on dedicated serial queues or actors marked `nonisolated`
where appropriate. Only UI state is main-actor.

**Video path:** `AVCaptureVideoDataOutput` (420f biplanar, `alwaysDiscardsLateVideoFrames = true`) sends
each `CMSampleBuffer` to the encoder and, downsampled, to the Metal preview and overlays. The same buffer
feeds both, so the preview shows exactly what is streamed.

**Audio path:** the capture session does not own the mic
(`automaticallyConfiguresApplicationAudioSession = false`). `AVAudioEngine` input runs through
gain → low-cut → preset EQ/compressor (`AVAudioUnitEQ`, `AVAudioUnitEffect`) → a tap that feeds
metering, FFT and the encoder.

## OBS plugin modules

| File / unit | Responsibility |
|---|---|
| `usbmux.c` | Client for the `/var/run/usbmuxd` Unix socket (plist protocol): `ListDevices`, `Listen`, `Connect` |
| `device-monitor.c` | Process-wide attach/detach tracking shared by all sources |
| `typecam-source.c` | `obs_source_info` registration, properties, lifecycle, connection thread |
| `demux.c` | Parses TypeCam packets ([PROTOCOL.md](PROTOCOL.md)) |
| `vt-decoder.mm` | `VTDecompressionSession` for H.264/HEVC producing NV12 `obs_source_frame`s |
| `audio-decoder.mm` | AAC → float planar via `AudioConverter`. PCM is passed through. |

## Failure handling

- **Cable pulled / app backgrounded:** the socket closes. The source keeps the last frame or goes transparent (a property), and the device monitor reconnects automatically when the device reappears or the app returns to the foreground.
- **Decoder error or mid-stream join:** the plugin sends `KEYFRAME_REQUEST`. The phone forces an IDR.
- **Congestion:** if the phone's send queue exceeds its limit, it drops non-key video frames until the next IDR and forces one. Audio is never dropped.
- **Thermal pressure:** the phone reports `thermalState`. At `.serious` it shows a warning; at `.critical` it steps down fps/resolution and tells the user.

## Known platform constraints

- iOS stops camera capture when the app is backgrounded or the screen locks. TypeCam keeps the idle timer disabled and offers a dim/blackout mode instead of locking.
- The USB-C port carries the stream, so a **wired USB-C mic needs a hub** with pass-through. Bluetooth mics use HFP and are lower fidelity. AirPods high-quality recording is only available on iOS 26+ and is enabled conditionally.
- Video stabilization adds latency (Cinematic modes significantly), so v1 offers only Off/Standard.
- Verify in M2: whether `NWListener` on the device triggers the Local Network permission for usbmux-tunnelled connections. If it does, add `NSLocalNetworkUsageDescription`.
