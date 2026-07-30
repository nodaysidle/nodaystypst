# Architecture Requirements Document — nodaystypst

## System Overview
nodaystypst is a native macOS desktop app (Swift 6 + SwiftUI) that observes verified editable AX fields across native, browser, and Electron hosts, requests short completions from OpenRouter, and paints a non-activating ghost overlay at the caret. One Tab accepts the shown 2–4-word completion in writing apps; Ghostty keeps Tab for shell completion. Unknown bundles and unsafe controls remain content-blind and inactive. Encrypted, bounded global and per-app writing statistics shape later prompts. There is no local LLM: RAM stays low because no model weights are loaded.

## Architecture Style
Modular service architecture with thin SwiftUI shell:
- **Capture / gate** — AccessibilityObserver + SecureFieldGate
- **Predict** — PredictClient (OpenRouter)
- **Present** — GhostOverlay (non-activating NSWindow / panel)
- **Commit** — AcceptInsert + FieldAdapters (native, terminal, and evidence-required app-specific paths)
- **Config** — Settings + Keychain
- **Personalize** — WritingStyleStore (encrypted aggregate statistics; no raw history)

Approach **1**: Accessibility + non-activating ghost overlay + adapter-based Tab insert. Not IMK. Not key-tap-only.

## Injection Approach (locked)

| Approach | Decision |
| --- | --- |
| **1 — Accessibility + ghost overlay + adapter Tab insert** | **Chosen** |
| IMK / custom input method | Rejected for Phase A — heavy install UX, focus fights, hard to keep ghost aligned |
| Global key event tap alone | Rejected as primary path — weak field semantics, poor secure-field gating, no reliable caret geometry |

Why Approach 1:
- Reads real focused UI element roles and values
- Can refuse secure fields cleanly
- Overlay can be hidden when geometry is untrusted
- Insert strategy can vary per app without changing the predict loop

## Module Map

```text
┌─────────────────────────────────────────────────────────────┐
│ Desktop Settings (AppKit)  ·  Keychain (API key)            │
└─────────────┬───────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────┐
│ CompletionCoordinator (debounce · cancel · one-in-flight)   │
└─┬──────────┬──────────┬──────────┬──────────┬───────────────┘
  │          │          │          │          │
  ▼          ▼          ▼          ▼          ▼
Accessibility  SecureField  PredictClient  GhostOverlay  AcceptInsert
Observer       Gate         (OpenRouter)   (non-activ.)  + FieldAdapters
```

### AccessibilityObserver
- Watches focused UI element, value / selected text changes, caret-related AX attributes when present
- Emits short context snippets only (bounded window — see TRD)
- Signals focus / app changes so adapters can switch
- Uses a content-blind key wake-up only for Orion and Antinote's proven missing-notification paths; AX remains the sole content source

### SecureFieldGate
- Blocks password fields, secure text fields, and known secure AX traits / roles
- When blocked: no network call, no ghost, no Tab intercept for accept

### FieldAdapters
- Protocol: read context, resolve caret screen rect (or fail), insert accepted text, optionally claim Tab
- **NativeAdapter** — selected for Orion, Antinote, Bear, TextEdit, Notes, and Safari web-content fields
- **TerminalAdapter** — selected for Ghostty (`com.mitchellh.ghostty`); reads only the trailing line, trusts geometry inside the terminal bounds, and **never** claims Tab so shell completion keeps working. Hosts such as Opencode's TUI inherit this behaviour when run inside Ghostty.
- **CodexAdapter** — selected for ChatGPT (`com.openai.codex`); field-anchored banner, verified atomic AX insertion, Tab accept enabled.
- **ChromeElectronAdapter** — selected for verified Obsidian content fields; Chrome remains policy-rejected because its live AX text area exposes no trusted caret rectangle, while Cursor and VS Code remain excluded code-editor surfaces
- Bundle, editable-role, secure-field, and browser-chrome metadata gates all run before field-value reads; unknown apps, address/search bars, and unsupported roles remain content-blind
- Event fallbacks are evidence-gated per actual target and may only trigger a fresh AX snapshot. AX remains the content source and SecureFieldGate remains mandatory.
- Orion and Antinote's proven missing-notification paths use a listen-only, content-blind key event wake-up. It inspects no key payload and only schedules a fresh AX read.

### GhostOverlay
- Non-activating, click-through panel/window above the field
- Renders ghost string with best-effort host font metrics
- **Contract:** if caret rect missing, stale, or adapter marks untrusted → hide (never misdraw)

### PredictClient
- OpenRouter HTTPS client
- Latency-oriented model/routing preference
- Cancel in-flight on new keystroke after debounce restart
- Timeout: drop late responses; never apply stale ghost
- Exactly one in-flight request at a time
- CompletionCoordinator suppresses the request when the last non-whitespace character before the caret is `?`

