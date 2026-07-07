# CoreAudio Capture in pure Zig — research crib sheet for type-wave

Researched 2026-07-07 against primary sources: the macOS SDK headers **on this machine** (the
nix `apple-sdk-14.4` that `xcrun --show-sdk-path` resolves to — all header quotes below are
verbatim from those files), Apple developer documentation (TN2091, Core Audio Overview, Audio
Queue Services Programming Guide, developer forums), and real-world implementations (SDL2's
CoreAudio backend) for cross-checking only — plus **empirical compile-and-run probes built with
the flake's Zig (`0.17.0-dev.1267+300116b02`) on this macOS 26.5.1 machine**. Nothing here ever
opened the microphone: anything that would start capture (and hence trigger a TCC prompt) was
compiled but deliberately not run, and is marked as such. Target format comes from the companion
crib sheet [openai-realtime-transcription.md](./openai-realtime-transcription.md) §3; toolchain
context from [zig-websocket-tls.md](./zig-websocket-tls.md) §9.

## Summary table

| Question | Answer | Evidence |
|---|---|---|
| Chosen API | **AudioQueue** (`AudioQueueNewInput`, AudioToolbox) — plain C function-pointer callback, converts to the target format for you, not deprecated | §2, §3 |
| Ask for 24 kHz mono s16le directly? | **Yes** — the queue owns an internal AudioConverter (incl. sample-rate conversion); `AudioQueueNewInput` with exactly that ASBD returned `noErr` here | ran it (§6.1); §3 |
| Explicit AudioConverter needed? | No for plan A. Fallback: capture at device rate + `AudioConverterFillComplexBuffer` (`AudioConverterNew` for 48k/f32/2ch → 24k/s16/1ch also ran fine) | §3, §6.1 |
| AUHAL? | Lower latency but **cannot resample input** (TN2091) → needs converter + ring buffer + realtime-safe callback; overkill for dictation. Kept as fallback | §2.2 |
| VoiceProcessingIO | Optional AEC/AGC variant (`'vpio'`); AGC "on by default" could help whisper-quiet speech, but it processes the signal — treat as an A/B experiment, not plan A | §2.3 |
| Buffer sizing | 3 buffers × 50 ms = **2400 bytes** each (24 kHz × 2 B); 50 ms callback cadence maps 1:1 onto the OpenAI append-chunk guidance | §4 |
| Capture-side latency | ~50–70 ms worst case for the *last* byte of a chunk (buffer duration + device IO buffer + safety offset); pipelined, so irrelevant against network latency. Not measured | §4 |
| TCC: who is prompted (CLI from terminal) | **The terminal app** (responsible process), not the binary; binary needs no Info.plist in that case | §5.1 |
| TCC: prompt trigger | `AudioQueueNewInput` already fires a tccd **preflight** (observed in logs here, no UI); the real prompt comes on first actual input IO (`AudioQueueStart`) — read, not provoked | §5.2 |
| TCC: denied → | **Silence (zeros), no error** per multiple sources — must be detected client-side. Read, not verified | §5.3 |
| Embedded Info.plist | Zig `linksection("__TEXT,__info_plist")` works; `otool -P` shows it; needs explicit `codesign -f -s -` for the signature to bind it (zig's linker-signed adhoc sig leaves it "not bound") | ran it (§5.4) |
| Reset for testing | `tccutil reset Microphone` (optionally `tccutil reset Microphone com.apple.Terminal`) | `man tccutil` on this machine |
| Zig ↔ C bridge | **`@cImport` no longer exists on the flake's 0.17-dev** ("invalid builtin function"). Use extern declarations (ran) or `zig translate-c` (ran) | §7 |
| Link flags | `-lc -framework AudioToolbox -F"$SDK/System/Library/Frameworks"` — sysroot not required for the extern-decl path | ran it (§7.2) |

## 1. Target format, as an AudioStreamBasicDescription

The wire format (companion sheet §3) is 16-bit signed integer PCM, 24 000 Hz, mono,
little-endian. `AudioStreamBasicDescription` is defined in
`CoreAudioTypes.framework/Headers/CoreAudioBaseTypes.h` (fields: `mSampleRate: Float64`,
`mFormatID`, `mFormatFlags`, `mBytesPerPacket`, `mFramesPerPacket`, `mBytesPerFrame`,
`mChannelsPerFrame`, `mBitsPerChannel`, `mReserved`). The exact ASBD:

| field | value | why |
|---|---|---|
| `mSampleRate` | `24000` | only legal PCM rate for the API |
| `mFormatID` | `kAudioFormatLinearPCM` (`'lpcm'` = `0x6C70636D`) | raw PCM |
| `mFormatFlags` | `kAudioFormatFlagIsSignedInteger \| kAudioFormatFlagIsPacked` (= `0x4 \| 0x8 = 0xC`) | s16; **not** setting `kAudioFormatFlagIsBigEndian` (`0x2`) makes it little-endian, which is also native on arm64 |
| `mBytesPerPacket` / `mBytesPerFrame` | `2` | 1 ch × 16 bit |
| `mFramesPerPacket` | `1` | uncompressed ⇒ 1 frame per packet (CoreAudioBaseTypes.h: "In uncompressed audio, a Packet is one frame") |
| `mChannelsPerFrame` | `1` | mono |
| `mBitsPerChannel` | `16` | s16 |

Flag values verified in the header (`kAudioFormatFlagIsFloat = 1U<<0`, `IsBigEndian = 1U<<1`,
`IsSignedInteger = 1U<<2`, `IsPacked = 1U<<3`, `IsNonInterleaved = 1U<<5`). Buffers from an input
queue in this format are byte-for-byte what `input_audio_buffer.append` wants (after base64).

## 2. Which C API

Candidates, all callable from plain C (and therefore Zig `extern fn`) — no ObjC runtime needed:

### 2.1 AudioQueue (AudioToolbox) — **picked**

`AudioQueueNewInput` (macOS 10.5+, `API_AVAILABLE`, **no deprecation** in the 14.4 SDK header):

```c
extern OSStatus
AudioQueueNewInput(  const AudioStreamBasicDescription *inFormat,
                     AudioQueueInputCallback         inCallbackProc,
                     void * __nullable               inUserData,
                     CFRunLoopRef __nullable         inCallbackRunLoop,
                     CFStringRef __nullable          inCallbackRunLoopMode,
                     UInt32                          inFlags,          // "Reserved... Pass 0"
                     AudioQueueRef __nullable * __nonnull outAQ);
```

(`AudioToolbox.framework/Headers/AudioQueue.h`.) Why it fits:

- **Callback model:** `AudioQueueInputCallback` is a **plain C function pointer** (the
  block-based variant `AudioQueueNewInputWithDispatchQueue` exists but is not needed — no
  blocks-ABI problem, unlike Network.framework in the websocket research §6.2).
- **Callback thread:** pass `NULL` for the run loop and "the callback is called on one of the
  audio queue's internal threads" (AudioQueue.h, `inCallbackRunLoop` doc). The Audio Queue guide
  is explicit that this thread is meant for ordinary work: "Typically, your callback should write
  the audio queue buffer's data to a file or other buffer, and then re-queue the audio queue
  buffer" (AudioQueue.h, `AudioQueueInputCallback` doc). I.e. it is *not* the HAL realtime IO
  thread — pushing into a ring buffer (or even doing the base64/JSON work) there is acceptable.
- **Format conversion built in** — see §3. This is the decisive difference vs AUHAL.
- **Cadence:** "Your callback is invoked each time the recording audio queue has filled a buffer
  with input data" (AudioQueue.h) — so callback rate = our chosen buffer duration (§4).
- **Device handling:** defaults to the default input device; `kAudioQueueProperty_CurrentDevice`
  (r/w, device UID) selects another, and "If the audio queue is tracking the default system
  device and the device changes, it will generate a property changed notification" (AudioQueue.h)
  — AirPods arriving mid-session is handled for us.
- **Overrun semantics:** if our callback stalls and no buffer is enqueued,
  `kAudioQueueErr_RecordUnderrun` (-66668): "During recording, data was lost because there was no
  enqueued buffer into which to store it" (AudioQueue.h). Detectable, non-fatal.
- Bonus for later UI: `kAudioQueueProperty_EnableLevelMetering` /
  `kAudioQueueProperty_CurrentLevelMeterDB` give per-channel input levels for free.

Deprecation status: the Carbon-era **Component Manager** route into audio units is what's
obsolete, not AudioToolbox: AudioComponent.h — "in order to provide an API that will be supported
going forward from macOS 10.6 and iOS 2.0, it is advised that applications use the Audio
Component APIs" (i.e. `AudioComponentFindNext`/`AudioComponentInstanceNew`, not
`FindNextComponent`/`OpenAComponent`). AUGraph.h deprecates itself "in favor of AVAudioEngine".
AudioQueue.h and the AudioComponent/AUHAL APIs carry plain `API_AVAILABLE` with no deprecation.
AVAudioEngine itself is ObjC-only, hence out per the constraint.

