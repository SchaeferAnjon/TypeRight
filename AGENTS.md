# TextWarden Development Guidelines

## Architecture

**See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed architecture documentation, design patterns, dependency injection, and coding principles.** Always consult ARCHITECTURE.md when making structural changes or adding new components.

- **Swift**: macOS app with SwiftUI, menu bar interface, Accessibility API integration
- **Rust**: GrammarEngine library via FFI (swift-bridge), handles grammar analysis via Harper
- **Apple Intelligence**: Style suggestions via Foundation Models framework (macOS 26+)
- **Build**: `make build` (Rust first, then Xcode)

## Swift Guidelines

### Logging
Use `Logger` (os.log-based), never `print()`:
```swift
Logger.info("Message", category: Logger.permissions)
Logger.debug("Details", category: Logger.ui)
Logger.error("Failed", category: Logger.analysis)
```

Categories: `general`, `permissions`, `analysis`, `accessibility`, `ffi`, `llm`, `ui`, `performance`, `errors`, `lifecycle`, `rust`
Levels: `trace` (high-frequency) → `debug` → `info` → `warning` → `error` → `critical`

### Safety & Error Handling
- No force unwraps (`!`) on AXValue or external data
- Use `guard let` / `if let` for optionals
- Handle all error cases explicitly

**Error Handling Patterns:**
```swift
// Array access - use .first, .last, or indices.contains()
guard let first = array.first else { return }
guard array.indices.contains(index) else { return }

// String indices - use limitedBy: parameter
guard let endIdx = str.index(str.startIndex, offsetBy: offset, limitedBy: str.endIndex) else { return }

// AXValue types - use safe helper functions (AccessibilityBridge)
guard let frame = AccessibilityBridge.getElementFrame(element) else { return }

// Optional chaining for nullable properties
element?.attribute(forKey: key)
```

**Logging Errors:**
- Log at appropriate level before returning nil/early
- Include context: what failed and any relevant identifiers
```swift
Logger.warning("Failed to get bounds for element: \(elementRole)", category: Logger.accessibility)
```

### Thread Safety
- UI updates on main thread: `DispatchQueue.main.async`
- Never block main thread with sync operations
- Use `@MainActor` for SwiftUI state

## Rust Guidelines

### Error Handling
- Use `Result<T, E>` for fallible operations
- Propagate errors with `?`, don't panic in library code
- Log errors before returning them

### FFI
- Keep FFI boundary minimal and simple
- Use `swift_bridge` types for cross-language communication
- Validate all inputs from Swift side

## Code Quality

- Comments should explain "why", not "what"
- Remove dead code, don't comment it out
- Keep functions focused and small
- Prefer editing existing files over creating new ones
- **Check `Sources/Utilities/` before implementing common operations** (TextIndexConverter, CoordinateMapper, etc.)
- Avoid compatibility shims unless a current file format, user setting, or supported workflow needs one

## Design

- Follow macOS 26 (Tahoe) design principles from Apple
- Use native SwiftUI components where possible
- Respect system appearance and accessibility settings

## Git Workflow

TypeRight has one maintainer: there are no pull requests and no protected branch. Work on the current branch; the public repository's `main` is pushed from it.

### Commit Rules

- Only commit after user validates and explicitly requests it
- **Always run `make ci-check` and fix all findings before committing**
- For app/runtime or dependency changes, also run the local CPU smoke gate before committing; see [CPU profiling](docs/CPU_PROFILING.md#local-regression-gate). Use the full suite for analysis, AX, timers, overlays, or performance changes. Docs-only changes are exempt. Record the baseline/candidate revisions and results; missing permissions, stale state, or noisy measurements are inconclusive, not passes. Never replace a baseline just to make the gate pass.
- Commits are not signed and carry no sign-off line: `git commit -m "<type>: <description>"`

### Conventional Commits (MANDATORY)

**Always use conventional commit format.** See [CONTRIBUTING.md](CONTRIBUTING.md#commit-messages) for full guidelines.

Format: `<type>: <description>` where type is one of:
- `feat` | `fix` | `docs` | `refactor` | `perf` | `test` | `chore` | `ci`

Examples:
- `feat: Add Microsoft Outlook support`
- `fix: Correct underline positioning in Slack`
- `docs: Update README with new app support`

## Testing

```bash
make run            # Build AND restart the app - use after EVERY code change for testing!
make test           # Run tests
make ci-check       # Run CI checks - ONLY before committing, not after every change
```

**Workflow**: Make code changes → `make run` → test manually → repeat. Only run `make ci-check` when ready to commit.

## Releasing

Releases are made with `Scripts/release.sh` (the `make release*` targets call it). It builds, signs with Developer ID, makes the DMG, notarizes only when the `TypeRight` notarytool keychain profile exists (the first releases are not notarized, like GetNewWord and Ask Free, and the release notes say how to open the app the first time), signs the update for Sparkle, updates `appcast.xml` and the build number, commits `chore: release vX.Y.Z` and tags `vX.Y.Z`:

```bash
Scripts/release.sh release X.Y.Z            # or X.Y.Z-alpha.N / -beta.N / -rc.N
git push origin HEAD:main && git push origin vX.Y.Z
Scripts/release.sh upload X.Y.Z             # GitHub release with the DMG and appcast.xml
```

Release notes list the commits since the last `v*` tag; the first release, which has no tag before it, gets a fixed text instead of TextWarden's history. `Scripts/release.sh notes` prints them without building.

Version format follows semver with pre-release suffixes:
- `0.1.0-alpha.1` → Early testing, expect breaking changes
- `0.1.0-beta.1` → Feature complete, bug fixes only
- `0.1.0-rc.1` → Release candidate, final testing
- `0.1.0` → Stable production release
