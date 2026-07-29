# AGENTS.md — nodaystypst

## Purpose
Guardrails for coding agents (and humans) implementing nodaystypst. Read `PRD.md`, `ARD.md`, `TRD.md`, and `TASKS.md` before writing code. This folder starts as a **docs-only** pack; do not invent a fake `codemap.md` until real entry points exist.

## Product Lock (do not drift)
- **Name:** nodaystypst
- **Stack:** Native Swift 6 + SwiftUI menu-bar app
- **Inference:** OpenRouter only — **do not add a local LLM**, GGUF, MLX, llama.cpp, or embedded weights
- **Injection:** Accessibility + non-activating ghost overlay + adapter-based Tab insert (**Approach 1**)
- **Completion loop:** capture → debounce → predict → ghost → Tab accepts the **next shown word** / repeated Tab walks the remainder / keep typing rejects
- **Personalization:** approved local style/vocab statistics shape OpenRouter prompts — still no local inference and no raw writing history
- **Quality:** idle RAM well under ~100MB; **hide ghost rather than misdraw**
- **Supported / must-pass apps:** Orion Browser and Antinote only
- **Supported bundle IDs:** `com.kagi.kagimacOS`, `com.chabomakers.Antinote`; remain content-blind and inactive elsewhere
- **Out of Phase A:** inline typo-fix productization; prompt-assist for ChatGPT/Claude/agents

## Do
- Follow TASKS.md build order unless the user explicitly re-prioritizes
- Keep modules aligned with ARD: AccessibilityObserver, SecureFieldGate, FieldAdapters, GhostOverlay, PredictClient, AcceptInsert, Settings/Keychain
- Debounce ~80–150ms; cancel in-flight on keystroke; timeout-drop late responses; **one** in-flight request
- Store API keys in **Keychain only**
- Send **short context snippets** only
- Fail **silently** on the typing/caret path; surface permission/key issues in Settings
- Treat untrusted caret geometry as **hide**
- Keep the default model locked to `google/gemma-4-26b-a4b-it` unless the user explicitly changes it
- Encrypt bounded learning statistics locally; exclude secure fields and AI-inserted text
- Require live QA on Orion and Antinote before claiming Phase A done
- Before adding an event fallback, prove the target app's bundle ID, selected adapter, missing AX notification, caret geometry, and Tab behavior
- Any event fallback may only trigger a fresh AX snapshot; it must never record characters, bypass secure-field gating, or replace AX as the content source
- Prefer smallest correct change; match existing project patterns once code exists
- After scaffolding, add `codemap.md` with real entry points and commands

## Don't
- Do not add local models or download weight files
- Do not show a misaligned ghost “for convenience”
- Do not log field contents by default
- Do not store API keys in UserDefaults, plist plaintext, or source
- Do not implement IMK as the primary path without an explicit product decision change
- Do not ship Phase A without Orion and Antinote gates
- Do not use Chrome, Cursor, or VS Code evidence to satisfy Phase A acceptance
- Do not productize typo-fix or agent prompt-assist in Phase A
- Do not persist raw documents, messages, chronological typing history, or reconstructed keystrokes for personalization
- Do not create commits, publish, notarize, or change machine-wide config unless asked
- Do not edit the plan file under `~/.cursor/plans/`
- Do not scaffold the app until the user asks to implement

## Scope Discipline
- Stay inside the current TASKS epic / user request
- No drive-by refactors, dependency sprawl, or unrelated docs
- If PRD/ARD/TRD conflict with code, stop and report — do not silently “improve” locked decisions

## Privacy & Security Checklist
- [ ] Secure fields blocked before predict
- [ ] Keychain for secrets
- [ ] Short snippets on the wire
- [ ] No field-content logging by default
- [ ] Overlay never activates / steals focus
- [ ] Learned profile encrypted; secure fields and AI completions excluded

## Verification (when code exists)
Run the lowest sufficient rung; record command + result before claiming done.

1. **Build** — `xcodebuild` / `swift build` as wired by the scaffold
2. **Unit** — debounce/cancel/generation-id, secure-gate, adapter trust helpers
3. **Manual must-pass** — Orion Browser and Antinote per TRD
4. **Memory** — Activity Monitor / Instruments idle footprint well under ~100MB
5. **Negative** — password field produces no ghost; untrusted caret hides; stale responses ignored

Until a scaffold exists, verification for doc-only work is:
- Confirm the five files exist and agree on locked decisions
- `ls` / `git status` as appropriate — **no commit unless requested**

## Phase A Done Means
All of the following are true with evidence:
- Phase A loop works on must-pass apps
- Every actual target has evidence for AX notifications, adapter selection, aligned ghost-or-safe-hide, full physical-Tab insertion, continued-typing rejection, focus retention, and secure-field blocking
- Tab accepts the next shown word; repeated Tab accepts the remaining words one at a time
- Secure fields blocked; Keychain key; silent in-field failures
- No local LLM; RAM target held
- Typo-fix and agent prompt-assist **not** shipped

## Doc Map
| File | Role |
| --- | --- |
| `PRD.md` | Product vision, Phase A/B, metrics |
| `ARD.md` | Architecture, modules, Approach 1 |
| `TRD.md` | Contracts, OpenRouter, adapters, QA |
| `TASKS.md` | Phased build order |
| `AGENTS.md` | This file — anti-drift rules |
| `codemap.md` | Add only after real code entry points exist |
