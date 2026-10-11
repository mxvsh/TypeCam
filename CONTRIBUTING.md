# Contributing to TypeCam

Thanks for your interest in TypeCam! Bug reports, device testing and pull requests are all welcome. This guide
explains how the project is laid out, how to build it and what we look for in a change.

## Ways to help

- **Report a bug.** Open an issue with your iPhone model and iOS version, Mac model and macOS version, OBS
  version, the TypeCam settings you used (resolution, fps, codec, audio format) and what you saw. The plugin's
  **Status** line and the OBS log (*Help → Log Files*) are very useful.
- **Test on your hardware.** Latency numbers and results from different iPhones, Macs and cables help a lot,
  especially for two-phone setups, 1080p60 and 4K.
- **Suggest a feature.** Check the [roadmap](docs/ROADMAP.md) first, then open an issue to discuss it before
  writing code.
- **Send a pull request.** For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Before you start

Read these before touching transport, encoding or the plugin:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system overview, data flow and key decisions
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — the wire contract between app and plugin
- [docs/IOS_APP.md](docs/IOS_APP.md) and [docs/OBS_PLUGIN.md](docs/OBS_PLUGIN.md) — specs for each side

## Development setup

You need a Mac, an iPhone on iOS 18+, the latest Xcode, CMake 3.28+ and OBS Studio 31+.

### iOS app

Signing lives in `ios/Config/`, not in the project file. Create your personal, git-ignored config once:

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
# set DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX in it
open ios/TypeCam.xcodeproj
```

Please don't set the team in Xcode's **Signing & Capabilities** tab: that writes your team ID into
`project.pbxproj`. Run on a real device; the camera, encoder and USB transport don't work in the Simulator.

Compile check from the command line:

```sh
xcodebuild -project ios/TypeCam.xcodeproj -scheme TypeCam -destination 'generic/platform=iOS' build
```

### OBS plugin

```sh
cd obs-plugin
cmake --preset macos          # first run downloads OBS sources and obs-deps (several minutes)
cmake --build --preset macos
```

Install for testing (quit OBS first):

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-typecam.plugin
cp -R build_macos/RelWithDebInfo/obs-typecam.plugin \
  ~/Library/Application\ Support/obs-studio/plugins/
```

If the first build after editing `CMakeLists.txt` fails at link time, run it again: the Xcode project was being
regenerated.

## Releasing the iOS app

`scripts/release.sh` builds a signed App Store IPA. It asks whether the release is a patch, minor or major
update (or `keep` to re-upload the same version), then bumps `ios/Config/Version.xcconfig` and archives.
It exports the IPA to `build/release/`, and finally offers to commit the bump and tag it `ios/vX.Y.Z`.

```sh
scripts/release.sh                 # interactive
scripts/release.sh patch           # no prompt
scripts/release.sh minor --upload  # upload straight to App Store Connect instead of exporting
```

Upload the IPA with Transporter, or use `--upload`. You need your team set in `Local.xcconfig` (or
`DEVELOPMENT_TEAM=… scripts/release.sh`). Xcode must be signed in under **Xcode › Settings › Accounts** with an
account that has the Admin or Account Holder role, so it can create the distribution certificate and App Store
profile. Alternatively, set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` to sign with an App Store Connect
API key.
The short git commit is embedded in the app and shown in **Settings › About** (with `-dirty` if you used
`--allow-dirty`). If the build fails, the version file is restored. Don't edit the version in Xcode's **General** tab: that writes
it into `project.pbxproj`, where it overrides `Version.xcconfig`.

The script isn't tied to TypeCam. Set `PROJECT`, `SCHEME`, `VERSION_FILE` and `TAG_PREFIX` to use it with
another Xcode project. See the header of the script for details.

## Project rules

These keep TypeCam small, fast and predictable. Pull requests that break them will be asked to change.

### Scope

- **TypeCam is a streaming camera only.** No photo, video or portrait modes, no gallery and no local recording.
- **Latency beats quality.** No B-frames, real-time encoding, and drop frames instead of queueing them.
- **Overlays are preview-only.** Zebra, peaking, histogram, grid and level are never burned into the stream.

### The protocol is a contract

Any change to the wire format must update all three of these **in the same commit**:

1. `docs/PROTOCOL.md`
2. `ios/TypeCam/Transport/` (`Wire.swift` and friends)
3. `obs-plugin/src/protocol.h` (and the code that uses it)

Additive changes (a new message type the other side can ignore) don't need a version bump. Anything that isn't
backward-compatible must bump `protocol_version`.

### iOS

- Swift and SwiftUI, **Apple frameworks only** — no third-party packages.
- Minimum target is **iOS 18**. Gate newer APIs with `#available`.
- The project defaults to `MainActor` isolation. Capture, audio, encode and network work must run **off the
  main actor**, on dedicated queues or `nonisolated` types. Only UI state belongs on the main actor.
- Settings the current device can't do are hidden, never shown disabled.

### OBS plugin

- Plain C against libobs, macOS only for v1.
- Format with `clang-format` 16 or later using `obs-plugin/.clang-format`, and format CMake files with `gersemi`.
- Never block the OBS graphics or audio threads. Network and decode work stays on the source's connection thread.

## Commits and pull requests

- Keep each pull request focused on one change, and keep commits small and self-explanatory.
- Write commit messages in the imperative mood, for example `Fix reconnect after phone lock`. Work that lands a
  roadmap milestone uses the milestone prefix, for example `M7: thermal step-down`.
- When a change finishes or moves a milestone, update its status in [docs/ROADMAP.md](docs/ROADMAP.md).
- If you change behaviour that's described in `docs/`, update the docs in the same pull request.
- Don't commit build output, `xcuserdata/`, `Local.xcconfig` or a `DEVELOPMENT_TEAM` in `project.pbxproj`.

### Pull request checklist

- [ ] The iOS app builds (`xcodebuild … build`) and the plugin builds (`cmake --build --preset macos`)
- [ ] Tested on a real iPhone streaming into OBS
- [ ] Protocol changes update `PROTOCOL.md`, the app and the plugin together
- [ ] Docs and roadmap are updated where relevant
- [ ] The description explains **what** changed, **why**, and **how you tested it** (devices, OS and OBS versions)

## Reporting security issues

Please don't open a public issue for a security problem. Contact the maintainer privately through
[monawwar.com/contact](https://monawwar.com/contact) instead.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Code of conduct

Be kind and constructive. Assume good intent, keep discussion focused on the work, and help newcomers find
their way around.
