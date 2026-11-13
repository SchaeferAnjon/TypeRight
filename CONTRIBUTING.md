# Contributing to TypeRight

TypeRight is an English typing assistant for the Mac menu bar, written in Swift and Rust and based on [TextWarden](https://github.com/PhilipSchmid/textwarden). While you type, it shows a small card next to a misspelled word, a Chinese word, or a finished sentence; Tab takes the fix. Contributions are welcome, especially focused fixes for Accessibility behavior, app compatibility, card placement, and tests.

## Prerequisites

- macOS 26 for the complete Swift test suite
- Xcode 26 or later with Command Line Tools
- Rust 1.95 or later through [rustup](https://rustup.rs/)
- Intel and Apple Silicon Rust targets
- Homebrew
- SwiftFormat and SwiftLint

The shipped app targets macOS 14. macOS 26 and Xcode 26 are required for developing and testing its Apple Foundation Models integration.

Install the command-line dependencies:

```bash
rustup update stable
rustup target add x86_64-apple-darwin aarch64-apple-darwin
brew install swiftformat swiftlint
```

Check the toolchain:

```bash
xcodebuild -version
rustc --version
rustup target list --installed
swiftformat --version
swiftlint --version
```

## Set Up the Project

```bash
git clone https://github.com/SchaeferAnjon/TypeRight.git
cd TypeRight
make build
make test
open TextWarden.xcodeproj
```

`make build` compiles the Rust grammar engine for Intel and Apple Silicon, creates a universal static library, and builds the Swift app (the Xcode project and scheme keep TextWarden's names; the app is `TypeRight.app`). See [BUILD.md](BUILD.md) for individual targets and troubleshooting.

Harper is pinned to a [small security patch on top of 3.0.0](https://github.com/PhilipSchmid/harper/commit/ae6acb45fd6cf10708728bb9e82289dea38154df). It upgrades `zip` to a patched 9.x version, validates archive header consistency, and uses the same Burn inference components directly to remove unused vulnerable backends. Grammar rules and model data are unchanged. Return to an official Harper release once it includes these fixes and no longer resolves `zip` below 9.0.5; rerun the grammar tests, archive security regression, and CPU gate before changing the pin.

## Repository Layout

```text
TypeRight/
├── Sources/                # Swift app
│   ├── TypeRight/          # The cards, the coach, notebooks, membership and TypeRight's own windows
│   ├── Accessibility/      # Focused-element monitoring and AX helpers
│   ├── App/                # Coordination, Foundation Models, updates, lifecycle
│   ├── AppConfiguration/   # Per-app strategies and behavior
│   ├── ContentParsers/     # Text extraction for supported editors
│   ├── Positioning/        # Character-bound and overlay positioning
│   ├── SketchPad/          # Built-in writing editor
│   ├── TextReplacement/    # Validated correction application
│   ├── UI/                 # SwiftUI and AppKit views
│   └── Utilities/          # Shared conversion and readability helpers
├── GrammarEngine/          # Rust library and Harper integration
├── Tests/                  # Swift unit, integration, contract, and performance tests
├── Scripts/                # Build, release, and reset scripts
└── docs/                   # Internal and application-specific documentation
```

Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing module boundaries, dependency flow, app behavior, or Accessibility strategy selection.

## Development Workflow

1. Make one focused change at a time (outside contributors: on a branch of your fork).
2. Keep the commit history readable: one commit per finished change.
3. Run `make run` after a code change so you test the installed app, not a stale build.
4. Test the affected host apps manually when Accessibility behavior changes.
5. Run `make ci-check` before committing. App/runtime and dependency changes also
   require the [local CPU gate](docs/CPU_PROFILING.md#local-regression-gate); use its
   full suite for analysis, AX, timers, overlays, and performance changes.
6. Outside contributors open a pull request targeting `main`; the maintainer commits directly.

Useful commands:

| Command | Purpose |
| --- | --- |
| `make run` | Build, install to `/Applications`, and launch |
| `make test` | Run Rust and selected Swift tests |
| `make ci-check` | Run all formatting, linting, testing, and build gates |
| `make reset-onboarding` | Show onboarding on the next launch |
| `make fmt` | Format Rust and Swift sources |
| `make lint` | Run Clippy and SwiftLint |

For performance investigations, see [CPU profiling](docs/CPU_PROFILING.md): native
counter captures, Instruments flame graphs, and repeatable Mail comparisons.

## Accessibility Permission

TypeRight needs Accessibility permission to inspect and update text in other apps. Enable the exact build you are testing under **System Settings → Privacy & Security → Accessibility**. A build at a different path or with a different signature may need permission again.

## Adding or Fixing App Support

Most app-specific behavior lives in three places:

- `Sources/AppConfiguration/AppRegistry.swift` selects parsers, positioning strategies, replacement methods, and feature flags.
- `Sources/AppConfiguration/AppBehaviorRegistry.swift` registers isolated overlay, timing, scrolling, coordinate, and text-index behavior.
- `Sources/ContentParsers/` handles editors whose exposed text needs app-specific parsing.

Unknown apps are profiled through Accessibility probes and cached in `strategy-profiles.json` in TypeRight's Application Support folder. Profiles expire after seven days. Add explicit support when automatic detection cannot capture an app's quirks or when it needs dedicated parsing, replacement, or positioning.

When adding an app:

1. Find its bundle identifier in **设置 › 高级 › 全部 App**, with `osascript -e 'id of app "AppName"'`, or with `mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app`.
2. Inspect the editor with Xcode's Accessibility Inspector. Check `AXValue`, selection attributes, range bounds, text-marker support, focus behavior, and what changes while typing or scrolling.
3. Add the narrowest configuration or behavior needed. Do not copy another app's quirks without confirming them.
4. Register any new `AppBehavior` and `AppConfiguration` explicitly.
5. Add regression tests under `Tests/Unit/` and an application note under `docs/applications/`.
6. Test typing, scrolling, focus changes, multiple windows, replacement, emoji, rich text, and external displays where relevant.

`AppRegistry` resolves application policy from the exact bundle IDs in [`ApplicationPolicy.defaults`](Sources/AppConfiguration/ApplicationPolicy.swift). Edit that single list to add a default exclusion. Terminal apps remain resumable; ignored utilities cannot be enabled by user overrides. Other unknown apps require safe-trial consent before TextWarden reads their text. `UserPreferences` stores the user's choices.

Before excluding an app, check the [exclusion policy](docs/APPLICATION_EXCLUSIONS.md). Review writing features before excluding an entire app; use a default pause when users should retain the option to enable it. Users can suggest additions in [GitHub Issues](https://github.com/SchaeferAnjon/TypeRight/issues) with the app name and bundle identifier.

## Code Style

### Swift

- Use `Logger`, never `print()`.
- Do not force-unwrap Accessibility values or external data.
- Keep UI state on the main actor and move blocking work off the main thread.
- Check `Sources/Utilities/` before adding text-index, coordinate, or other shared helpers.
- Use named constants from `TimingConstants`, `GeometryConstants`, or `UIConstants` when the value is shared or behavior-defining.

### Rust

- Return `Result<T, E>` from fallible library code.
- Propagate errors instead of panicking across the library or FFI boundary.
- Keep the Swift bridge surface small and validate Swift inputs.
- Run `cargo fmt`, Clippy, and locked tests through `make ci-check`.

Comments should explain why a constraint or workaround exists. Delete dead code instead of commenting it out.

## Logging and Privacy

Writing may contain credentials, private messages, and customer data. Do not put user text in Info, Warning, Error, or Critical logs. Prefer lengths, ranges, identifiers, timing, and result counts.

```swift
// Avoid: exposes user text
Logger.debug("Processing: \(userText)", category: Logger.analysis)

// Prefer: records enough context without the text
Logger.debug("Processing \(userText.count) characters", category: Logger.analysis)
```

Use the existing categories: `general`, `permissions`, `analysis`, `accessibility`, `ffi`, `llm`, `ui`, `performance`, `errors`, `lifecycle`, and `rust`.

Debug and Trace logs may include text for targeted troubleshooting. Keep those cases deliberate and make the privacy consequence visible to the user.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) with one of these types:

`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, or `ci`.

Write an imperative subject with no period:

```text
fix: Keep the card under the word in Slack
```

Commits are not signed and carry no sign-off line:

```bash
git commit -m "fix: Keep the card under the word in Slack"
```

## Pull Requests

TypeRight has one maintainer, who commits directly. Pull requests from others are welcome:

- Keep the pull request focused and describe the user-visible result.
- Link the issue when one exists.
- Include manual test context for app-specific behavior.
- Make sure `make ci-check` passes.

## Bug Reports and Feature Requests

Report defects in [GitHub Issues](https://github.com/SchaeferAnjon/TypeRight/issues). Include the TypeRight version (设置 › 高级 › 关于), macOS version, host app, exact steps, expected behavior, actual behavior, and a diagnostic export when appropriate.

Use [GitHub Discussions](https://github.com/SchaeferAnjon/TypeRight/discussions) for feature requests and questions.

## Releases

Releases are maintainer-only because they need the Developer ID certificate and the Sparkle signing key. They are made with `Scripts/release.sh` on the current branch, without a pull request. The first releases are not notarized; the release notes tell users how to open the app the first time.

```bash
Scripts/release.sh release X.Y.Z
git push origin HEAD:main && git push origin vX.Y.Z
Scripts/release.sh upload X.Y.Z
```

Versions follow Semantic Versioning, including `alpha`, `beta`, and `rc` prerelease identifiers.