### 2.2 AUHAL (`kAudioUnitSubType_HALOutput`, `'ahal'`) — fallback

"The audio unit that interfaces to any audio device … Bus 0 is used to send audio output to the
device; bus 1 is used to receive audio input" (AUComponent.h). Setup is the classic TN2091
sequence: `kAudioOutputUnitProperty_EnableIO` (=2003) — enable on `{scope input, element 1}`,
disable on `{scope output, element 0}` ("Output units default to output-only operation",
AudioUnitProperties.h) → set `kAudioOutputUnitProperty_CurrentDevice` (=2000, an `AudioObjectID`)
→ set `kAudioUnitProperty_StreamFormat` on the *output scope of element 1* → register
`kAudioOutputUnitProperty_SetInputCallback` (=2005) — whose callback "will always receive a NULL
AudioBufferList in ioData. You must call AudioUnitRender in order to obtain the audio"
(AudioUnitProperties.h) → `AudioOutputUnitStart` (AudioOutputUnit.h).

Trade-offs vs AudioQueue:

- **Latency:** the render callback fires once per device IO cycle (default ~512 frames ≈ 10.7 ms
  @48 kHz, tunable via `kAudioDevicePropertyBufferFrameSize`) — the lowest-latency capture path
  short of a raw HAL IOProc. Apple's Core Audio Overview positions audio units as the
  low-latency mechanism vs the "straightforward, low overhead" queue APIs.
