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

Note that patches 1–4 are tagged in place; patch 5 is a one-case change in
`linkVisibleForClick` and carries the same marker. Patches 6–11 also touch
`Sources/SwiftTerm/SelectionService.swift`, `Sources/SwiftTerm/Terminal.swift` and
`Sources/SwiftTerm/EscapeSequenceParser.swift`.

## Patches

### 1. Pointer (trackpad / mouse) click-drag selection

`setupGestures()` → `enablePointerSelection()` + `pointerSelectHandler(_:)`

Upstream only offers text selection via a finger long-press. On iPad with a Magic
Keyboard / trackpad (or any indirect pointer) there was no way to click and drag to
highlight text for copy.

The patch adds a `UIPanGestureRecognizer` restricted to
`UITouch.TouchType.indirectPointer` that drives the existing `selection` engine:
`.began` anchors at the clicked cell, `.changed` extends to follow the pointer,
`.ended` requests the menu. To stop a trackpad drag from *scrolling* instead
of selecting, the scroll view's own `panGestureRecognizer` is restricted to
`UITouch.TouchType.direct` (finger) touches. Finger long-press selection and
two-finger scrolling are unchanged.

Coordinate-space note (fixed after shipping an earlier version):
`calculateTapHit` returns a **buffer-absolute** position, but the original
patch anchored via `startSelection(row:col:)`, whose API is screen-relative and
adds `yDisp` again. With any scrollback the double-add pushed the anchor past
the end of the buffer (clamped to the bottom), so a click-drag selected
everything from the bottom of the buffer up to the pointer. The anchor is now
set in buffer space via `setSelection`, with `selection.pivot` set explicitly
so `pivotExtend` can grow the selection in either direction (the old
`dragExtend` could only move the end, so upward drags misbehaved too).

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

### 4. Native-feeling touch selection (long-press select + drag extend)

`longPress(_:)`, `selectionMenuRequested`, and the `.ended` branch of
`pointerSelectHandler`.

Upstream's finger story was broken on modern iOS: long-press only popped a
deprecated `UIMenuController` with an empty item list (invisible on iOS 16+),
and no finger gesture could start or extend a selection at all — drag-to-select
was wired to indirect pointers only. The app compensated with its own long-press
recognizer to show a modern edit menu, and the two recognizers raced, making
selection feel random. Practical result: double-tap word select and Select All
were the only working touch selections.

The patch makes long-press behave like iOS text views: press selects the word
under the finger (with a selection haptic), dragging while pressed extends the
selection live (word-granularity, auto-scrolling past the top/bottom edge),
and lifting requests the edit menu. A long-press beginning near an endpoint of
an existing selection adjusts that end instead of starting over. Menu
presentation is delegated to the host app through the new
`selectionMenuRequested` callback (falling back to the legacy path when unset),
so the app presents a `UIEditMenuInteraction` menu at the selection and no
longer needs a competing recognizer.

### 5. Tappable links on touch

`AppleTerminalView.linkVisibleForClick` → the `.always` case.

Upstream gates link *activation* on `match.isExplicit`, so only an OSC 8
hyperlink can be followed; an implicitly-detected URL is matched by
`linkMatch(mode: .explicitAndImplicit)` and then discarded. On a desktop that's a
reasonable guard against stray cmd-clicks, but on iPhone it removes the feature
outright — the common case is a command printing a bare URL and expecting you to
open it, and a finger has no hover state and no modifier key to qualify the tap
with. (The app compounded this by leaving `linkHighlightMode` at its `.hover`
default, where the click gate compares against a highlight range only a trackpad
or Pencil can populate — so no link, explicit or not, was tappable at all. The
app now sets `.always`.)

The patch returns `true` for `.always` under `os(iOS) || os(visionOS)`, leaving
macOS on upstream behaviour. The implicit matcher requires a URL scheme
(`https?://`, `mailto:`, `ssh:`, …), so this does not make ordinary words into
tap targets, and the app filters what it will actually open down to http(s) and
confirms the destination before leaving the app.

