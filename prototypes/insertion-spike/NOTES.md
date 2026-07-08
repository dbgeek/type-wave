# Insertion spike — the question

**Throwaway prototype** for wayfinder ticket #9 ("Prototype the hold-to-talk
insertion spike"). Delete or graduate once the question below is answered.

## Question

Prove the **OS half without OpenAI**: a Zig binary that observes the chosen Talk
Key globally and, on release, performs an **Insertion** of a canned string into
whatever app has focus.

Specifically (from the two research crib sheets this ticket builds on):

- Does a listen-only `CGEventTap` on `flagsChanged` observe **Right-Option**
  (keycode 0x3D, device bit 0x40) press/release edges, non-consuming, while
  another app is focused? (`docs/research/macos-hotkey-observation.md` §7 item 1.)
- Does **pasteboard swap + synthetic Cmd-V** actually insert across the apps a
  developer lives in — a terminal, a browser field, Cursor (Electron), Notes?
  (`docs/research/macos-text-insertion.md` §10, spike item 5.)
- Which **TCC** grants are really needed, and does the CLI attribution land on
  the terminal? (Input Monitoring for the tap; PostEvent for the insert.)

## Design (per the crib sheets)

- **Talk Keys:** Right-Option → **paste** (primary mechanism); Left-Option →
  **keystroke** (fallback). Two keys so both mechanisms get an A/B across every
  test app in a single run. Edges are read from the device-dependent Alt bits
  (0x40 right / 0x20 left), which — unlike `kCGEventFlagMaskAlternate` — tell
  left from right.
- **Insertion off the callback:** the 400 ms paste (100 ms settle + Cmd-V +
  300 ms restore) runs on a worker thread. The tap callback stays sub-ms so the
  OS never disables the tap on timeout.
- **Clipboard:** save/restore plain text only (best effort; rich/promised types
  are lost — crib sheet §8), mark writes `TransientType` + `ConcealedType` so
  clipboard managers skip them.
- **Self-event guard:** posts carry `kCGEventSourceUserData = -27469`; the tap
  skips them (belt-and-braces — the Talk Key ≠ the V/Cmd we post anyway).
- **Secure Event Input:** checked before each insert; suppression is reported,
  not silently dropped.

## Structure

- `src/tap.zig` — listen-only CGEventTap Talk Key observer (portable; graduation candidate)
- `src/insert.zig` — paste + keystroke Insertion, TCC, secure-input (portable; graduation candidate)
- `src/main.zig` — terminal shell wiring the two + the worker thread (throwaway)

## How to run

    cd prototypes/insertion-spike
    zig build run          # inside `nix develop`

First run: grant this terminal **Input Monitoring** and **Accessibility**
(PostEvent) when prompted (or add it by hand), then re-run. Then focus a test app
and hold Right-Option (paste) or Left-Option (keystroke); release to insert.

Reset grants for clean re-testing:

    tccutil reset ListenEvent
    tccutil reset PostEvent      # (a.k.a. Accessibility for our posting)

## Verdict (2026-07-08)

**Yes — the OS half is real.** A background Zig binary observes the Talk Key
globally and inserts a canned string into whatever app has focus, no OpenAI in
the loop. Proven live on macOS 26.5.1 with the flake's Zig.

- **Talk Key observation — PROVEN.** A listen-only `CGEventTap` on `flagsChanged`
  delivered clean Right-Option (keycode 0x3D, device bit 0x40, flags 0x80140) and
  Left-Option (0x3A / 0x20 / 0x80120) press **and** release edges while other apps
  were focused, non-consuming (the Option keys still worked normally). Held-time
  measured per hold (~140–2300 ms). Left/right distinguished by both keycode and
  device bit, exactly as `docs/research/macos-hotkey-observation.md` predicted; no
  autorepeat storm on a held bare modifier.
- **Insertion — PROVEN across all five test apps.** Both mechanisms landed the
  canned string in: **Terminal** and **Ghostty** (terminals), **Google Chrome**
  (browser field), **Cursor** (Electron/Chromium), and **TextEdit** (native
  AppKit — same app-class as Notes per crib-sheet §5, used as the stand-in).
  Right-Option → pasteboard-swap + Cmd-V (primary); Left-Option → chunked Unicode
  keystrokes (fallback). Both worked everywhere.
- **TCC — exactly two grants, both attributed to the terminal.** Input Monitoring
  (`kTCCServiceListenEvent`) for the tap and PostEvent (`kTCCServicePostEvent`,
  shown under Accessibility) for the insert — granted to Ghostty (the responsible
  terminal for a CLI run) in System Settings. Pasteboard needed no grant, no full
  Accessibility, no AX. Until Input Monitoring was granted the tap was created
  **non-NULL but disabled**, and the binary detected + reported that (crib-sheet
  §3/§5 "stale NULL" claim confirmed live).
- **Secure Event Input — the surprise, and it does NOT block us.** On this machine
  `IsSecureEventInputEnabled()` is effectively always true: the holder (via
  `kCGSSessionSecureInputPID` + libproc) tracked the frontmost app — TextEdit,
  Cursor, Chrome, Ghostty, Terminal each reported as holder while focused (secure
  input is stuck on system-wide). **Yet both Cmd-V and synthetic keystrokes still
  inserted correctly in every app.** This answers crib-sheet §6 open Q / spike
  item 4: here, secure input suppresses *listening* but NOT `CGEventPost` / Cmd-V.
  **Design consequence for #10: the daemon should only _warn_ on secure input,
  never hard-block** — the original hard guard was wrong and was changed to
  warn-and-attempt.

Not separately audited this pass (cheap follow-ups if they matter): per-glyph
fidelity of ✅ / é / 😀 vs. tofu, and whether the clipboard was faithfully
restored after each paste (the code saves/restores plain text only, best-effort —
§8).

**Disposition:** code stays in `prototypes/insertion-spike/`. `src/tap.zig` (Talk
Key observer) and `src/insert.zig` (paste + keystroke Insertion, TCC, secure-input)
are the graduation candidates; `src/main.zig` is the throwaway shell. What
graduates, and how, is #10's call.
