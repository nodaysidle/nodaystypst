# Tasks Plan — nodaystypst

## Global Assumptions
- Greenfield: docs exist first; scaffold only when implementation is requested
- Stack: Native Swift 6 + SwiftUI menu-bar app; OpenRouter for predictions; **no local LLM**
- Injection: Accessibility + non-activating ghost overlay + adapter-based Tab insert (Approach 1)
- Completion loop: capture → debounce → predict → ghost → word-by-word Tab acceptance / keep-typing reject
- Must-pass: Orion Browser and Antinote only; remain content-blind and inactive elsewhere
- Every named target is a ship blocker; hide rather than misdraw
- Privacy: secure fields blocked; Keychain for API key; short snippets; silent in-field failures
- Debounce ~80–150ms; cancel in-flight on keystroke; timeout drops late responses; one in-flight request
- Out of Phase A: typo-fix productization; prompt-assist for ChatGPT/Claude/agents
- Personalization is explicitly approved: encrypted local style/vocab statistics shape OpenRouter prompts — still no local inference

## Current Takeover Status — 2026-07-29
- Automated baseline before takeover: 64 tests across 12 suites passed
- Implemented: Gemma 4 26B A4B default + migration, latency/privacy request policy, Orion content-blind AX refresh, word-by-word Tab, encrypted bounded global/per-app learning, Settings controls
- Current automated result: 79 tests across 14 suites passed
- Live Orion evidence from the preceding session remains valid for alignment, secure blocking, focus, and one-time insertion; word-by-word repeated Tab and the newly packaged binary require fresh live proof
- Antinote live gate remains open; Orion has prior live evidence and needs confirmation on the final scoped package.

## Risks
- AX notifications, caret geometry, and Tab semantics differ across target apps — characterize before adding fallbacks or adapters
- Tab conflicts in terminals and some web widgets — may force hide rather than accept
- OpenRouter latency variance — cancel/timeout/generation-id discipline is mandatory
- Accessibility permission UX can block first-run success
- AX APIs differ across apps; adapter sprawl if selection rules are vague
- App Sandbox is intentionally disabled for the direct-distribution build (cross-app AX reads/writes are incompatible with sandboxing); Accessibility consent remains required. Keychain + network entitlements must be wired correctly at scaffold.

## Epics (Phase A build order)

## 0. Scaffolding
**Goal:** Create a buildable menu-bar app skeleton with module stubs matching ARD/TRD.

### Create Xcode/SwiftPM macOS menu-bar project
- LSUIElement, network client entitlement (for OpenRouter), Keychain access, Accessibility usage description
- MenuBarExtra placeholder + Settings scene shell
- Stub modules: AccessibilityObserver, SecureFieldGate, FieldAdapters, GhostOverlay, PredictClient, AcceptInsert, CompletionCoordinator

**Acceptance Criteria**
- Project builds for macOS
- App appears as menu-bar only
- Stubs compile with public interfaces from TRD

**Dependencies:** None (implementation kickoff)

---

## 1. Permissions & Onboarding
**Goal:** Accessibility trust check + clear Settings/onboarding for key and permissions.

### Implement Accessibility permission flow
- `AXIsProcessTrusted` / prompt; deep-link to System Settings
- Menu bar status when denied

### Keychain API key Settings UI
- Save/load OpenRouter key via Keychain only
- Pause/resume toggle

**Acceptance Criteria**
- Denied Accessibility → no prediction loop
- Key persists across relaunch via Keychain
- Pause stops all ghosts

**Dependencies:** Scaffolding

---

## 2. Accessibility Observer
**Goal:** Reliable focused-element and value change stream with short context extraction.

### Implement AccessibilityObserver
- Focused UI element, value/selected text, app bundle id
- Bounded context snippet (TRD caps)
- Emit updates to CompletionCoordinator

**Acceptance Criteria**
- Switching apps/fields updates observer state
- Snippets respect max length
- No content logged by default

**Dependencies:** Permissions & Onboarding

---

## 3. Secure Field Gate
**Goal:** Never predict or show ghosts in secure fields.

### Implement SecureFieldGate
- Password / secure-text roles and traits
- Short-circuit before network

**Acceptance Criteria**
- Password fields produce zero OpenRouter calls
- Silent no-op in-field

**Dependencies:** Accessibility Observer

---

## 4. Native Field Adapter
**Goal:** Context + caret + insert for standard AppKit/AX fields used by actual native targets.

### Implement NativeAdapter
- `readContext`, `caretScreenRect`, `geometryTrusted`, `insertAcceptedText`
- Wire adapter selection for Orion and Antinote; safe-hide unsupported bundles before reading field content

**Acceptance Criteria**
- Actual NativeAdapter targets: trusted caret when available; insert works
- Untrusted geometry returns nil/false (hide path)

**Dependencies:** Accessibility Observer

---

## 5. Ghost Overlay
**Goal:** Non-activating overlay that never steals focus and hides when untrusted.

### Implement GhostOverlay
- Non-activating, click-through panel
- Show/hide/update ghost string at screen rect
- Hide on pause, focus loss, reject, accept

