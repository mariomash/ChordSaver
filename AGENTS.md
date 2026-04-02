# AGENTS.md

This file is the single source of truth for AI coding agents working in this repo.

---

## Coding philosophy (Karpathy-inspired guidelines)

Behavioral guidelines to reduce common LLM coding mistakes.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

## MegaChord implementation principles

When the user asks for an **implementation** (feature, fix, or behavior change) in this repo:

### Dual surface (hardware + on-screen Launchpad)

- Treat **physical Launchpad output** (SysEx / MIDI / `LaunchpadHardwareLighting` and AU paths that refresh hardware LEDs) and the **SwiftUI Launchpad surface** (`LaunchpadSurfaceView` and related) as **one product surface**.
- Prefer a **single source of truth** (shared model, snapshot, driver, or pure helper in `Shared/`) that **both** paths consume, so tempo, pulse, colors, layout-affecting state, and programmer/live behavior stay aligned.
- If a change only touches one path, **explicitly extend** the shared path or add the missing call so the other surface is not left stale.

### Duplication and structure

- When planning a new implementation, take a general look and see if there are any existing helpers, snapshots, or pipelines that could be extended to cover the new case instead of adding a new one.
- When planning a new implementation, check if the same logic is needed in both "hardware" and "on-screen" paths. If so, prefer a single shared implementation that both call into instead of two parallel implementations.
- **No duplicated logic (mandatory):** Before finishing an implementation or fix, ensure the same policy (colors, thresholds, routing, clamping, titles, etc.) exists in **one** place. If two call sites need the same behavior, **extract** a shared helper (prefer `Shared/`, `LaunchpadChordOctaveShift`-style enums, or `extension TypeName` in `TypeName+Topic.swift`) and call it from both paths.
- **No parallel branch ladders:** Avoid copy-pasted `if`/`switch` trees for "hardware" vs "on-screen," or for two controllers that share a rule. Prefer **one** branch or index (e.g. table lookup, `min`/`max` tier, `switch` on a small enum) that all paths use.
- **Reduce duplication** before shipping: extract shared logic into named functions rather than repeating blocks.
- Do **not** fork parallel "hardware version" and "view version" of the same algorithm when one parameterized implementation can serve both.
- Reuse existing bridges (e.g. pad lighting pulse driver, scale store, kernel snapshots) instead of adding parallel pipelines.
- After every implementation, asses if there are orphan lines (e.g. unused variables, imports, functions) that your change made unused — remove them. Asses also if there are orphan code branches (e.g. `if`/`switch` cases) that your change made unreachable — remove them.
- Better one way of doing things than a way and a fallback. If you find yourself hacking in a fallback, stop and ask: can I just make the main way work?

### Simplicity, maintainability, elegance

- Prefer the **smallest change** that fully satisfies the request; avoid drive-by refactors and speculative abstractions.
- Favor **clear data flow** (one direction: host/kernel → snapshot → UI/hardware) over clever branching.
- Match **existing naming, file layout, and documentation level** in the codebase; new code should read as if written by the same author.
