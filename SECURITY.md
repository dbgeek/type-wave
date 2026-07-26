# Security Policy

type-wave is an experimental research project. It handles sensitive material on
your Mac: your OpenAI API key (stored in the macOS login keychain) and live
microphone audio. Security reports are taken seriously even though the project
is provided as-is with no support guarantee.

## Reporting a vulnerability

**Please report vulnerabilities privately — do not open a public issue.**

Use GitHub's private reporting: open the **Security** tab and click **Report a
vulnerability** to file a private security advisory. This keeps the details out
of the public tracker until a fix is available.

If you cannot use GitHub's private reporting, email **me@ba78.me** instead.

Please include, where possible:

- The type-wave version or commit you are running.
- A description of the issue and its impact (for example: API-key or audio
  exposure, or insertion into an unintended target).
- Steps to reproduce.

## What to expect

This is a single-maintainer project with no SLA. Reports are handled on a
best-effort basis, so you may not receive an immediate response. There is no bug
bounty. Fixes land on `main`; there are no separately maintained release
branches.

## Scope

In scope: the type-wave daemon and helper in this repository — API-key handling,
keychain access, audio capture, network transport to the transcription backend,
and text insertion.

Out of scope: vulnerabilities in third-party dependencies (please report those
upstream), and issues that require an already-compromised machine or physical
access to the Mac running type-wave.

## Accepted limitations

These are known residuals: things a security review found, that were looked at and
deliberately not changed, and that are written down here rather than left for you to
discover. Each one names what it costs you and what you can do about it. If you can show
one is worse than described here, that is worth reporting.

### A pasted Insertion transits the general pasteboard

The default insertion method (`.insertion = .paste`) places the Final Transcript at your
cursor by saving your current clipboard text, writing the transcript to the **general
pasteboard**, posting ⌘V, and restoring the saved text about 300 ms later. The paste is the
point: it lands in one shot, carries arbitrary Unicode exactly, and works in terminals and
Electron apps where synthetic typing does not.

For that window the transcript is ordinary pasteboard content. Any process in your login
session can read it — no permission grant, no audit trail, and no trace afterwards.
type-wave marks its write `org.nspasteboard.TransientType` and `ConcealedType`, but those
markers are an **honor system**: well-behaved clipboard managers skip a write carrying
them, and nothing stops a reader that ignores them.

If your dictation is sensitive enough that the window matters, choose
`.insertion = .keystroke` (**Insertion ▸ keystroke** in the menu bar). That method posts
the text as synthetic Unicode keystrokes and never touches the pasteboard — at the fidelity
cost that keeps it from being the default. One caveat: a Final Transcript that is not valid
UTF-8 falls back to the paste path.

Two neighbouring facts, so they are not surprises. The saved clipboard is restored
best-effort as **plain text**, so rich or promised contents do not survive an Insertion.
And **Copy** in the Recent Insertions menu is a deliberate, ordinary, permanent clipboard
write — a copy you asked for should behave like one.

### Dictation is not blocked while a secure text field has focus

macOS exposes **Secure Event Input**: a flag an app raises while it owns a password field, and
the OS's strongest available signal that somebody in your login session is typing a secret.
type-wave does not stop dictating while it is held, and that is deliberate. The flag is
**session-wide** — Terminal's Secure Keyboard Entry, a password prompt in any app, the login
window: any one of them holds it for the whole session, and a hard gate would kill dictation
everywhere for as long as anything anywhere shows a password field. That cure is worse than the
condition, and it is not the condition you would expect either: while the flag is held the Talk
Key keeps working perfectly (modifier events still flow) while the recovery chord `⌃⌘⌫` never
reaches type-wave at all, because the WindowServer withholds key events from every event tap.

What type-wave does instead is refuse to **retain** what you said. An Utterance spoken while the
flag was held at either edge — when you pressed the Talk Key, or when you released it — is
marked, and for that Utterance:

- **Recent Insertions keeps the entry but stores none of its text.** The row reads
  `not retained … [secure input]`, and Reveal, Copy and Re-insert are shown disabled, because
  there is nothing behind them. The row's own length is not published either.
- **`⌃⌘⌫` still undoes it.** The entry carries how many characters to delete, never the
  characters, so the one recovery that matters here — taking a dictated password back out of the
  field — still works. Once the hold clears, at least: nothing can observe the chord while it is
  held.
- **The words stay out of the log**, even with `.log_transcripts = true` set for debugging. The
  log line says so rather than silently ignoring your opt-in.
- **A log line names the condition** at the Utterance, so this is not something you discover
  from an empty row.

What this does **not** do: the transient exposures are unchanged. The audio still goes to your
selected Transcription Backend — the OpenAI cloud Session when that is the one selected — and a
pasted Insertion still transits the general pasteboard for ~300 ms (above). Those mirror what
typing into the field would have risked anyway; the retained, re-openable, revealable ring entry
is the part with no non-dictation analogue, and it is the part refused.

### The daemon's log is not sanitised for terminal escape sequences

Strings the transcription endpoint chooses reach `~/Library/Logs/type-wave.log` verbatim:
an error `message`, an unrecognised item id. With `.log_transcripts = true` set while
debugging, raw event bytes do too. Nothing strips control characters, so a hostile or
compromised endpoint can place terminal escape sequences in a file you may open in a
terminal or attach to a bug report. Transcript text itself is redacted by default — the log
records that an Utterance resolved and how large it was, never the words.

### The installed binaries do not use the hardened runtime

`packaging/install.sh` signs the daemon and the Whisper Helper with your local signing
identity and deliberately without `--options runtime`: that signature exists to give the
pair a stable TCC identity, not to harden the process. The consequence is that macOS does
not block library injection into a process holding Microphone and Input Monitoring grants,
so code already running as you could use it to observe dictation. That overlaps the
already-compromised-machine case this policy puts out of scope, but the mitigation is real
and type-wave has not taken it.
