# iOS App — TypeCam

Target: **iOS 18.0+**, iPhone first (iPad supported, not optimized). SwiftUI, Apple frameworks only.

TypeCam is a **streaming camera, not a camera app**. It has no photo/video/portrait modes, no gallery and
no local recording. It has one job: send the best possible live feed to OBS.

## Screens

### 1. Camera (main)

Design: dark, technical "creator" style, with one **control deck** at the bottom for every adjustment
(Blackmagic Camera / Halide pattern). It replaces the earlier floating rail and panels, which scattered the
controls across the screen.

```
┌──────────────────────────────────────┐
│ TypeCam        1080p · 30 · HEVC  ● 🔋│  ← status bar (dot = waiting / live / paused)
│            [🔒 AE/AF LOCK]            │  ← only while locked; tap to unlock
│                                  ┌──┐│
│        preview (full screen)     │▌▌││  ← L/R meter (long-press = mute)
│   tap = focus · hold = lock      │▌▌││
│   pinch = zoom                   └──┘│
├──────────────────────────────────────┤
│ ZOOM  FOCUS  EXPOSURE   WB   AUDIO   │  ← tabs show live values (1.4× · MF · ISO 400 · LOCK · −6 dB)
│  ▔▔                                  │     tap or swipe to switch; content slides left/right
│ [0.5×][1×][2×][4×]            [Flip] │  ← per-tab chips
│ ┊ ┊ ┊ ┊ ┊ ┊ ┃ ┊ ┊ ┊ ┊ ┊ ┊   1.4×      │  ← ruler dial: drag to scrub, haptic tick per mark
│   ☾            ( ◉ )            ⚙    │  ← dim · stream · settings
└──────────────────────────────────────┘
```

| Deck tab | Chips | Ruler |
|---|---|---|
| Zoom | Lens chips (base zoom of each physical lens, plus a 2× crop of the main lens), Flip | Continuous zoom on a log scale; crossing a lens's base zoom switches to that lens |
| Focus | Auto · Manual · Unlock (while AE/AF-locked) | Lens position, macro ↔ infinity. Dragging it in Auto switches to Manual. |
| Exposure | Auto · ISO *n* · 1/*n* (tapping ISO or shutter switches to Manual and selects that ruler), aperture readout | Auto: EV −2…+2 in 0.1 steps. Manual: ISO or shutter (log scale, shutter capped at one frame). |
| WB | Auto · Lock cards | — |
| Audio | Mute, live level meter | Input gain −12…+24 dB. If audio is off or not permitted, shows why, with a Turn On button. |

Highlighted values (manual, locked, muted, non-zero EV) show in the accent colour in the tab and the chips.
The selected tab is remembered between launches.

| Element | Behaviour |
|---|---|
| Status bar | Resolution · fps · codec. A connection dot shows waiting (pulsing grey), live (red) or paused (amber). Battery and thermal icons appear when the device is `.serious` or worse. |
| Preview | Full-screen aspect-fill, so the edges of the streamed frame may be cropped on screen. Tap to focus/expose (yellow square; drifts back to centre when the scene changes). Long-press locks AE/AF. Manual focus or exposure isn't overridden by taps. Pinch to zoom. |
| L/R meter | Post-DSP segmented peak meter with 1 s hold (yellow from −12, red from −6 dBFS). Long-press to mute. Hidden when audio is off. |
| Stream button | Waiting: grey ring with a pulsing cable glyph, disabled. Live: red. Paused: amber pause glyph. Tap to pause or resume. |
| Lens changes | Each lens is its own physical camera, so manual ISO, shutter and focus work everywhere. A lens change is a brief cut, covered by freezing and blurring the last frame. A camera flip uses a card-turn animation. |

The UI is portrait-locked and counter-rotates the round buttons and meter labels instead of re-laying out.
The stream's orientation follows the device (via `AVCaptureDevice.RotationCoordinator`) unless locked, and is
sent to OBS as rotation metadata (see ARCHITECTURE.md).

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
| Focus | Auto (continuous) · Manual (lens position, set from FOCUS on the camera screen). Shown when the camera supports it. | Auto |
| Exposure | Auto (+ EV bias -2…+2) · Manual (ISO + shutter, clamped to the lens's range; shutter capped at one frame so the frame rate never drops). Switching to manual starts from the current auto values. | Auto |
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

The screen (*Settings › Audio*) has a spectrum display at the top (32 log-spaced FFT bars, green → yellow → red,
computed only while the screen is open) and a segmented level meter with a dBFS scale. Only the toggle shows
when audio is off or mic permission is denied.

| Setting | Options | Default |
|---|---|---|
| Send audio | On / Off (video-only stream; removes the mic from the session) | On |
| Microphone | iPhone Microphone, plus connected Bluetooth / USB-via-hub inputs (`availableInputs`) | iPhone Microphone |
| Mic position | Bottom · Front · Back (built-in mic data sources, when more than one exists) | Bottom |
| Pattern | Omni · Cardioid · Subcardioid · Stereo (what the position supports). Choosing Stereo also switches Channels to Stereo. | Omni |
| Input gain | Digital, -12…+24 dB (applied identically on every input) | 0 dB |
| Mute | On / Off; also a long-press on the camera screen meter. Sends silence, so the OBS track stays alive. | Off |
| Preset | Natural · Voice Boost · Outdoor · Music | Natural |
| Low cut filter | Off · 80 Hz · 120 Hz | Off |
| Format | PCM 16-bit · AAC 128 / 192 / 256 kbps | PCM 16-bit (lowest latency) |
| Sample rate | 44.1 kHz · 48 kHz | 48 kHz |
| Channels | Mono · Stereo (shown when the input or pattern is stereo) | Mono |

Footers explain the limits. Bluetooth mics record at call quality unless high-quality recording is active
(supported AirPods on iOS 26+), and a wired USB-C mic needs a hub.

Presets (DSP chain after gain, before low-cut):

| Preset | Processing |
|---|---|
| Natural | none |
| Voice Boost | high-pass 100 Hz, presence +3 dB @ 3 kHz, compression 3:1 at -18 dB, +4 dB makeup |
| Outdoor | high-pass 150 Hz, low-shelf -4 dB @ 250 Hz, compression 2:1 at -18 dB, +2 dB makeup |
| Music | no EQ, compression 1.5:1 at -12 dB, +1 dB makeup |

The camera screen shows a vertical L/R (or M) peak meter on the right with a 1 s peak hold, and a mic-slash
icon when muted.

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
