# LayoutLock Agent Instructions

LayoutLock is a macOS menu bar app for saving and restoring window layouts.

## Project

- macOS 14+
- Xcode 26+
- SwiftUI app using the `@main App` lifecycle
- Accessibility permission is required for window capture and restore
- Source lives in `LayoutLock/`
- Tests live in `LayoutLockTests/`

## Related Repositories

- **License Proxy**: `/Users/brkgng/Repo/LayoutLockFiles/layoutlock-license-proxy` — handles entitlement validation. Modify when features span the app and licensing backend.
- **Website**: `/Users/brkgng/Repo/LayoutLockFiles/Website` — marketing site, download links, support. Modify when features require website changes.

## Important Modules

- `App/` — `@main` entry point, app shell, scenes, and menu commands
- `Snapshots/` stores snapshot models, capture orchestration, and JSON persistence
- `WindowDiscovery/` reads application/window metadata via Accessibility + `CGWindowList`
- `Restore/` restores saved layouts (relaunches apps, matches windows, applies geometry and z-order)
- `Displays/` handles display-relative normalized positioning and change-driven restore suggestions
- `Hotkeys/` handles per-layout global restore shortcuts (Carbon `EventHotKey`)
- `BrowserAutomation/` captures and restores Safari/Chrome tabs via AppleScript
- `Integrations/` handles external capture/restore commands and exports the layout index
- `Permissions/` handles Accessibility authorization and re-prompting
- `Onboarding/` contains the first-run onboarding flow
- `Monetization/` handles Free/Pro entitlements, Creem checkout, and license-proxy receipt validation
- `Dashboard/` contains the main dashboard SwiftUI UI and layout preview
- `MenuBar/` contains menu bar interactions and capture/restore orchestration
- `Settings/` contains the five-tab settings UI (General, Integrations, Pro, Diagnostics, About)
- `Updates/` contains the Sparkle-backed update controller and native update window
- `LaunchAtLogin/` wraps `SMAppService.mainApp`
- `Infrastructure/` contains logging, telemetry, overlays, and app support setup
- `Shared/` contains value extensions, settings keys, and Codable geometry helpers
- `Assets.xcassets/` is the asset catalog

## Code Conventions

- Use `AppLogger` for production logging, not `print()`
- Keep shared helper extensions in `LayoutLock/Shared/ValueExtensions.swift`
- Prefer small, focused changes that follow existing patterns
- Prefer shared restore fixes that work across applications; use app-specific handling only when evidence requires it
- Add or update XCTest coverage for behavior changes
- Do not introduce backward compatibility unless persisted data, shipped behavior, or user requirements require it

## Verification

Run the fast hygiene check after small edits:

```
Scripts/lint.sh
```

This checks:

- no production `print()` calls

For behavior changes, run the smallest relevant existing XCTest first. For example:

```sh
xcodebuild test \
  -project LayoutLock.xcodeproj -scheme LayoutLock -destination 'platform=macOS' \
  -only-testing:LayoutLockTests/ExternalCommandIntegrationTests/testParsesRestoreAndCaptureCommands
```

Replace the test filter with the relevant target/class/method and confirm that tests actually ran. Lint does not replace behavior tests.