The same section of `singleTap(_:)` now runs before the first-responder check
rather than inside it: upstream only looked for a link once the view had the
keyboard, so with the keyboard down a tap on a link raised the keyboard instead
of following the link.

Not patched: `shouldUnderlineLink`, which under `.always` returns
`cell.hasPayload` — implicit links are tappable but not underlined. Underlining
them means running the link matcher per row inside the draw path, which is the
cost patch 3 exists to avoid. Worth revisiting only with a per-row match cache.

### 6. A selection survives incoming output

`feedPrepare` / `feed(byteArray:)` / `feed(text:)` → `selectionFeedMark()` +
`settleSelection(after:)` in `AppleTerminalView.swift`; `linefeed(source:)`,
`longPress(_:)`, `singleTap(_:)` and `presentSelectionMenu(pos:)` in
`iOSTerminalView.swift`;
`SelectionService.linesTrimmed(count:)`.

Upstream dropped the selection on every feed and every line feed whenever mouse
reporting was allowed, which is the default. Anything on screen that repaints —
a multiplexer's status-line clock, a progress spinner — therefore erased a
selection within a second of making it, usually before Copy could be tapped
(and with the selection gone the edit menu no longer offers Copy at all).

The patch keeps the selection across feeds and settles it afterwards instead:

- lines pushed into scrollback keep their buffer rows, so nothing moves;
- lines trimmed off a *full* scrollback shift every row up — the selection moves
  with its text (`linesTrimmed`), and is dropped once that text is gone;
- a switch between the normal and alternate screens leaves the coordinates
  pointing into a different buffer, so the selection is dropped.

Long-press also no longer makes the view first responder. Upstream did, and
with the software keyboard down that slides the keyboard up, the terminal
resizes to make room, and `processSizeChange` drops the selection — so selecting
text with the keyboard hidden destroyed the selection it had just made. The edit
menu resolves its actions from the view either way.

Two smaller fixes ride along. A tap now dismisses an active selection before
anything else: upstream only cleared it when the remote had *not* asked for
mouse events, so with mouse reporting on the tap went to the remote as a click
and the selection could not be dismissed. And every gesture that leaves a
selection behind (double-tap, triple-tap, the selection pan) now offers the edit
menu through `selectionMenuRequested`, as patch 4 did for long-press — they
were still calling the invisible legacy menu.

The macOS view's `linefeed` gets the same change (patch 11).

### 7. Scrollback that holds its place

`updateScroller()`, `followsLiveTail`, `isAtLiveTail`, `scrollToLiveTail(animated:)`,
`scrollContent(toRow:)`, `liveTailChanged` and `layoutSubviews` in
`iOSTerminalView.swift`; `scrollTo(row:)`, `scrollUp(lines:)`,
`scrollDown(lines:)` in `AppleTerminalView.swift`.

Upstream's `updateScroller` pinned the scroll view to the bottom every time the
terminal scrolled a line, so the view could not stay on earlier output while
anything was still printing — scrollback was only readable in a silent
terminal. The view now follows the live tail only while it is at the tail.
Scrolled back, it holds its place (compensating when a full scrollback trims
lines off the top), reports the change through `liveTailChanged` so the host can
offer a way back, and returns on `scrollToLiveTail` or as soon as the user types.
"Following" is recorded when the user moves the view rather than derived from
geometry, so a resize (the keyboard appearing) can't be mistaken for scrolling
back, and neither can UIKit moving the origin on its own.

The same change fixes programmatic scrolling, which never worked on iOS: the
draw path reads `contentOffset`, but `scrollTo(row:)` only set `yDisp` and then
let `updateScroller` pin the offset back to the bottom. Keyboard scroll commands
and jump-to-match now move the view (`scrollContent(toRow:)`), and
`scrollUp`/`scrollDown` step from the row actually on screen.

### 8. OSC 52 from any selection target

`Terminal.oscClipboard(_:)`.

