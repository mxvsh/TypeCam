# iOS App — TypeCam

Target: **iOS 18.0+**, iPhone first (iPad supported, not optimized). SwiftUI, Apple frameworks only.

TypeCam is a **streaming camera, not a camera app**. It has no photo/video/portrait modes, no gallery and
no local recording. It has one job: send the best possible live feed to OBS.

## Screens

### 1. Camera (main)

Design: dark, technical "creator" style. The layout follows design reference #2 and the polish follows
reference #1 (grouped inset cards, blue accent, green→yellow→red meters).

```
┌──────────────────────────────────────┐
│ TypeCam        4K · 60 · HEVC   ●  🔋│  ← status strip
│ ┌─────┐                        ┌──┐  │
│ │FOCUS│                        │▌▌│  │  ← L/R audio meter (peak + hold)
│ │ AE  │        preview         │▌▌│  │
│ │ WB  │     (+ grid/zebra/     │LR│  │
│ │ ISO │      peaking/level)    └──┘  │
│ └─────┘  [histogram]                 │  ← left quick rail
│         ( 0.5 )( 1x )( 2 )( 3 )      │  ← lens pills (available lenses only)
│  1/120    f1.8    ISO 100    AWB 🔒   │  ← live exposure readout
│  [ ☾ ]        (  ◉ LIVE  )      [⚙]  │  ← dim · stream-state · settings
└──────────────────────────────────────┘
```

| Element | Behaviour |
|---|---|
| Status strip | Resolution · fps · codec. A connection dot shows waiting (pulsing grey), live (red) or paused (amber). Battery and thermal icons appear when the device is `.serious` or worse. Tap the dot for a telemetry sheet. |
| Left quick rail | **FOCUS** (Auto/Manual, opens a focus slider), **AE** (Auto/Manual, opens an EV bias or ISO/shutter dial), **WB** (Auto/Lock), **ISO** (current value, tap for the manual ISO dial). Active manual controls are highlighted in the accent colour. |
| Preview | Full-screen aspect-fill, so the edges of the streamed frame may be cropped on screen. Tap to focus/expose at a point. Long-press for AE/AF lock (shows an "AE/AF LOCK" badge). Pinch to zoom. |
| L/R meter | Post-gain, post-DSP peak meter with peak hold, -60…0 dBFS. Mono input shows one bar. Red when clipping. |
| Histogram | Small luma histogram when enabled in Overlays. |
| Lens pills | Built from the device's available lenses (0.5 / 1x / 2 / 3 / 5 etc.). Tap to switch, drag horizontally for a smooth zoom ramp. A flip button for the front camera sits at the pill row's end. Flipping freezes and blurs the last frame and turns the preview like a card, and the new camera appears edge-on. |
| Exposure readout | Live shutter, aperture (fixed per lens), ISO and WB mode. |
| Stream-state button | Big centre button. **Waiting**: grey ring, disabled. **Live**: red filled ring, tap to pause. **Paused**: amber ring, tap to resume. While paused, preview continues but no media is sent. |
| Dim button | Enters dim mode: the screen goes black with a tiny status line and the idle timer stays disabled. Tap anywhere to wake. |
| Settings | Opens the settings sheet. |

The UI is portrait-locked and counter-rotates its controls instead of re-laying them out, like the system
Camera app. The stream's orientation follows the device (via `AVCaptureDevice.RotationCoordinator`) unless
it is locked, and is sent to OBS as rotation metadata (see ARCHITECTURE.md).

### 2. Settings

A navigation stack of grouped inset lists. Multiple-choice settings show their current value and push a
checkmark list where each option has its full name and an optional subtitle (for example *4K · 3840 × 2160*).
Toggles and sliders are inline. Values the current device or format can't do are hidden, never shown
disabled-with-error.

#### Video

| Setting | Options | Default |
|---|---|---|
| Resolution | 720p · 1080p · 4K | 1080p |
| Frame rate | 24 · 25 · 30 · 60 (filtered by the active format) | 30 |
| Codec | H.264 · HEVC | HEVC |
| Bitrate | Auto · Manual (2–100 Mbps slider) | Auto (table below) |
| Keyframe interval | 0.5 s · 1 s · 2 s | 1 s |
| Orientation | Auto · Landscape lock · Portrait lock | Landscape lock |
| Mirror front camera | On / Off (applies to the stream too) | Off |

