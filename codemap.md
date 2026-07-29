# nodaystypst Code Map

## Architecture

Native Swift 6 / SwiftPM macOS 15+ menu-bar application. `NodaystypstApp` owns the SwiftUI scene shell; `AppServices` is the composition root for the Phase A services. The remaining service files are compile-safe Task 1 stubs and are implemented in later Phase A tasks.

## Entry Points

- `Sources/Nodaystypst/App/NodaystypstApp.swift` — executable `@main`; defines `MenuBarExtra` and `Settings` scenes.
- `Sources/Nodaystypst/App/AppServices.swift` — service composition root.
- `Sources/Nodaystypst/Support/PredictionConstants.swift` — shared debounce, timeout, bounded context, 2–4-word completion, and Gemma 4 defaults.
- `Sources/Nodaystypst/Support/SupportedAppPolicy.swift` — strict Orion/Antinote allowlist used before field-content reads.

## Module Responsibilities

- `Sources/Nodaystypst/Accessibility/` — focused-field observation and secure-field gating.
- `Sources/Nodaystypst/Adapters/` — field context, adapter contract/selection, and native/Chromium/Electron/terminal insertion paths.
- `Sources/Nodaystypst/Overlay/` — non-activating ghost presentation.
- `Sources/Nodaystypst/Predict/` — OpenRouter request/response models and prediction client.
- `Sources/Nodaystypst/Accept/` — next-word Tab acceptance and repeated-Tab remainder handling.
- `Sources/Nodaystypst/Coordinator/` — debounce, cancellation, generation, and one-in-flight orchestration.
- `Sources/Nodaystypst/Settings/` — Keychain, preferences, menu-bar controls, and Settings UI.
- `Sources/Nodaystypst/Personalization/` — encrypted, bounded global/per-app writing statistics and prompt summaries.
- `Tests/NodaystypstTests/` — focused Swift Testing suites.

## Build and Run

- Build: `swift build`
- Test: `swift test`
- Focused constants test: `swift test --filter PredictionConstantsTests`
- Package and launch development app: `Scripts/compile_and_run.sh`
- Package only: `MENU_BAR_APP=1 Scripts/package_app.sh release`
- Regenerate the app icon: `Scripts/build_icon.sh`

## Bundle Configuration

- `Resources/Info.plist` — bundle metadata with `LSUIElement=true`.
- `Resources/AppIcon.png` — source artwork; packaging generates `AppIcon.icns`.
- `Resources/Nodaystypst.entitlements` — outbound network client entitlement only. The direct-distribution build is intentionally non-sandboxed (App Sandbox removed) because cross-app assistive AX reads, observers, and writes are incompatible with sandboxing. Accessibility consent remains required.
- `version.env` — marketing version and build number consumed by packaging.
