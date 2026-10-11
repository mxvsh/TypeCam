# TypeCam — working notes

iPhone → OBS wired camera. The iOS app is in `ios/`, the macOS OBS plugin in `obs-plugin/` and the specs in `docs/`.
Read `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` before touching transport, encode or the plugin.

## Rules

- **Protocol is a contract.** Any wire change updates `docs/PROTOCOL.md`, `ios/.../Transport` and
  `obs-plugin/src/protocol.h` in the same commit.
- **Commit per phase/milestone** (see `docs/ROADMAP.md`). Update the roadmap's status when a milestone lands.
- **No photo/video/portrait modes, gallery or local recording.** TypeCam is a streaming camera only.
- iOS: Swift + SwiftUI, Apple frameworks only, iOS 18 minimum (gate newer APIs with `#available`).
- The project defaults to `MainActor` isolation. Capture, audio, encode and network work must stay off the main actor.
- Overlays (zebra, peaking, histogram, grid) are preview-only and never burned into the stream.
- Favour latency over quality: no B-frames, real-time encoding, drop frames instead of queueing.

## Build

```sh
# iOS (compile check)
xcodebuild -project ios/TypeCam.xcodeproj -scheme TypeCam -destination 'generic/platform=iOS' build

# OBS plugin
cd obs-plugin && cmake --preset macos && cmake --build --preset macos

# App Store IPA (bumps ios/Config/Version.xcconfig, archives, exports to build/release/)
scripts/release.sh
```

Version and build number live in `ios/Config/Version.xcconfig`, signing in `ios/Config/App.xcconfig` +
git-ignored `Local.xcconfig`. Never write `DEVELOPMENT_TEAM`, `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION`
into `project.pbxproj`.
