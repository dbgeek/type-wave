# HUD v3 graduation — handoff spec

The exit artifact of wayfinder map
[#39](https://github.com/dbgeek/type-wave/issues/39) (HUD v3: Liquid Glass).
The look and motion are **locked and proven by runnable prototypes**; this doc
is what a later graduation effort executes to land them in the deployed
daemon. The design decision itself — bare marks, no glass — is recorded in
[ADR 0002](adr/0002-hud-v3-is-bare-marks-no-glass.md).

The living reference is the prototypes, kept until graduation lands:

- `prototypes/liquid-glass-hud` — boots into the winning look + motion;
  exact constants and transition mechanics in code and `NOTES.md`.
- `prototypes/status-item-icons` — the winning Status Item icon; graduation
  crib in its `NOTES.md`.

## 1. Look (`src/hud.zig`)

Winner, in the prototype harness's terms:

    [glass=none tint=accent_strong bars=label radius=capsule shadow=true
     pill=300x22 bar=6w/4g(26) processing=dots_neutral show=fade
     switch=crossfade speed=0.7]

(`tint`/`radius`/`shadow` have no visible target while bare — the effective
window shadow is **off**.)

- Pill: **300×22** transparent panel; the #20 focus-avoidance recipe verbatim
  (accessory policy, nonactivating borderless panel, `orderFrontRegardless`,
  ignores mouse, status window level) — unchanged, proven glass-era and bare.
- Recording bars: `labelColor`, **6 pt wide / 4 pt gap → 26 bars**,
  re-resolved on repaint (tracks light/dark).
- Processing dots: `secondaryLabelColor`, sized/spaced/bounced relative to
  pill height (the prototype's 22 pt scaling, so nothing clips).
- Window shadow: **off** (macOS outlines raw bar layers otherwise).
- Audio mapping: **−60/−10 dBFS unchanged** — whisper contrast proven at this
  size (2026-07-17, live mic, light + dark backdrops).
- **Removals:** the custom red/green tint scheme, and `hud.zig`'s capsule
  background plate if any remains — the panel is fully transparent.

## 2. Motion (`src/hud.zig`)

- Show/hide: **fade** (window `alphaValue`); recording→processing:
  **crossfade** (bars fade out while dots fade in). All at **0.7×**:
  show ≈0.14 s, hide ≈0.11 s, crossfade ≈0.15 s.
- Mechanics (proven in the prototype, graduate as-is): explicit
  `NSAnimationContext` groupings for window alpha, nested actions-enabled
  `CATransaction`s for bar/dot layer opacity — CA interpolates in the render
  server. The 20 Hz render pump keeps its per-tick `setDisableActions:`
  (#25's verdict), only *starts* transitions, and **defers `orderOut` until
  the hide fade has played**.
- A hide starting from processing freezes the dots and fades out around them.
- The Utterance lifecycle mapping is untouched: recording on press→release,
  held over Insertion, hidden on every resolution.

## 3. Status Item (`src/menu.zig`)

- Swap `waveform` → **`waveform.badge.mic`** with an explicit
  `NSImageSymbolConfiguration`: **17 pt / regular weight / medium scale**.
- Keep `setTemplate:` and the **alpha 0.35** dim for the dimmed tier
  (paused / no key / permission missing).
- **Removal:** the `waveform.slash` swap — no slash variant exists for the
  new glyph; dimming is alpha alone.
- Menu content/structure untouched.

## 4. Build

- **No SDK switch.** The bare design never touches the glass API, so the
  daemon keeps building against the nix 14.4 SDK unchanged.
- For posterity: building against the 26.5 CLT SDK requires the CLI-only
  sysroot lever (`zig build --sysroot
  /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; see
  `prototypes/liquid-glass-hud/build.zig` for the `-L`/`-F` split) — only
  relevant if glass ever returns, and #41 showed even that likely isn't
  gated on the SDK stamp.

## 5. Acceptance

- Focus-avoidance intact: dictating into a terminal/Electron app never
  steals key focus (the #20 recipe checks).
- Lifecycle unchanged: pill shows on press, holds through Insertion,
  hides on every resolution path (success, error, timeout).
- Whisper re-check in the real daemon: bars visibly move at a live whisper
  over light and dark backdrops.
- Light/dark appearance pass: bars/dots legible in both, colors re-resolve
  on appearance change.
- Status Item sits naturally among Tahoe menu-bar icons at 17 pt; dimmed
  tier reads clearly at alpha 0.35.

## 6. Cleanup (final step of graduation)

Delete `prototypes/liquid-glass-hud` and `prototypes/status-item-icons` once
the daemon embodies everything they prove — they are throwaway by charter,
kept only as the runnable reference until then.