Auto bitrate (HEVC; H.264 = ×1.5): 720p30 4 · 720p60 6 · 1080p30 8 · 1080p60 12 · 4K30 25 · 4K60 40 Mbps.

#### Lens & Image

| Setting | Options | Default |
|---|---|---|
| Lens | available lens pills | 1x |
| Stabilization | Off · Standard (Cinematic is excluded because it adds latency) | Off |
| Focus mode | Auto (continuous) · Manual (lens position slider) | Auto |
| Exposure mode | Auto (+ EV bias -2…+2) · Manual (ISO + shutter) | Auto |
| White balance | Auto · Locked | Auto |
| Torch | Off · On (+ level) (rear lenses only) | Off |

#### Overlays (preview only, never in the stream)

| Setting | Options | Default |
|---|---|---|
| Grid | Off · Rule of thirds | Off |
| Histogram | Off · Luma | Off |
| Zebra stripes | Off · 70% · 80% · 90% · 100% | Off |
| Focus peaking | Off · Red · Green · Blue · White | Off |
| Level | Off · On (horizon line, snaps green at 0°) | Off |

#### Audio

The screen has a spectrum visualizer at the top (FFT bars, green→yellow→red) and a level meter with a dBFS scale.

| Setting | Options | Default |
|---|---|---|
| Send audio | On / Off (video-only stream) | On |
| Microphone input | Dropdown: Built-in, plus connected Bluetooth / wired (via hub) inputs | Built-in |
| Built-in mic position | Bottom · Front · Back (from `AVAudioSessionDataSourceDescription`) | Bottom |
| Polar pattern | Omni · Cardioid · Subcardioid · Stereo (where the data source supports it) | Omni |
| Input gain | Slider: hardware gain when `isInputGainSettable`, otherwise digital -12…+24 dB | 0 dB |
| Mute | On / Off (also on the camera screen via long-press on the meter) | Off |
| Low cut filter | Off · 80 Hz · 120 Hz | Off |
| Preset | Natural · Voice Boost · Outdoor · Music | Natural |
| Format | AAC (128 / 192 / 256 kbps) · PCM 16-bit | AAC 192 |
| Sample rate | 44.1 kHz · 48 kHz | 48 kHz |
| Channels | Mono · Stereo (Stereo only with a stereo pattern or a stereo device) | Mono |

Presets (DSP chain after gain, before low-cut):

| Preset | Processing |
|---|---|
| Natural | none |
| Voice Boost | high-pass 100 Hz, presence +3 dB @ 3 kHz, light compression 3:1, makeup gain |
| Outdoor | high-pass 150 Hz, gentle low-shelf -4 dB @ 250 Hz, compression 2:1 (wind/rumble) |
| Music | flat EQ, very light compression 1.5:1, no high-pass |

#### Display & Power

| Setting | Options | Default |
|---|---|---|
| Auto-dim while live | Off · 30 s · 1 min · 5 min | 1 min |
| Dim style | Blackout · Dim preview (lowest brightness) | Blackout |
| Show telemetry on camera screen | On / Off | Off |

#### About / Connection

**Name in OBS** (editable; defaults to the system name, which iOS reports only as "iPhone"), port 7878 (read-only), protocol version, app version, connection help
("Connect with a USB cable, tap *Trust* on the phone, add a *TypeCam* source in OBS").

## Telemetry sheet

Shows phone-side fps, bitrate, dropped frames, thermal state, battery and charging. Shows host-side
(`HOST_STATS`) decoded fps, dropped frames, estimated latency and OBS version.

## Persistence

`SettingsStore` holds one `Codable` `CaptureSettings` struct saved to `UserDefaults` as JSON (key
`settings.v1`). On launch and on lens/format change, settings are **clamped** to what the active device
supports. The clamping does not overwrite the user's stored preference, so it applies again when
switching back.

## Permissions (Info.plist)

- `NSCameraUsageDescription`: "TypeCam streams your camera to OBS on your Mac."
- `NSMicrophoneUsageDescription`: "TypeCam streams your microphone audio to OBS on your Mac."
- `NSLocalNetworkUsageDescription`: only if M2 shows it is needed (see ARCHITECTURE.md).

## Out of scope for v1

Photo/video/portrait modes, local recording, gallery, Kelvin WB, HDR, Apple Log/color profiles, aspect ratio
crop and safe-area guides, monitor audio, presets for camera settings, control from OBS, Wi-Fi streaming.