- **No input resampling:** TN2091 (verbatim): "the device's sample rate should match the desired
  sample rate. If sample rate conversion is needed, it can be accomplished by buffering the input
  and converting the data on a separate thread with another AudioConverter." Its internal
  converter "can handle any *simple* conversion … a client can specify ANY variant of the PCM
  formats" — i.e. int↔float, bit depth, interleaving, channel count (via
  `kAudioOutputUnitProperty_ChannelMap`), **but not rate**. So AUHAL means: callback on a
  time-constrained thread → ring buffer → converter thread → websocket. Three moving parts
  AudioQueue gives us for free.
- The callback runs on the HAL IO thread: no allocation, no locks, no syscalls — a realtime
  constraint type-wave doesn't otherwise need. (`kAudioOutputUnitProperty_OSWorkgroup` even
  carries `__SWIFT_UNAVAILABLE_MSG("Swift is not supported for use with audio realtime
  threads")` — Apple's own hint about how touchy this thread is.)

For a dictation stream whose downstream is a network round-trip, ~50 ms of queue-side buffering
is noise; the AUHAL complexity buys nothing. **Fallback only** (e.g. if AudioQueue's converter
quality/latency disappoints).

The raw-HAL route (`AudioDeviceCreateIOProcID` from CoreAudio/AudioHardware.h) is strictly more
work than AUHAL for the same result; not considered further.

### 2.3 `kAudioUnitSubType_VoiceProcessingIO` (`'vpio'`) — noted, not picked

"This audio unit can do input as well as output … does signal processing on the incoming audio
(taking out any of the audio that is played from the device at a given time from the incoming
audio)" (AUComponent.h) — i.e. echo cancellation; available on macOS. Knobs
(AudioUnitProperties.h): `kAUVoiceIOProperty_BypassVoiceProcessing` (=2100),
`kAUVoiceIOProperty_VoiceProcessingEnableAGC` (=2101) — "Enable automatic gain control on the
processed microphone uplink signal. **On by default**", `kAUVoiceIOProperty_MuteOutput` (=2104).

Relevance to whisper-quiet speech: AGC would boost a quiet voice before it hits the model, and
AEC removes speaker bleed if the user dictates over playing audio. But it's an opinionated DSP
chain (Voice Isolation may engage), same AUHAL-style integration cost, and the OpenAI session
already has server-side `noise_reduction: near_field`. Verdict: an A/B experiment for the
prototype *if* quiet-speech accuracy disappoints — one line on the map, no more.

## 3. Format conversion: who resamples?

**Plan A: ask the queue for the target format directly.** Evidence the queue converts (header +
docs + cross-check; the actual audio path is read-not-verified since running capture was off
limits here):

- AudioQueue.h front matter: audio queues "Employ codecs, as necessary, for compressed audio
  formats" and the `inFormat` parameter is "the format of the audio data **to be recorded**", not
  the device format. The queue demonstrably owns an internal AudioConverter:
  `kAudioQueueProperty_ConverterError` — "the most recent error (if any) encountered by the
  queue's internal encoding/decoding process"; `kAudioQueueErr_PrimeTimedOut` — "During Prime,
  the queue's AudioConverter failed to convert the requested number of sample frames" (both
  AudioQueue.h). `kAudioQueueDeviceProperty_SampleRate` exists as a separate *read-only* device
  property — the device rate and the queue format are independent by design.