**Acceptance Criteria**
- Overlay does not activate nodaystypst
- Missing/untrusted rect → hide
- No misdrawn offset ghosts in native path

**Dependencies:** Native Field Adapter

---

## 6. OpenRouter Predict Client
**Goal:** Latency-oriented OpenRouter client with cancel, timeout, one-in-flight.

### Implement PredictClient + CompletionCoordinator debounce
- Debounce 80–150ms
- Cancel previous request; generation id; timeout drop
- Key from Keychain; short snippet only
- Silent failure on typing path

**Acceptance Criteria**
- Fast typing never applies stale completions
- Only one in-flight request
- Empty/error responses leave no ghost

**Dependencies:** Keychain Settings; Accessibility Observer

---

## 7. Tab Accept Insert
**Goal:** Tab accepts the next shown word via the active adapter; repeated Tab walks the remainder and typing rejects.

### Implement AcceptInsert
- Tab only when ghost visible and adapter allows
- Next-word insert; re-anchor and retain any visible remainder
- Keep-typing reject → restart debounce

**Acceptance Criteria**
- Tab inserts the exact next word once
- Repeated Tab inserts the remaining words one at a time without a new request
- Reject path clears ghost immediately

**Dependencies:** Ghost Overlay; Predict Client; Native Adapter

---

## 8. Actual Target Adapter Characterization (ship blocker)
**Goal:** Evidence-first support for Orion Browser and Antinote.

### Characterize before changing fallback code
- Verify installed bundle ID and selected adapter
- Test AX value/selection notifications, caret geometry, physical Tab insertion, continued-typing rejection, focus retention, and secure fields
- Add an app-specific adapter or event fallback only after reproducing the defect in that actual target
- Event fallback may only trigger a fresh AX snapshot; never log characters or replace AX content capture

**Acceptance Criteria**
- Every actual target meets the TRD bar or safely hides on untrusted geometry
- No Chrome, Cursor, or VS Code evidence is used as completion proof

**Dependencies:** Ghost Overlay; Predict Client; Accept Insert

---

## 9. Actual Target Gates
**Goal:** Close Orion Browser and Antinote surfaces while unsupported apps remain inactive.

### Native/web-view target passes
- Orion and Antinote complete the full Phase A loop

**Acceptance Criteria**
- Both named targets meet the TRD must-pass tests

**Dependencies:** Native Adapter; TerminalAdapter; actual-target characterization

---

## 10. Pause / Settings Polish
**Goal:** Usable menu-bar controls and onboarding copy.

### Finish Settings
- Model/routing default (optional), debounce display if exposed, last error (non-sensitive)
- Launch-at-login optional (not required for Phase A gate)

**Acceptance Criteria**
- User can pause, set key, see Accessibility status
- No secrets in logs or UserDefaults plaintext

**Dependencies:** Prior Phase A modules

---

## 11. Phase A Verification
**Goal:** Prove ship bar before claiming Phase A done.

### Verification checklist
- [ ] Orion Browser
- [ ] Antinote
- [ ] Unsupported-app content-blind safe hide
- [ ] Secure field block
- [ ] Debounce / cancel / timeout / one-in-flight
- [ ] Idle RAM well under ~100MB
- [ ] Tab accepts next word; repeated Tab walks the visible remainder
- [ ] No local LLM artifacts
- [ ] No typo-fix or agent prompt-assist features

**Acceptance Criteria**
- All boxes checked with evidence (manual notes / screenshots / Instruments memory)
- Failures fixed or explicitly deferred only if not ship blockers (Orion and Antinote cannot defer)

**Dependencies:** Epics 1–10

---

## 12. Personalization — Style / Vocab Statistics (approved and implemented)
**Goal:** Learn the user's repeated writing tendencies during normal use and shape OpenRouter prompts without raw history.

### Implemented
- AES-GCM encrypted global + per-app aggregate profile; key stored in Keychain
- Bounded/aged word, repeated phrase, punctuation, capitalization, and sentence-length statistics
- Minimum repeat threshold before any learned signal enters a prompt
- Secure-field, large-paste, and AI-inserted-text exclusion
- Global/per-app enable controls and reset actions
- Still **no local LLM weights**

**Acceptance Criteria**
- [x] Automated persistence, encryption, bounds, repeat-threshold, reset, and AI-exclusion tests
- [ ] One-day live observation confirms suggestions measurably reflect repeated vocabulary/phrasing
- [ ] Idle RAM remains well under ~100MB

**Dependencies:** Automated implementation complete; live validation follows app gates

---

## Suggested Agent Execution Order (Hermes / Eldio)
1. Scaffolding
2. Permissions & Onboarding
3. Accessibility Observer
4. Secure Field Gate
5. Native Adapter
6. Ghost Overlay
7. OpenRouter Predict Client + debounce coordinator
8. Tab Accept Insert
9. **Actual target adapter characterization**
10. Orion / Antinote gates and unsupported-app safe hide
11. Pause / Settings polish
12. Phase A Verification
13. Personalization (explicitly approved by the user)

## Open Questions
- Scaffold via XcodeGen vs plain Xcode vs SwiftPM executable — decide at implementation kickoff
- Determine whether any actual target requires a narrower adapter only after live AX characterization
