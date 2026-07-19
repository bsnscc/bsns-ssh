# Vendored SwiftTerm — local patches

This is a vendored fork of upstream [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
**1.13.0**, copied into the tree so we can carry small behavioural patches that the
app can't make from the outside (they touch `internal` members of the terminal view).

Only the `SwiftTerm` library target is vendored. Upstream's `Fuzz`, `Termcast`, the
macOS example apps, and the benchmark targets are intentionally dropped from
`Package.swift` — the iOS app links the library alone.

## How to refresh from upstream

1. Bump the pinned version below and copy `Sources/SwiftTerm` + `LICENSE` from a clean
   checkout of the new tag.
2. Re-apply each patch listed here (search for the `bsns fork:` markers).
3. `xcodegen generate && xcodebuild ... build` to confirm it still compiles.

Pinned upstream: **1.13.0**. Patches live in
`Sources/SwiftTerm/iOS/iOSTerminalView.swift` and
`Sources/SwiftTerm/Apple/AppleTerminalView.swift`, tagged with a `bsns fork`
comment so they're greppable.

## Patches

### 1. Pointer (trackpad / mouse) click-drag selection

`setupGestures()` → `enablePointerSelection()` + `pointerSelectHandler(_:)`

Upstream only offers text selection via a finger long-press. On iPad with a Magic
Keyboard / trackpad (or any indirect pointer) there was no way to click and drag to
highlight text for copy.

The patch adds a `UIPanGestureRecognizer` restricted to
`UITouch.TouchType.indirectPointer` that drives the existing `selection` engine:
`.began` → `startSelection` (anchor at the start cell), `.changed` → `dragExtend`
(move the END to follow the pointer), `.ended` → `showContextMenu`. Note it uses
`dragExtend`, **not** `pivotExtend` — `pivotExtend` no-ops unless `selection.pivot`
is set (which `startSelection` doesn't do), so an early version selected a single
cell but never extended on drag. To stop a trackpad drag from *scrolling* instead
of selecting, the scroll view's own `panGestureRecognizer` is restricted to
`UITouch.TouchType.direct` (finger) touches. Finger long-press selection and
two-finger scrolling are unchanged.

### 2. PageUp / PageDown forwarded to the remote (tmux scrollback)

`pressesBegan` → `.keyboardPageUp` / `.keyboardPageDown` case (and the Kitty-protocol
path earlier in the same method).

Upstream maps the hardware PageUp/PageDown keys to *local* SwiftTerm buffer scrolling.
That means inside tmux / less / a full-screen TUI the keys never reach the remote, so
tmux copy-mode paging and app-level paging don't work — you can only scroll the local
one screen.

The patch forwards plain PageUp/PageDown to the remote as `ESC[5~` / `ESC[6~`
(`EscapeSequences.cmdPageUp` / `cmdPageDown`), and reserves **Shift+PageUp/PageDown**
for local-buffer scrolling. Both the normal and Kitty-keyboard-protocol code paths are
patched so the behaviour is consistent regardless of negotiated keyboard mode.

### 3. iOS region repaint (battery)

`AppleTerminalView.updateDisplay` (iOS branch), `iosRegion(forUpdateRows:_:)`,
and the row-band selection in `drawTerminalContents`.

Upstream's iOS path invalidated the full view bounds on every feed (the macOS
branch computes a dirty region; the iOS side was a `TODO`). A busy pane — e.g. a
tmux window running a program with an animated status line — emits several small
diffs per second, and each one repainted every visible cell plus filled the whole
view with background first: identical pixels, ~20× the drawing work, a steady
battery cost.

The patch invalidates only the changed rows (content-space band anchored at
`yBase`, ±1 row of padding for glyph overhang) and lets `drawTerminalContents`
draw just that band when the incoming dirty rect is narrow. The known UIKit
hazard that made upstream ignore dirty rects — scroll-coalesced rects delivered
with the wrong origin — is detected by intersection: a mis-offset rect misses
the visible band entirely and falls back to the full-viewport draw, preserving
upstream's safety behaviour.