- Core Audio Overview (Core Audio Essentials): "When you use Audio Queue Services … **you get the
  appropriate converter automatically.**"
- Empirical (this machine): `AudioQueueNewInput` with the §1 ASBD (24 kHz mono s16) returned
  `noErr` — the format was accepted at creation (§6.1). Not proof the samples come out right, but
  the API contract was honored.
- Cross-check: SDL2's CoreAudio backend builds the ASBD from the *application's* requested spec
  and passes it straight to `AudioQueueNewInput`
  ([SDL_coreaudio.m](https://github.com/libsdl-org/SDL/blob/SDL2/src/audio/coreaudio/SDL_coreaudio.m),
  `prepare_audioqueue`) with no backend resampler — this is exactly how whisper.cpp's `stream`
  example gets 16 kHz mono s16 capture on macOS today.

**Fallback: explicit AudioConverter** (AudioToolbox/AudioConverter.h), if plan A's resampler
quality or behavior disappoints: capture at the device rate (query
`kAudioQueueDeviceProperty_SampleRate` or HAL `kAudioDevicePropertyNominalSampleRate`), then
convert. Key facts from the header:

- `AudioConverterNew(inSourceFormat, inDestinationFormat, outAudioConverter)` supports, for
  PCM-to-PCM: "addition and removal of channels … **sample rate conversion** …
  interleaving/deinterleaving … 8/16/24/32-bit integer … 32 and 64-bit float" (doc comment).
  Creating a 48 kHz/float32/stereo → 24 kHz/s16/mono converter succeeded here (§6.1).
- Rate conversion **must** go through the pull-model API: `AudioConverterConvertBuffer` carries
  the warning "this function will fail for any conversion where there is a variable relationship
  between the input and output data buffer sizes. This includes sample rate conversions … use
  AudioConverterFillComplexBuffer". `AudioConverterFillComplexBuffer` pulls input via an
  `AudioConverterComplexInputDataProc` you supply.
- Quality knobs: `kAudioConverterSampleRateConverterComplexity` (`'line'`/`'norm'` default/
  `'bats'` mastering/`'minp'` minimum-phase) and `kAudioConverterSampleRateConverterQuality`.
- Rate converters have priming latency (`AudioConverterPrimeInfo`, `leadingFrames`) — a first
  `FillComplexBuffer` call requests extra input. Only relevant to the fallback path.

**Simplest correct pipeline** is therefore plan A: one `AudioQueueNewInput` at the wire format;
the queue's converter does 48 k→24 k, float→s16, and (if the mic is stereo) the channel
reduction; buffers arrive network-ready.

## 4. Buffer sizing and latency

Mechanism: in AudioQueue you don't set a device buffer size — you choose the **byte size of the
queue buffers** you allocate (`AudioQueueAllocateBuffer(inAQ, inBufferByteSize, &buf)`); a filled
buffer = one callback. Apple's Recording Audio guide uses `kNumberBuffers = 3` and derives byte
size from a duration ("One half second, as set here, is typically a good choice" — for *file*
recording; interactive streaming wants much less).

For type-wave: the companion sheet (§2) recommends streaming ~50 ms appends (OpenAI's own example
uses `CHUNK_LENGTH_S = 0.05`). Choosing a **50 ms buffer duration makes the capture cadence equal
the append cadence** — no reblocking layer:

> 24 000 Hz × 2 bytes × 0.050 s = **2400 bytes per buffer**, × **3 buffers** in flight.

Latency accounting (read from headers, not measured):

- Queue buffer: data for a given instant is delivered when its buffer fills → up to 50 ms.
- Device IO buffer beneath the queue: `kAudioDevicePropertyBufferFrameSize` — "A UInt32 whose
  value indicates the number of frames in the IO buffers" (AudioHardware.h); macOS default is 512
  frames ≈ 10.7 ms @48 kHz (legal range per-device via `kAudioDevicePropertyBufferFrameSizeRange`).
- Device+stream latency and safety offset: `kAudioDevicePropertyLatency` ("number of frames of
  latency in the AudioDevice … AudioStreams may have additional latency") and
  `kAudioDevicePropertySafetyOffset` (AudioHardwareBase.h) — typically a few ms for built-in mics.

So worst case ~60–70 ms from sound to callback, and because chunks are pipelined while the Talk
Key is held, this adds at most one chunk of delay to the *commit*, dwarfed by the network/model.
If lower feedback latency is ever wanted, drop to 20–25 ms buffers (960–1200 B) — the guide's
mechanism is the same; per-callback overhead is trivially small either way. Going below the
device IO buffer (~10 ms) buys nothing in this API.

## 5. TCC: microphone permission for a bare CLI binary

All of §5 is **read-not-verified** except where marked *ran*: this session never started capture,
and on this machine the responsible process already holds a mic grant (observed `authValue=1`
preflights, §5.2), so no prompt would have appeared anyway.

### 5.1 Which process is prompted

For a plain binary run from a terminal, **the terminal application is the "responsible process"
and it is what TCC prompts and records**: "If you run the executable from the terminal, then the
microphone access dialog is prompted for by the Terminal"
([Apple DevForums #109759](https://developer.apple.com/forums/thread/109759)). The user sees
"*Terminal* would like to access the microphone", and the TCC.db row is for the terminal's bundle
id. The binary itself needs no Info.plist in this configuration — which is exactly the ticket-#8
CLI-prototype situation.

The flip side: once type-wave is launched any other way (launchd agent, Finder, a hotkey daemon —
its real life as a background dictation tool), the binary is its **own** responsible process and
the usage-description rule applies: "in order to get the popup dialog asking for microphone
access, you must have the NSMicrophoneUsageDescription key in the Info.plist … If you run the app
itself (eg from the Finder) it crashes if you don't have NSMicrophoneUsageDescription" (same
thread). So the embedded-plist story (§5.4) is a requirement for the product, merely optional for
the prototype.

### 5.2 What triggers the prompt (and what was observed here)

There is no public **C** preflight/request API (the documented route,
`AVCaptureDevice requestAccessForMediaType:`, is ObjC). With CoreAudio C APIs the system handles
it implicitly: the real TCC access request — the one that can show UI — happens when the process
first performs input IO, i.e. at `AudioQueueStart` / `AudioOutputUnitStart` on an input-enabled
unit.

*Ran:* each `AudioQueueNewInput` call from the probes produced a tccd **preflight** request, no
UI: unified log shows `function=TCCAccessRequest, preflight=true …
service=kTCCServiceMicrophone`, answered `AUTHREQ_RESULT: … authValue=1` (already authorized for
this session's responsible process). So merely *creating* the queue pings TCC but does not
prompt; disposal before `Start` kept this session prompt-free as intended.

### 5.3 What denial looks like

Denied (or never-prompted-and-unauthorized) microphone access yields **silence, not an error**:
"the XCode debugger still allows the app to run but of course there is no access to the
microphone so only zeros are returned" (DevForums #109759); multiple TCC write-ups agree the
input callbacks either receive zeroed buffers or the IO never starts delivering data, with all
calls returning `noErr`. Consequences for type-wave: detect it (all-zero buffers for the first
~N callbacks after Start → surface "microphone access denied — System Settings → Privacy &
Security → Microphone") rather than waiting on a transcript that will never come.
`kAudioQueueErr_Permissions` (-66676, "You do not have the required permissions to call the
function", AudioQueue.h) exists but reports on macOS associate mic-TCC denial with silence, not
this code — which path actually fires is a prototype question.

Note for later hardening: if the binary is ever signed with **hardened runtime** (notarization),
mic access additionally requires the `com.apple.security.device.audio-input` entitlement at
signing time; the ad-hoc unhardened prototype doesn't need it.

### 5.4 Embedding Info.plist in a single-file Zig binary (*ran*)

The classic single-file-tool trick — an `__info_plist` section in `__TEXT` — works from pure Zig
without linker flags, via `linksection`:

```zig
const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleIdentifier</key>
    \\  <string>me.ba78.type-wave</string>
    \\  <key>CFBundleName</key>
    \\  <string>type-wave</string>
    \\  <key>NSMicrophoneUsageDescription</key>
    \\  <string>type-wave captures your voice while the Talk Key is held, to transcribe it.</string>
    \\</dict>
    \\</plist>
;
export const info_plist: [plist.len]u8 linksection("__TEXT,__info_plist") = plist.*;
```

Verified on this machine with the flake's Zig: `otool -P` prints the embedded plist back out.
One wrinkle found: Zig's linker ad-hoc signs the binary (`flags=0x20002(adhoc,linker-signed)`)
but that signature reports **`Info.plist=not bound`**; after an explicit re-sign —
`codesign -f -s - --identifier me.ba78.type-wave ./type-wave` — the signature shows
**`Info.plist entries=3`**, i.e. the plist is now sealed into the code signature (what TCC's
attribution machinery reads). Make the ad-hoc `codesign` a post-link step in build.zig when the
plist starts mattering. (The equivalent non-Zig spelling is `ld -sectcreate __TEXT __info_plist
Info.plist`.)

### 5.5 Resetting for testing

`man tccutil` (this machine): "reset — Reset all decisions for the specified service, causing
apps to prompt again the next time they access the service." So: `tccutil reset Microphone` (all
apps) or `tccutil reset Microphone com.apple.Terminal` (just the terminal that fronts the
prototype). Grants also appear/toggle under System Settings → Privacy & Security → Microphone.

## 6. Empirical results (what actually ran on this machine)

All probes in the session scratchpad; nothing added to the repo. Zig `0.17.0-dev.1267+300116b02`
(flake dev shell = PATH zig, confirmed identical). SDK: nix `apple-sdk-14.4` via
`xcrun --show-sdk-path`.

1. **Extern-declaration probe** (no `@cImport`; hand-written `AudioStreamBasicDescription`,
   `AudioQueueNewInput`, `AudioQueueDispose`, `AudioConverterNew/Dispose` extern decls):
   compiled with `zig build-exe probe.zig -lc -framework AudioToolbox
   -F"$SDK/System/Library/Frameworks"` and ran:
   `AudioQueueNewInput(24 kHz mono s16) → 0`, `AudioQueueDispose → 0`,
   `AudioConverterNew(48 kHz stereo f32 → 24 kHz mono s16) → 0`, `AudioConverterDispose → 0`. ✅
2. **`@cImport` fails on this nightly**: `error: invalid builtin function: '@cImport'` — removed
   from the language on 0.17-dev (translate-c is now a separate/build-system step). ✅ ran (the
   failure is the datum).
3. **`zig translate-c` path works**: `zig translate-c atb.h …` over
   `#include <AudioToolbox/AudioQueue.h>` + `AudioConverter.h` produced a 14,912-line `.zig`
   binding; a probe `@import`ing it compiled and ran (`AudioQueueNewInput → 0`). ✅
4. **Full capture sketch (§8) compiles** — allocate 3×2400 B buffers, enqueue, Start/Stop,
   callback copying into a sink — but was **deliberately not run** (running `AudioQueueStart`
   is the TCC-visible act). ✅ compiled only.
5. **Info.plist embed** (§5.4): built, `otool -P` round-trip, codesign binding before/after. ✅
6. **TCC log observation** (§5.2): three probe runs ⇒ three `preflight=true` mic requests in
   `log show --predicate 'subsystem == "com.apple.TCC"'`, each answered `authValue=1`, zero
   prompts. ✅ observed.
7. **Link-flag minimum**: dropping `-F"$SDK/System/Library/Frameworks"` fails with `unable to
   find framework "AudioToolbox"`; `--sysroot` is *not* needed for the extern-decl path (it is
   for translate-c, which reads headers). Only `-framework AudioToolbox` was needed — its
   dependencies resolve transitively. ✅
8. **Zig std churn bites here too** (reinforces zig-websocket-tls.md §9): on this nightly
   `std.Thread.sleep` is gone (sleeping now goes through `std.Io`), `std.fs.File` moved to
   `std.Io.File`. The sketch uses libc `sleep()` to stay std-API-neutral. ✅ (compile errors
   observed, then fixed.)

**Not verified anywhere in this research:** actual audio flowing (sample values, resampler
quality, callback cadence under load), the TCC prompt appearing, denial behavior. Those are the
prototype's first tasks (see Open questions).

## 7. Zig integration notes

- **Bindings approach — recommend extern declarations.** The API surface type-wave needs is ~7
  functions, 2 structs, and a handful of constants (see sketch). Hand-declared externs are
  `build.zig`-trivial, survive `zig translate-c` output churn, and compile fast. Keep
  translate-c (`zig translate-c` on a one-line header, checked in or generated by a build step)
  as the escape hatch if the surface grows (e.g. AUHAL fallback, HAL device enumeration).
- **Frameworks:** everything in §2/§3 — AudioQueue, AudioConverter, AudioComponent/AudioUnit —
  lives in **AudioToolbox** (`module.modulemap`: the AudioUnit "framework" headers are shims that
  include AudioToolbox's). Raw HAL calls (device enumeration, `kAudioDevicePropertyBufferFrameSize`)
  would add `-framework CoreAudio`. The queue path needs AudioToolbox only (verified, §6.7).
- **build.zig shape:** `exe.linkLibC(); exe.linkFramework("AudioToolbox");` plus
  `exe.root_module.addFrameworkPath(.{ .cwd_relative = sdk ++ "/System/Library/Frameworks" })`
  where `sdk` comes from `xcrun --show-sdk-path` (or `std.zig.system.darwin.getSdk`). In the nix
  dev shell that resolves to the pinned `apple-sdk-14.4` — deterministic. (Exact build.zig API
  names not compile-verified; the CLI equivalents are, §6.1.)
- **Callback conventions:** `callconv(.c)` on the input callback; note the AudioQueue.h
  `Boolean` parameters (`inImmediate`) are 1-byte (`u8` in Zig).

## 8. Recommendation and sketch

**Pick: AudioQueue.** Create one input queue directly in the wire format (24 kHz mono s16le);
let its internal converter own resampling/downmix/f32→s16; 3 × 50 ms (2400 B) buffers; callback
(queue-internal thread) pushes bytes into an SPSC ring; the Transcription-Session writer thread
drains the ring, base64s, and sends `input_audio_buffer.append` under the websocket write mutex
(zig-websocket-tls.md §3.4). Talk Key press → `AudioQueueStart`; release → `AudioQueueStop(true)`
then `input_audio_buffer.commit`. Keep the queue object alive across Utterances (create once,
Start/Stop per Utterance) — `AudioQueuePause`/`AudioQueueStart` is the cheaper cycle if Stop
proves slow; measure in the prototype.

Pipeline: `AudioQueue callback (AQ thread) → SPSC ring buffer → websocket writer thread →
input_audio_buffer.append`. The ring absorbs network stalls so the queue never underruns
(`kAudioQueueErr_RecordUnderrun` = data loss); size it generously (a few seconds ≈ 100–200 KiB).

Fallbacks, in order: AudioQueue at device rate + explicit `AudioConverterFillComplexBuffer`
(if the direct-format capture misbehaves); AUHAL + AudioConverter (if queue latency ever
matters); VoiceProcessingIO (quiet-speech A/B only).

The sketch below **compiled cleanly with the flake's Zig on this machine (§6.4) but was not
run** — the callback body and Start/Stop flow are unexecuted. The create/dispose calls and the
ASBD are the exact code that *did* run in §6.1.

```zig
// zig build-exe capture.zig -lc -framework AudioToolbox -F"$(xcrun --show-sdk-path)/System/Library/Frameworks"
const std = @import("std");

const OSStatus = i32;

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

pub const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
pub const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;

const AudioQueueRef = ?*opaque {};
const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: *anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque, // unused for LPCM input
    mPacketDescriptionCount: u32,
};
const AudioQueueBufferRef = ?*AudioQueueBuffer;
const AudioTimeStamp = opaque {}; // passed through, never dereferenced here
const AudioStreamPacketDescription = extern struct {
    mStartOffset: i64,
    mVariableFramesInPacket: u32,
    mDataByteSize: u32,
};

const AudioQueueInputCallback = *const fn (
    ?*anyopaque, AudioQueueRef, AudioQueueBufferRef,
    *const AudioTimeStamp, u32, ?[*]const AudioStreamPacketDescription,
) callconv(.c) void;

extern "c" fn AudioQueueNewInput(
    inFormat: *const AudioStreamBasicDescription,
    inCallbackProc: AudioQueueInputCallback,
    inUserData: ?*anyopaque,
    inCallbackRunLoop: ?*anyopaque, // CFRunLoopRef; null => queue-internal thread
    inCallbackRunLoopMode: ?*anyopaque, // CFStringRef
    inFlags: u32,
    outAQ: *AudioQueueRef,
) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(inAQ: AudioQueueRef, inBufferByteSize: u32, outBuffer: *AudioQueueBufferRef) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(inAQ: AudioQueueRef, inBuffer: AudioQueueBufferRef, inNumPacketDescs: u32, inPacketDescs: ?[*]const AudioStreamPacketDescription) OSStatus;
extern "c" fn AudioQueueStart(inAQ: AudioQueueRef, inStartTime: ?*const AudioTimeStamp) OSStatus;
extern "c" fn AudioQueueStop(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
extern "c" fn AudioQueueDispose(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;

/// 24 kHz * 2 B * 50 ms = 2400 bytes: one buffer == one append-event's worth.
const buffer_bytes: u32 = 2400;
const buffer_count = 3;

const Capture = struct {
    queue: AudioQueueRef = null,
    sink: *std.Io.Writer, // real impl: SPSC ring drained by the websocket writer thread

    /// Runs on the audio queue's internal thread (run loop arg = null).
    fn onBuffer(
        user_data: ?*anyopaque,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        start_time: *const AudioTimeStamp,
        num_packets: u32, // == frame count for LPCM (mFramesPerPacket = 1)
        packet_descs: ?[*]const AudioStreamPacketDescription, // always null for LPCM input
    ) callconv(.c) void {
        _ = start_time;
        _ = num_packets;
        _ = packet_descs;
        const self: *Capture = @ptrCast(@alignCast(user_data.?));
        const buf = buffer.?;
        const bytes: [*]const u8 = @ptrCast(buf.mAudioData);
        self.sink.writeAll(bytes[0..buf.mAudioDataByteSize]) catch {}; // ring push; drop on overflow
        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null); // hand the buffer back
    }

    pub fn start(self: *Capture) !void {
        const format = AudioStreamBasicDescription{
            .mSampleRate = 24000, // wire rate; the queue's converter resamples from the device rate
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, // s16le
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
        };
        if (AudioQueueNewInput(&format, onBuffer, self, null, null, 0, &self.queue) != 0)
            return error.AudioQueueNewInput;
        errdefer _ = AudioQueueDispose(self.queue, 1);
        for (0..buffer_count) |_| {
            var buf: AudioQueueBufferRef = null;
            if (AudioQueueAllocateBuffer(self.queue, buffer_bytes, &buf) != 0)
                return error.AudioQueueAllocateBuffer;
            if (AudioQueueEnqueueBuffer(self.queue, buf, 0, null) != 0)
                return error.AudioQueueEnqueueBuffer;
        }
        // First real input IO on a fresh TCC state => microphone prompt for the
        // responsible process (the terminal, for the CLI prototype). §5
        if (AudioQueueStart(self.queue, null) != 0) return error.AudioQueueStart;
    }

    pub fn stop(self: *Capture) void {
        _ = AudioQueueStop(self.queue, 1); // sync; pending callbacks fire during this call
        // keep the queue for the next Utterance; AudioQueueDispose(self.queue, 1) on shutdown
    }
};
```

## Open questions for the prototype (ticket #8)

1. **Does 24 kHz direct capture sound right?** Verify the queue's resampler end-to-end: record a
   known tone/utterance at 24 kHz mono s16 while the device runs 48 kHz, inspect for pitch shift,
   aliasing, glitches; compare against the explicit-AudioConverter fallback. (The API accepted
   the format; the audio path itself never ran here.)
2. **Callback cadence & underruns in anger** — confirm ~50 ms cadence, and how
   `kAudioQueueErr_RecordUnderrun` (or silent gap) manifests when the sink stalls; pick the ring
   size accordingly.
3. **TCC prompt & denial, observed for real**: does the prompt fire at `AudioQueueStart` (and
   not at `AudioQueueNewInput`, which only preflights)? On denial, is it zeros-forever with
   `noErr`, or does `kAudioQueueErr_Permissions`/`kAudioQueueErr_CannotStart` surface? Build the
   all-zero-buffer detector either way. Test matrix: terminal-granted / terminal-denied /
   `tccutil reset Microphone` mid-run / launched via launchd with the embedded plist (§5.4).
4. **Start/stop latency per Utterance**: is `AudioQueueStart` fast enough on Talk-Key press
   (first buffer within ~100 ms), or should the queue run continuously (Pause/Start, or run
   always and gate in software)? Also whether `kAudioQueueErr_CannotStartYet` (device
   reconfiguring — e.g. AirPods just connected) needs the sleep-retry the header recommends.
5. **Stop-vs-commit ordering**: `AudioQueueStop(true)` invokes remaining callbacks "during the
   stopping" (header) — confirm the last partial buffer arrives before the websocket `commit` is
   sent, or flush explicitly.
6. **Device switch mid-Utterance** (default-device change notification via
   `kAudioQueueProperty_CurrentDevice` listener): does capture glitch, and does the sample-rate
   change confuse the converter?
7. **Quiet-speech level**: are raw capture levels too low for good transcription? If so, A/B:
   simple software gain in the callback vs `VoiceProcessingIO` AGC (§2.3) vs relying on the
   server's `noise_reduction`.
8. **build.zig framework wiring** exactly as sketched in §7 (the flag set is CLI-verified; the
   build-system API names are not), plus the post-link `codesign` step once the embedded plist
   matters.
