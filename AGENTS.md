# Working on Duo Reader

Notes for anyone, human or agent, making changes in this repository. The
conventions follow Phase (`FrTime/phase-ios`).

## Track every piece of work as a GitHub issue

All work is tracked as an issue in
[FrTime/duo-reading-app](https://github.com/FrTime/duo-reading-app/issues) and
shows up on the "Duo Reading App" project board automatically.

- **New work gets an issue first**, before any code.
- **Changes ship through pull requests** with `Closes #N` in the description.
- Don't push straight to `main`.
- The roadmap is [#1](https://github.com/FrTime/duo-reading-app/issues/1).
  Epics are labelled `epic`, features `mvp` or `later`, areas `area: …`,
  investigations `spike`.
- Work is grouped into milestones M0 to M5. Each milestone from M1 on ends with
  a **polish and bug-hunt pass** (label `polish`) before the next one starts.

## Review every PR through several lenses

Each PR is reviewed once per lens, with comments on the PR and follow-up commits
that address them (or an issue for anything out of scope):

1. Architecture and code quality
2. iOS UX and accessibility
3. iPhone Duo layouts
4. Performance
5. Privacy and security
6. Tests

The PR template has the checklist.

## Follow Conventional Commits

Commits, PR titles and branch names follow
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):
`feat(reader): add page-turn animations`, branch `feat/page-turn-animations`.
Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `build`, `ci`,
`perf`, `style`.

## Decisions that hold across the app

- **Production app, App Store-bound.** Every feature ships with tests,
  accessibility and empty/error states.
- **Data stays on the device.** No third-party analytics or SDKs. The only
  network calls are cover searches the user starts.
- **No DRM removal**, and no copyrighted books or images in the repo or bundle.
- **Out of scope:** focus mode, app blocking, AI features.
- **Lay out from size classes and the fold region**, never from orientation or
  device idiom (Apple's Duo guidance).

## Building

Xcode-only: SwiftUI, SwiftData, Swift 6 with complete concurrency checking.
Deployment target iOS 27.1.

**Use Xcode 27.1.0 or later.** An older Xcode without the Duo SDK may also be
installed, so select the right one explicitly:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer
xcodebuild test -project DuoReader.xcodeproj -scheme DuoReader \
  -destination 'platform=iOS Simulator,name=iPhone Duo'
```

- `DuoReaderCore/` holds models and logic with no UI; `DuoReader/` holds the
  app. Both compile into the app target (file-system synchronized groups).
- Tests use Swift Testing in `DuoReaderTests`.
- The SwiftData schema is versioned in
  `DuoReaderCore/Models/DuoReaderSchema.swift`. Changing a model means adding a
  schema version and a migration stage, never editing a shipped version.
  Until the first TestFlight build nothing has shipped, so `DuoReaderSchemaV1`
  is still edited in place; delete the app from the simulator if an old
  development store won't open. From the first TestFlight build on, every
  model change gets a new schema version and migration stage.
- **Every PR is built and tested on Tim's Mac** with the command above, and the
  result is posted on the PR. GitHub Actions CI (`.github/workflows/ci.yml`) is
  manual-only until Actions billing is sorted and runners have Xcode 27.1.
- Put test books in `TestBooks/` (git-ignored). Never commit real ebooks.

### Testing Duo poses without touching the Mac

Nothing on the command line can move the Duo's hinge (`simctl` and `devicectl`
don't), and Xcode 27.1 has no Simulator.app. Only Device Hub
(`Xcode-27.1.0.app/Contents/Applications/DeviceHub.app`) has the hinge slider.
The fold position **persists per simulator across reboots**, so there's one
simulator per pose, set once by hand:

| Simulator | Pose | One-time setup |
| --- | --- | --- |
| `iPhone Duo (closed)` | folded, app on the outer screen | none (new Duos start closed) |
| `iPhone Duo (open)` | fully open, app on the inner screen | Device Hub: drag the hinge slider to fully open |
| `iPhone Duo (half open)` | partially open, book / tabletop | Device Hub: drag the hinge slider to about 90° |
| `iPhone Duo` | whatever the last person left it in | shared; don't rely on its pose |

Pick one by name: `-destination 'platform=iOS Simulator,name=iPhone Duo (open)'`.
If a pose sim gets moved, reset it in Device Hub. Recreate a missing one with
`xcrun simctl create "iPhone Duo (open)" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1`.

- **Orientation is scriptable:**
  `xcrun devicectl device orientation set --device "<udid>" landscapeLeft`
  (`portrait`, `portraitUpsideDown`, `landscapeLeft`, `landscapeRight`).
- **Screens:** the outer panel is 466×678 pt and the inner 669×951 pt (@3x).
  Screenshot either one: `xcrun simctl io <udid> screenshot --display=1 out.png`
  (outer) or `--display=3` (inner). The images come out in the panel's native
  rotation, so rotate them before judging the layout.
- **Input:** while Device Hub has a simulator open, synthesized taps and swipes
  may not reach it. Prefer launch arguments and logs for automated checks.
- **Camera:** the simulator has no camera, and it presents
  `CameraCaptureAccessory` content without a capture session. Hardware does
  not, so anything that depends on the camera must be checked on a real Duo
  (see `docs/spikes/outer-screen-cover.md`).