### AcceptInsert
- Listens for Tab when a ghost is visible and adapter allows
- Accept the **entire shown 2–4-word completion** when the adapter permits Tab
- Inserts via active adapter; clears ghost
- Keep-typing: any other character rejects ghost and restarts debounce loop

### Settings / Keychain
- OpenRouter API key in Keychain only (not UserDefaults plaintext)
- Pause/resume global prediction
- Settings action to delete all encrypted learned-writing statistics
- Accessibility trust status and deep-link to System Settings
- Compatibility matrix and non-sensitive host/adapter/geometry diagnostics
- Normal launch opens the desktop Settings window; closing it leaves prediction running, and reopening the Dock app restores the window
- Explicit `--qa-settings` launch adds non-sensitive diagnostics to that Settings window
- The initial responder is a normal prediction control, never the secure API-key field; saving the key restores that safe focus so AeroSpace is not blocked by persistent Secure Input

## Data Flow (Phase A)

```text
keystroke / AX value change
        │
        ▼
 SecureFieldGate ──block──► (silent no-op)
        │ allow
        ▼
 debounce 80–150ms ──new key──► cancel in-flight + hide stale ghost
        │
        ▼
 adapter.readContext (short snippet) + caretRect?
        │
        ├── caret untrusted ──► hide ghost, skip predict (or predict but never show)
        │
        ▼
 PredictClient (one in-flight) ──timeout/cancel──► drop
        │
        ▼
 GhostOverlay.show(text, frame)   # only if still current + aligned
        │
        ├── Tab ──► AcceptInsert → adapter.insert(shown completion)
        └── type ──► reject → hide → loop
```

## Why Not Local LLM
- Phase A quality bar is low RAM and simple install
- OpenRouter keeps weights off-device
- Personalization uses **local style/vocab statistics** that shape prompts — still no local inference weights

## RAM and Latency Constraints
- No model weights in process or on disk for inference
- Idle footprint target: well under ~100MB
- Debounce ~80–150ms before request
- Cancel previous request when user keeps typing
- Drop responses that arrive after timeout or after a newer generation id
- Keep encrypted personalization persistence off the prediction-critical path
- Prefer hide over waiting for perfect geometry
- Default model: `google/gemma-4-26b-a4b-it`; OpenRouter providers sorted by latency; reasoning disabled

## Frontend Architecture
- Lightweight native AppKit Settings content in an AppKit-managed desktop window; SwiftUI remains only as the application scene/command shell
- AppKit for overlay window and AX / event integration
- Observation (`@Observable`) for UI state; services on `@MainActor` or explicitly isolated actors where needed
- LSUIElement = NO (normal Dock app; completion service remains alive with no open windows)

## Backend / Network
- Outbound HTTPS to OpenRouter only (for predictions)
- No first-party backend in Phase A
- API key from Keychain injected into Authorization header at request time

## Data Layer
- Keychain: API key
- Lightweight preferences (pause, debounce, model id): UserDefaults or SwiftData — keep minimal
- Writing profile: AES-GCM encrypted file in Application Support; encryption key in Keychain
- Profile contains bounded/aged word, two-word phrase, punctuation, capitalization, and sentence-length counters only
- Raw text history, documents, messages, secure-field values, and AI-inserted text are never persisted

## Infrastructure
- Distributed as a local `.app` (Xcode / SwiftPM as chosen at scaffold time)
- **Direct-distribution build is intentionally non-sandboxed.** Cross-app assistive AX reads, observers, and writes are incompatible with App Sandbox. Accessibility consent remains required. The `package_app.sh` script verifies bundle entitlements deterministically at packaging time.
- No server hosting
- Manual QA on must-pass apps is part of the architecture gate, not optional CI theater

## Key Trade-offs
| Choice | Trade-off |
| --- | --- |
| Overlay vs IMK | Better install UX and hide-on-failure; harder perfect caret in web views |
| Cloud vs local LLM | Low RAM, needs network + user key; latency depends on OpenRouter |
| Adapter matrix | More code per app class; add only after an actual target reproduces a generic adapter defect |
| Bounded full-phrase Tab | One deliberate action completes the visible phrase; the 2–4-word cap prevents uncontrolled insertion |
| Aggregate personalization | Learns useful repetition without raw history; subtler than retaining full text |
| Silent in-field failures | Cleaner typing; settings must surface API/permission issues |

## Non-Functional Requirements
- Swift 6 strict concurrency
- Privacy: short snippets only; no default field-content logs
- Every named target: live evidence required; never show a misaligned ghost
- Secure fields always blocked
- Phase A must not productize typo-fix or agent prompt-assist
