# nodaystypst Code Map

## Architecture

Native Swift 6 / SwiftPM macOS 15+ desktop application. `NodaystypstApp` owns the thin SwiftUI scene/command shell and lifecycle delegate; `AppSettingsWindowController` owns the lightweight AppKit Settings window. `AppServices` is the composition root for capture, prediction, overlay, insertion, settings, and personalization.

## Entry Points

- `Sources/Nodaystypst/App/NodaystypstApp.swift` — executable `@main`; opens and reopens the desktop Settings window, keeps prediction alive after close, and enables optional QA diagnostics.
- `Sources/Nodaystypst/Settings/DesktopSettingsViewController.swift` — native Settings controls for prediction, Keychain, encrypted learning/reset, compatibility, Accessibility, and optional diagnostics.
- `Sources/Nodaystypst/App/AppServices.swift` — service composition root.
- `Sources/Nodaystypst/Support/PredictionConstants.swift` — shared debounce, timeout, bounded context, 2–4-word completion, and Gemma 4 defaults.
- `Sources/Nodaystypst/Support/SupportedAppPolicy.swift` — verified ten-app matrix plus editable-role and browser-chrome metadata gate used before field-content reads.

## Module Responsibilities

- `Sources/Nodaystypst/Accessibility/` — focused-field observation and secure-field gating.
- `Sources/Nodaystypst/Adapters/` — field context, adapter contract/selection, and native/Chromium/Electron/terminal insertion paths.
- `Sources/Nodaystypst/Overlay/` — non-activating ghost presentation.
- `Sources/Nodaystypst/Predict/` — OpenRouter request/response models and prediction client.
- `Sources/Nodaystypst/Accept/` — one-Tab bounded-completion acceptance, live AX revalidation, verified atomic ChatGPT insertion, and adapter pass-through policy.
- `Sources/Nodaystypst/Coordinator/` — debounce, cancellation, generation, and one-in-flight orchestration.
- `Sources/Nodaystypst/Settings/` — Keychain, preferences, prediction/learning controls, and Settings UI.
- `Sources/Nodaystypst/Personalization/` — encrypted, bounded global/per-app writing statistics and prompt summaries.
- `Tests/NodaystypstTests/` — focused Swift Testing suites.

## Build and Run

- Build: `swift build`
- Test: `swift test`
- Focused constants test: `swift test --filter PredictionConstantsTests`
- Package and launch development app: `Scripts/compile_and_run.sh`
- Package only: `Scripts/package_app.sh release`
- Launch attachable QA Settings: `open -na /Applications/Nodaystypst.app --args --qa-settings`
- Launch the completion service without opening Settings: `open -na /Applications/Nodaystypst.app --args --background`
- Regenerate the app icon: `Scripts/build_icon.sh`

## Bundle Configuration

- `Resources/Info.plist` — bundle metadata; packaging sets `LSUIElement=false` for the normal Dock app.
- `Resources/AppIcon.png` — source artwork; packaging generates `AppIcon.icns`.
- `Resources/Nodaystypst.entitlements` — outbound network client entitlement only. The direct-distribution build is intentionally non-sandboxed (App Sandbox removed) because cross-app assistive AX reads, observers, and writes are incompatible with sandboxing. Accessibility consent remains required.
- `version.env` — marketing version and build number consumed by packaging.
