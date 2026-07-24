# Undo backspace semantics: what one synthetic Delete keystroke removes

Research for map #209 ("Undo last Insertion"), ticket #211.

**Question.** When the daemon posts a synthetic Delete (`kVK_Delete = 0x33`) via
`CGEventCreateKeyboardEvent` + `CGEventPost` into the frontmost app, how much text does
**one** keystroke remove — one grapheme cluster, one Unicode scalar, or one UTF-16 code
unit? And is that consistent across AppKit text, Chromium/Electron web inputs, and terminal
emulators? The daemon must turn an Insertion's stored `inserted` bytes
(`Record.inserted_len` is a **UTF-8 byte** count, `src/recent_insertions.zig`) into a
correct backspace count `N`.

---

## TL;DR — the counting rule

> **Count extended grapheme clusters (UAX #29) over the stored UTF-8 `inserted` bytes; that
> count is `N`, the number of Delete keystrokes to post.** One keystroke removes one
> grapheme cluster in the two well-defined targets (AppKit and Chromium/Electron), so
> grapheme count is the correct unit there.

Do **not** count UTF-8 bytes, UTF-16 code units, or Unicode scalars: a single emoji, a
flag, a skin-tone/ZWJ sequence, or a base-char-plus-combining-mark is *one* grapheme
cluster but *several* scalars / code units / bytes, and each is removed by a **single**
keystroke in AppKit and Chrome. Counting any smaller unit over-deletes.

**The one place this rule is wrong is terminal emulators** — see the per-target table.
There, deletion is byte- or scalar-granular (never grapheme-granular), so `N =
grapheme-count` under-deletes emoji/combining text and the whole approach is best-effort.

Because the daemon already records **App Identity** (bundle id) per Insertion, the safe
posture is: apply the grapheme rule for AppKit/Chromium apps, and treat terminals (and
other raw-input apps) as a **refuse / best-effort** class rather than trusting the count.

---

## Why there is no single OS-level answer

A synthetic `kVK_Delete` keystroke deletes **nothing by itself**. `CGEventPost` injects a
hardware-equivalent key event into the session; the **receiving app's own text engine**
decides how much text one Backspace removes. So the deletion unit is a property of *each
target's text handling*, not of the daemon, the CGEvent, or macOS. The daemon can only pick
a count and hope the frontmost app's engine agrees.

Two clarifications on the keystroke itself:

- On macOS **`kVK_Delete` (0x33) is the Backspace key** — it deletes *backward* (toward the
  start), which is what Undo needs. Forward-delete is `kVK_ForwardDelete` (0x75); we do not
  use it. The naming is a long-standing Apple quirk.
- Posted Delete events must carry the existing `self_event_tag` (as `postCmdV` does in
  `src/insert.zig`) so the Talk Key tap does not self-observe them — mechanism note for the
  spec, not part of the counting rule.

---

## Per-target table

| Target | Unit removed per Delete keystroke | `N = grapheme count` correct? | Confidence | Caveats |
|---|---|---|---|---|
| **AppKit** `NSTextField` / `NSTextView` (`deleteBackward:`) | **One grapheme cluster** (composed character sequence, via `-[NSString rangeOfComposedCharacterSequenceAtIndex:]`) | **Yes** | High (documented behavior of the standard text engine) | Whole-cluster deletion of newer emoji (flags, ZWJ, skin-tone) depends on the OS's Unicode segmentation version; older macOS deleted such sequences fragment-by-fragment. Custom `NSTextView` subclasses that override `deleteBackward:` can diverge. |
| **Chromium / Electron** web inputs (`<input>`, `<textarea>`, plain `contenteditable`) — DOM `deleteContentBackward` | **One grapheme cluster** (Chrome/Blink deletes by extended grapheme cluster, matching the macOS platform) | **Yes** | Medium-High | JS can intercept `beforeinput`/`keydown` and do anything: rich editors (Slack, Notion, Google Docs, CodeMirror/Monaco), mention "chips", autocomplete, and markdown auto-formatting may delete a code point, a whole widget, or nothing — arbitrary and per-app. Google Docs renders to canvas and does not use a real text field at all. |
| **Terminal emulators** (Terminal.app, iTerm2) | **Not grapheme-granular.** The emulator sends a byte (DEL `0x7F` / BS `0x08`) to the pty; the *foreground program's* line editor deletes. Best case (UTF-8 `readline`, bash ≥2.05b) = **one Unicode scalar / code point**; worst case (byte-oriented or misconfigured) = **one UTF-8 byte**; raw-mode TUIs (vim, less, REPLs) = **undefined**. | **No** | Low | Emoji/combining sequences are multiple scalars → need multiple keystrokes and a grapheme count under-deletes. Byte-oriented editors can leave broken UTF-8 fragments. Programs in raw mode may not map Backspace to deletion at all. **Treat as best-effort / out of the trusted gate.** |

### How to read "grapheme cluster" here

For a non-BMP emoji like 😃, AppKit's `deleteBackward:` removes an `NSRange` of **length 2**
(two UTF-16 code units = one surrogate pair = one scalar = one grapheme cluster) in a
**single** keystroke. That length-2 is the UTF-16 span of the one grapheme, not evidence of
per-code-unit deletion. The unit of deletion is the whole composed sequence.

---

## Emoji / combining / trailing-space analysis

| Stored text | Bytes | UTF-16 units | Scalars | **Grapheme clusters** | Keystrokes in AppKit / Chrome | In a terminal |
|---|---|---|---|---|---|---|
| trailing ASCII space `" "` | 1 | 1 | 1 | **1** | 1 | 1 (safe everywhere) |
| `é` as U+0065 U+0301 (combining acute) | 3 | 2 | 2 | **1** | 1 | 2 (scalar) or 3 (byte) |
| 😃 U+1F603 | 4 | 2 | 1 | **1** | 1 | 1 scalar (readline) / 4 bytes (worst) |
| 🇺🇸 flag (2 regional indicators) | 8 | 4 | 2 | **1** | 1 | 2 scalars / 8 bytes |
| 🏄🏼‍♂️ surfer + skin tone + ZWJ + gender (multi-scalar ZWJ) | 17 | 7 | 4 | **1** | 1 (modern macOS) | 4 scalars / 17 bytes |

**Takeaways.**

- **Trailing space** (every Insertion ends with one, per CONTEXT.md *Insertion*): it is a
  single scalar / byte / cluster / column, so it costs exactly **1** keystroke in every
  target. This is the one universally safe unit.
- **Combining marks and all emoji forms** are exactly where byte / scalar / UTF-16 counting
  diverges from grapheme counting. Grapheme counting is right for AppKit/Chrome; every
  smaller unit over-deletes there. In terminals none of the counts are reliably right for
  these.
- The multi-scalar ZWJ surfer is the sharpest test: 17 bytes / 4 scalars but **one**
  keystroke in modern AppKit. Any byte- or scalar-based count would delete 4–17 extra
  characters of preceding text.

---

## Implementation note (for the downstream spec/effort)

Computing "grapheme clusters over UTF-8 bytes" requires **UAX #29** grapheme segmentation,
which Zig's `std.unicode` does **not** provide (it gives scalar iteration only). Two options
for whoever builds Undo:

1. **Bridge to the OS segmenter** — count composed character sequences with CoreFoundation
   (`CFStringGetRangeOfComposedCharactersAtIndex`) / `NSString`
   `rangeOfComposedCharacterSequenceAtIndex:`. This is the **same API AppKit's
   `deleteBackward:` uses**, so the count matches what the field will actually delete —
   exact parity, and it tracks the OS's Unicode version automatically. Preferred.
2. Vendor a UAX #29 grapheme table. More code, and it can drift from the OS's segmentation
   version (re-introducing the emoji-fragment mismatch).

Given the app-level gate already in scope, pairing the grapheme count with an **App Identity
allow/deny classification** (trust AppKit + Chromium bundles; refuse terminals and unknown
raw-input apps) is the robust shape.

---

## Needs on-device confirmation

These are behavioral claims that this desk research **cannot** verify without running on the
target machine/OS version; confirm before locking the spec:

1. **Modern macOS deletes multi-scalar emoji (flags, ZWJ, skin-tone) as one keystroke in
   `NSTextField`/`NSTextView`.** Documented direction is whole-cluster, but the exact
   fragment/whole-cluster boundary is OS-version-dependent — verify on the deployment macOS
   version with 🇺🇸, 🏄🏼‍♂️, and base+combining `é`.
2. **Electron/Chromium plain inputs delete by grapheme cluster on macOS** (not code point)
   for the same sequences — verify in a representative Electron app (e.g. VS Code, Slack
   composer, a plain `<textarea>` in Chrome).
3. **Rich editors' divergence.** Spot-check the apps users actually dictate into (Slack,
   Notion, Google Docs, VS Code editor pane) — these are the likeliest to intercept
   `beforeinput` and break the count. Google Docs in particular is canvas-rendered.
