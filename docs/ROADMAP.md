# Roadmap

Each milestone is committed separately. A milestone is done when it builds clean, has been tested on a
real device, and its docs are updated.

## v1

| # | Milestone | Scope | Done when |
|---|---|---|---|
| M0 | Docs & scaffolding | Repo layout (`ios/`, `obs-plugin/`, `docs/`), template cleanup, iOS 18 target, v1 spec | ✅ |
| M1 | Capture & camera UI shell | Theme, `SettingsStore`, `CameraController` (virtual device, lens pills, zoom, flip, torch, rotation), Metal preview, camera screen layout, stream-state button (UI only), permissions | ✅ |
| M2 | Encode & transport (iOS) | `VideoEncoder` (H.264/HEVC, low-latency), `StreamServer` (loopback 7878, framing, backpressure, ping), `Streamer` (config/frames/state policy), live stream-state button, "Name in OBS" setting | ✅ (verified over USB with a scratch client; end-to-end latency measured in M3) |
| M3 | OBS plugin: video | Template setup, usbmux client, device registry, source + properties, VT decode → async video, rotation, keyframe request, multi-device, reconnect after lock/background | ✅ (single phone verified in OBS 32.0.2; two-phone and 1080p60 latency checks still to do) |
| M4 | Audio pipeline | Mic on the capture session, `AudioRouting` (input/data source/polar pattern), DSP (gain, mute, presets, low-cut), meters, spectrum, PCM/AAC encode, plugin audio decode, shared-clock A/V sync | ✅ (PCM verified in OBS 32.0.2; AAC path built, lightly tested) |
| M5 | Pro controls + control deck | Physical lenses (manual exposure needs them), manual focus/ISO/shutter/EV, tap-to-focus, AE/AF lock, WB lock; bottom control deck with sliding tabs and ruler dials replaces the rail | ✅ |
| M6 | Overlays | Grid, level, histogram, zebra, focus peaking (preview-only); ASSIST deck tab + Settings › Overlays | ✅ |
| M7 | Telemetry, power & polish | `DEVICE_STATUS`/`HOST_STATS`, telemetry sheet, dim/blackout and auto-dim, thermal step-down, onboarding/help, app icon, plugin `.pkg` signing/notarization | End-to-end v1 release candidate |

## v2 (deferred)

- Control the phone from OBS (lens, zoom, exposure from the source properties)
- Wi-Fi fallback with Bonjour discovery
- Camera setting presets
- Kelvin white balance, HDR, Apple Log / color profiles
- Aspect-ratio crop (16:9 / 4:3 / 9:16 / 1:1) and safe-area guides
- Monitor audio (Bluetooth headphones)
- Windows (Apple Mobile Device Support) and Linux (libimobiledevice) plugin builds
