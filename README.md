# TypeCam

Turn an iPhone into a low-latency, wired camera for **OBS Studio** on macOS.

TypeCam is two pieces that talk over the USB-C (or Lightning) cable:

| Part | Path | Tech |
|---|---|---|
| iOS camera app | [`ios/`](ios/) | Swift, SwiftUI, AVFoundation, VideoToolbox, Network.framework — iOS 18+ |
| OBS source plugin | [`obs-plugin/`](obs-plugin/) | C / Objective-C++, CMake, libobs, VideoToolbox — macOS, OBS 31+ |

The phone captures and hardware-encodes H.264/HEVC + audio, and serves it on a TCP port. The plugin
reaches that port through Apple's `usbmuxd` USB tunnel — no Wi-Fi, no network setup — then decodes
and feeds frames straight into an OBS source.

## Docs

- [Architecture](docs/ARCHITECTURE.md) — system overview, data flow, key decisions
- [Wire protocol](docs/PROTOCOL.md) — the contract between app and plugin
- [iOS app](docs/IOS_APP.md) — features, settings, UI spec
- [OBS plugin](docs/OBS_PLUGIN.md) — source properties, decoding, build & install
- [Roadmap](docs/ROADMAP.md) — milestones for v1 and what's deferred to v2

## Status

Pre-development. Docs define v1; see the roadmap for the current milestone.