Upstream accepted only `OSC 52 ; c ; <base64>`. The selection field is any mix
of `c p q s 0-7`, and may be empty — which is exactly what tmux sends when copy
mode copies (`52;;<base64>`), so every tmux copy was silently dropped. The patch
accepts any valid target (there is one pasteboard, so they all map to it) and
tolerates stray whitespace in the payload. A `?` read request still goes
unanswered, so the remote cannot read the pasteboard.

Note for mosh: `mosh-server` 1.4.0 has the same `c`-only restriction on the
*server* side, so over mosh a tmux copy never reaches the client unless tmux is
told to emit the `c` target — see Terminal Help in the app.

### 9. Shell prompt marks (OSC 133)

`EscapeSequenceParser` → `case 133`; `Terminal.oscPromptMark(_:)`, `promptMarks`,
`hasPromptMarks`, `promptRows()`, `lastCommandOutput()`, `clearPromptMarks()`;
`TerminalView.scrollToPrompt(previous:)` in `iOSTerminalView.swift`.

Upstream ignores OSC 133. A shell set up for "semantic prompts" brackets every
command with marks — `A` at the prompt, `B` where the typed command starts, `C`
where its output starts, `D` when it finishes — and recording where they fell
is what lets a terminal jump between prompts and copy one command's output
without guessing at what a prompt looks like.

The patch records the marks for the normal screen (the alternate screen keeps
no history to navigate). A mark stores a line number that counts from the
buffer's creation (`linesTop + yBase + y`), so it stays attached to its text as
the scrollback trims and simply expires when that text is gone. Marks are
discarded when the lines are renumbered underneath them: the scrollback is
erased (`ED 3`), or a width change reflows it. `lastCommandOutput()` returns the
text between the last `C` and the mark that follows it, joining wrapped rows
and skipping commands that printed nothing.

These sequences only reach the terminal on a plain SSH session: a multiplexer
consumes them for its own prompt tracking and mosh drops what it doesn't model.

### 10. Resetting a mouse encoding no longer disables mouse reporting

`Terminal` private-mode reset → the `1005` / `1006` / `1015` / `1016` cases.

Upstream sets `mouseMode = .off` when any mouse *encoding* (UTF-8, SGR, urxvt,
SGR-pixel) is reset. Encoding and reporting are independent modes: xterm leaves
reporting alone when an encoding is reset. It matters here because mosh's
renderer refreshes every mode on a full repaint by resetting and re-setting it
— `?1002l ?1002h … ?1006l ?1006h` — and with upstream's behaviour the `?1006l`
switched reporting off after `?1002h` had just switched it on, and `?1006h`
does not switch it back. A full repaint happens on connect, on every resize and
every time the app returns from the background, so in a mosh session with a
mouse-mode program (a multiplexer with mouse on) the terminal forgot that the
program wanted the mouse after any of those, until the program happened to ask
again. Taps and scroll gestures then stayed local.

The patch drops the `mouseMode = .off` from the four encoding cases; resetting
the reporting modes themselves (`9`, `1000`, `1002`, `1003`) is unchanged.

### 11. macOS view: selection across output, and the scroll wheel to the remote

`Mac/MacTerminalView.swift` → `linefeed(source:)` and `scrollWheel(with:)`.

The Mac app shares this fork. Its view had the same selection-dropping
`linefeed` as iOS (patch 6), fixed the same way. And its scroll wheel only ever
scrolled the local buffer: with a program that has asked for the mouse — a
multiplexer in mouse mode, a pager — there is nothing local to scroll, and the
program never heard the wheel. The wheel is now reported to the remote in that
case (button 4/5 at the pointer's cell, trackpad deltas accumulated into whole
steps), and scrolls locally otherwise or with Shift held.

## Privacy manifest

Bundle `PrivacyInfo.xcprivacy` as a SwiftPM resource. It documents this fork's
predictive-input preference and in-container image file-metadata access; see
`docs/privacy-manifest-audit.md` at the repository root for release checks.