4. **Terminal reality.** Confirm in Terminal.app and iTerm2 under a normal UTF-8 `zsh`/`bash`
   whether Backspace deletes one scalar (expected with modern readline/zle) vs one byte, and
   confirm emoji/combining need multiple keystrokes — establishing that terminals must be a
   refuse/best-effort class.
5. **Autocorrect / predictive text interaction.** A Backspace immediately after macOS
   autocorrect can *revert the correction* rather than delete a character. Verify this does
   not desync the count in AppKit fields with autocorrect on.

---

## Sources

- Apple, [*Characters and Grapheme Clusters*](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/stringsClusters.html) and [`rangeOfComposedCharacterSequence(at:)`](https://developer.apple.com/documentation/foundation/nsstring/1416036-rangeofcomposedcharactersequence?language=objc) — grapheme-cluster boundaries for AppKit deletion.
- [`deleteBackward()` — UIKit docs](https://developer.apple.com/documentation/uikit/uikeyinput/deletebackward()) and [openradar #21005](https://github.com/lionheart/openradar-mirror/issues/21005) — deleteBackward NSRange spans the whole composed sequence (😃 → length 2).
- W3C, [*Input Events Level 1*](https://www.w3.org/TR/input-events-1/) — non-normative note: "In some scripts on some platforms, backward deletion within a text node with a collapsed selection will delete a single code point rather than a[n] entire grapheme cluster"; `getTargetRanges()` to introspect.
- [w3c/input-events #71 — Code points and graphemes in backward deletion](https://github.com/w3c/input-events/issues/71) — Chrome deletes by extended grapheme cluster; Firefox by code point.
- [codemirror/dev #516](https://github.com/codemirror/dev/issues/516), [alacritty #5857](https://github.com/alacritty/alacritty/issues/5857) — real-world emoji-fragment deletion cases.
- [UTF-8 and Unicode FAQ for Unix/Linux (Kuhn)](https://www.cl.cam.ac.uk/~mgk25/unicode.html) and [Red Hat bug 142265](https://bugzilla.redhat.com/show_bug.cgi?id=142265) — terminal Backspace/DEL vs multibyte UTF-8; readline multibyte support from bash 2.05b / readline 4.3; byte- vs character-oriented deletion.
- [Unicode mailing list: "Grapheme clusters and backspace"](https://corp.unicode.org/pipermail/unicode/2019-October/008334.html) — grapheme cluster is the intended backspace unit; implementations vary.
