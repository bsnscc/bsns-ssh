# Accessibility

Terminals are one of the least accessible app categories — VoiceOver users are
badly served by terminal emulators. We treat accessibility as both table stakes
(the UI chrome should just work) and a genuine differentiator (a VoiceOver-
readable terminal is rare). This doc records what's done and scopes what's next.

## Done (quick-wins pass)

- **Labeled controls.** Every icon-only button has an `accessibilityLabel`
  (terminal toolbar: Find / Decrease text size / Increase text size / More
  actions; find bar: Previous match / Next match / Close find; tab strip: New
  session / Close <title>; SFTP: New folder / Upload file). Previously VoiceOver
  read these as bare "Button".
- **Dynamic Type.** The SwiftUI chrome uses semantic text styles
  (`.subheadline`, `.caption`, …), which scale with the system text-size setting.
  The terminal has its own independent font-size control (pinch / the
  smaller/larger buttons).
- **Dark + contrast.** Dark by default; primary text `#E8E8E8` on `#0F0F0F` and
  the `#00C29C` accent are high-contrast. Theme presets give alternatives.

## App Store accessibility nutrition label — what to claim

Honest claims today (verify each on-device with the feature on):

- ✅ **Dark Interface** — yes.
- ✅ **Larger Text** — the UI chrome scales with Dynamic Type.
- ✅ **Sufficient Contrast** — primary text/accent on the dark background.
- ✅ **VoiceOver** — *for the app UI* (connect, settings, keys, SFTP, toolbars)
  now that controls are labeled. **Caveat:** the live terminal *content* is not
  yet VoiceOver-navigable (see below) — keep marketing claims scoped to the UI
  until that ships.
- ⚪ **Voice Control** — labeled controls make most of it work; spot-check.
- ⚪ **Reduced Motion / Differentiate Without Color** — little motion; we don't
  rely on color alone for meaning. Low effort to confirm/declare.

## Next: VoiceOver-readable terminal (post-launch differentiator)

The headline feature. Making terminal *output* accessible to VoiceOver is rare
and on-brand. Scope:

**Goal.** A VoiceOver user can read terminal output line-by-line, hear new output
as it arrives, and review scrollback — not just operate the chrome.

**Approach (to prototype):**
- Expose the terminal grid to UIKit accessibility — likely a custom
  `accessibilityElements` mapping buffer rows to elements (text per line), or an
  `UIAccessibilityContainer` over the visible buffer + scrollback.
- Announce new output via `UIAccessibility.post(notification: .announcement)` (or
  a live region), rate-limited so a busy TUI doesn't flood the user.
- A rotor / line navigation so output is reviewable by line and word.
- Respect "screen curtain" and focus behavior; don't fight VoiceOver's cursor.

**Hard parts:**
- Live, high-frequency updates (spinners, TUIs) vs. not overwhelming the listener
  — needs smart coalescing / "speak on quiesce."
- Scrollback vs. the live screen; mosh's framebuffer model.
- Wide/Unicode glyphs and prompts; meaningful line boundaries.
- Performance — accessibility tree updates on every frame are expensive.

**Validation:** this MUST be tested with actual VoiceOver users, not just the
simulator's Accessibility Inspector. Treat it as a designed feature with real
user feedback, not a checkbox.

**Refinements also worth doing:** accessibility labels on the special-keys bar
(esc / ⌃C / arrows read meaningfully), and an audit pass with the Accessibility
Inspector across every screen.
