---
name: verify
description: Verify Fork/** changes end-to-end in the running Ghostty.app.
---

# Verify (ghostty macOS fork)

## Surface

Fork/** changes surface in the running `Ghostty.app` GUI. There is no headless
mode; the reducer/model layer is covered by Swift Testing suites but the
view↔AppKit seams (TextField binding writes, `.onSubmit` ordering, focus,
`performKeyEquivalent`) only manifest in the live app.

## Build & launch

```sh
./scripts/fork-release.sh                              # ReleaseLocal, self-signed
open macos/build/ReleaseLocal/Ghostty.app              # or GHOSTTY_FORK=1 for Debug
```

Second instance exits silently with status 1 (fork.json single-instance guard) —
quit the running one first, or the launch is a no-op.

## Driving the GUI

`osascript` keystroke injection needs Accessibility TCC for the *invoking*
terminal (System Settings → Privacy & Security → Accessibility). Without it,
`System Events got an error: osascript is not allowed to send keystrokes. (1002)`.

No XCUITest harness exists for Fork views yet. Until one does, GUI-seam changes
(palette key handling, sheet focus, sidebar drag) are user-driven: build, hand
the flow to the user, capture their confirmation.

## Reducer/model changes

If the change is entirely inside a `Fork/Model/*` reducer or `NewSessionMachine`
and the view wiring is untouched, the Swift Testing suite is the observable
surface — but state that explicitly in the verify report; a view-seam change
masquerading as reducer-only is exactly the class of bug this fork keeps hitting
(see `project_swiftui_recurring_hazards.md`).

## Post-rebase smoke pass

After any upstream rebase, run the 5-step smoke pass in `Fork/CLAUDE.md` §
"Branches & release" — those five contracts break silently.
