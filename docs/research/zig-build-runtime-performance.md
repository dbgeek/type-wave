# Zig build configuration for runtime performance — research for type-wave

Researched 2026-07-09 against primary sources: the **std lib shipped with the pinned nightly**
(`0.17.0-dev.1267+300116b02`, read directly from the flake's Zig at
`/nix/store/k19g5bxkzc20r5958n01mzjmafqmn9jq-zig-0.17.0-dev.1267+300116b02/lib/std/…` — cited
below as `lib/std/…`), the **compiler source at the exact nightly commit**
(`ziglang/zig@300116b02`, cited as `src/…` with GitHub links), the **langref shipped with this
nightly** (`doc/langref.html`), Apple/LLVM docs, and **empirical builds of this repo** with the
flake's Zig on this Apple M1 machine. Evidence tags: **[src]** = read in this nightly's
source, **[ran]** = verified empirically here, **[docs]** = official docs, **[inf]** =
inference.

The question: `build.zig` currently defaults to `.ReleaseFast`, uses `standardTargetOptions`,
sets `link_libc = true`, and touches no other knob (strip/lto/single_threaded/…). Is anything
left on the table for **runtime** performance of the installed daemon?

**Bottom line: no.** Every runtime-relevant knob is either already at its optimum by default
(LLVM backend, `-O3`-equivalent codegen, hardware AES/SHA at the CPU baseline, MachO
dead-strip on), or is unavailable on aarch64-macos with this toolchain (LTO, PGO, BOLT), or
would be wrong for this daemon (`single_threaded`, `omit_frame_pointer`). The remaining
milliseconds live in the code, not the build line — consistent with the delay-tier work
([delay-tier-benchmark.md](./delay-tier-benchmark.md)).

## Summary table

| Knob | Default in this nightly (ReleaseFast, aarch64-macos) | Change? | Evidence |
|---|---|---|---|
| Optimize mode | `.ReleaseFast` (repo default); all release modes = LLVM `Aggressive` (-O3-class); Fast vs Safe differs only in safety checks | **No** — keep | §1 [src][docs] |
| CPU | plain `zig build` = **native host CPU** (M1 → `apple_a14` model); explicit `-Dtarget=aarch64-macos` = `apple_m1` baseline; both include AES/SHA2/SHA3/NEON | **No** | §2 [src][ran] |
| LTO | `lto: ?std.zig.LtoMode` exists but **hard-errors on MachO** (`LTO requires using LLD`) | **Impossible** | §3 [src][ran] |
| Backend | LLVM backend + Zig's self-hosted MachO linker, all modes | **No** | §4 [src] |
| `strip` | `false` in ReleaseFast; saves ~67 KB (~4.6%), zero runtime effect | Optional, not perf | §5.1 [src][ran] |
| `omit_frame_pointer` | `false` in ReleaseFast | **No — keep FP** (Apple ABI, Instruments) | §5.2 [src][docs] |
| `single_threaded` | `false` | **Must stay false** (daemon spawns ≥6 threads) | §5.3 [src][ran] |
| `unwind_tables` | always `.async` on Darwin | No | §5.4 [src] |
| `error_tracing` | `false` in all release modes | Already off | §5.5 [src] |
| `sanitize_thread` | `false` | Dev-only tool | §5.6 [src] |
| dead-strip (`gc_sections`) | **already on** for non-Debug on MachO | No | §5.7 [src] |
| `bundle_compiler_rt` | bundled for exes (required) | No | §5.9 [src] |
| `link_libc = true` | macOS **requires** libSystem; no perf cost | No | §6 [src] |
| PGO / BOLT | no PGO flags exist; BOLT is ELF-only | **Unavailable** | §7 [ran][docs] |
| `-fincremental` | build-speed feature | **Not runtime-relevant** | §8 [src] |

## 1. Optimize modes: what actually differs

The langref shipped with this nightly (`doc/langref.html`, "Build Mode") defines the four
modes: ReleaseFast = "Optimizations on and safety off", ReleaseSafe = "Optimizations on and
safety on", ReleaseSmall = "Size optimizations on and safety off". **[docs]**

What that means concretely in this nightly's compiler:

- **LLVM optimization level is identical for all three release modes.** The codegen maps
  `optimize_mode == .Debug` → `CodeGenOptLevel.None`, *everything else* → `.Aggressive`
  ([src/codegen/llvm.zig#L1029-L1032](https://github.com/ziglang/zig/blob/300116b02/src/codegen/llvm.zig#L1029-L1032)).
  ReleaseSmall additionally stamps every function with the `minsize` + `optsize` LLVM
  attributes ([src/codegen/llvm.zig#L2799-L2802](https://github.com/ziglang/zig/blob/300116b02/src/codegen/llvm.zig#L2799-L2802)). **[src]**
- **Safety checks** are the Fast↔Safe axis: `is_safe_mode = switch (optimize_mode) { .Debug,
  .ReleaseSafe => true, .ReleaseFast, .ReleaseSmall => false }`
  ([src/Module.zig#L255-L258](https://github.com/ziglang/zig/blob/300116b02/src/Module.zig#L255-L258)).
  So ReleaseSafe is the same `-O3`-class codegen plus check branches — not a lower optimizer
  tier. **[src]**
- **Error return tracing** defaults to `false` in *all three* release modes; only Debug gets
  it ([src/Compilation/Config.zig, `root_error_tracing`](https://github.com/ziglang/zig/blob/300116b02/src/Compilation/Config.zig): `break :b switch (root_optimize_mode) { .Debug => true, .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false }`). **[src]**
- **Strip** defaults on only for ReleaseSmall (`if (root_optimize_mode == .ReleaseSmall)
  break :b true` in Config.zig's `root_strip`); ReleaseFast keeps debug info. **[src]**
- **Unwind tables** are emitted regardless of mode on Darwin (§5.4). **[src]**
- **Float mode is `strict` in every mode** — `std.builtin.FloatMode = enum { strict, optimized }`
  (`lib/std/builtin.zig:902`), and fast-math is opt-in per scope via `@setFloatMode(.optimized)`
  even in ReleaseFast (langref, `@setFloatMode` / Build Mode example). ReleaseFast does **not**
  imply fast-math. **[src][docs]**

**Verdict: `.ReleaseFast` is the right default for this daemon** — it is the only mode that
both gets `Aggressive` codegen and drops safety-check branches from the hot paths. The repo's
`orelse switch (b.graph.release_mode)` default already selects it for plain `zig build`
(verified: `zig build --help` shows the project's `-Doptimize` with ReleaseFast behavior
**[ran]**). If the team ever wanted illegal-behavior detection in production, ReleaseSafe
costs only the check branches, not an optimizer tier.

## 2. CPU targeting: baseline is already Apple-M1-class, crypto included

Three facts, all verified:

1. **The aarch64-macos *baseline* CPU is `apple_m1`, not generic ARMv8.** `Target.Cpu.Model.baseline`
   special-cases Apple OSes: `.driverkit, .maccatalyst, .macos => &aarch64.cpu.apple_m1`
   (`lib/std/Target.zig:2087`; the doc comment at lines 2067-2070 states this explicitly).
   **[src]**
2. **A plain native `zig build` doesn't even use the baseline — it detects the host CPU.**
   `Query.cpu_model` defaults to `.determined_by_arch_os` (`lib/std/Target/Query.zig:18`),
   which resolves to *native detection* when no `-Dtarget` arch is given, and to
   `baseline(arch, os)` when one is (`lib/std/zig/system.zig:374-379`). macOS native detection
   maps `hw.cpufamily` to a model; an M1 (`ARM_FIRESTORM_ICESTORM`) maps to **`apple_a14`**
   (same silicon generation) (`lib/std/zig/system/darwin/macos.zig`,
   `detectNativeCpuAndFeatures`). **[src]** Empirically: the default build and
   `-Dcpu=native` produce **byte-identical binaries** (same SHA-256), while `-Dcpu=apple_m1`
   differs — but `apple_a14` and `apple_m1` have **identical 31-entry feature sets**
   (diffed the generated lists in `lib/std/Target/aarch64.zig`); the binary delta is only the
   `target-cpu` string handed to LLVM (scheduling model identity), not features. **[ran]**
3. **The crypto extensions are in the baseline feature set.** `apple_m1` (and `apple_a14`)
   include `.aes` and `.sha3`, and the dependency chain closes over everything std.crypto
   checks: `.sha3 → .sha2 → .neon → .fp_armv8`, `.aes → .neon`
   (`lib/std/Target/aarch64.zig`, feature definitions). std.crypto selects hardware
   implementations **at comptime** from these flags: `lib/std/crypto/aes.zig:5-21`
   (`builtin.cpu.has(.aarch64, .aes)` → `aes/armcrypto.zig`), `lib/std/crypto/sha2.zig:203`
   (`.sha2` → inline-asm SHA-256 intrinsics), `lib/std/crypto/ghash_polyval.zig:289-293`.
   **[src]** Empirically: the default ReleaseFast `type-wave` binary contains **1310
   `aese`/`aesmc`** and **924 `sha256h`/`sha256su0`** instructions (`otool -tv | grep -c`) —
   the TLS hot path is already on the ARMv8 Crypto Extensions. **[ran]**

**Verdict: no change.** Local builds already target the exact host CPU; a distributed
`-Dtarget=aarch64-macos` build would get the `apple_m1` baseline, which still has every
feature std.crypto dispatches on. `-Dcpu=native` only matters on an M3/M4 host (newer
scheduling model + ARMv8.5/8.6 features) and would cost nothing here but also gain little —
and it would *not* be safe for binaries distributed back to M1 machines. **[inf]**

## 3. LTO: the API exists, but it is a hard error on MachO

- Current API on master: the old `want_lto: ?bool` is gone; `Compile` has
  `lto: ?std.zig.LtoMode = null` (`lib/std/Build/Step/Compile.zig:180`) with
  `pub const LtoMode = enum { none, full, thin }` (`lib/std/zig.zig:377`). It is a plain
  field (not in `Compile.Options`), so usage would be `exe.lto = .thin;`. **[src]**
- **It cannot work on aarch64-macos with this toolchain.** LTO requires LLD:
  `if (options.lto != null and options.lto != .none) … return error.LtoRequiresLld`
  when LLD is unavailable — and `hasLldSupport(ofmt)` returns true only for `.elf, .coff,
  .wasm`, **not `.macho`**
  ([src/Compilation/Config.zig, `use_lld`/`lto` blocks](https://github.com/ziglang/zig/blob/300116b02/src/Compilation/Config.zig);
  [src/target.zig#L274-L279](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L274-L279)).
  The source comments that self-hosted-linker LTO is tracked by
  [ziglang/zig#8680](https://github.com/ziglang/zig/issues/8680). **[src]**
- Empirical confirmation: `zig build-exe t.zig -flto -O ReleaseFast` with the flake's Zig on
  this machine → `error: LTO requires using LLD`. **[ran]**
- Backend interaction: even where LLD exists, requesting LTO forces LLD, and a self-hosted
  (non-LLVM) backend refuses LLD (`error.LldIncompatibleWithSelfHostedBackend`, same file).
  Moot here. **[src]**
- Expected value if it *were* available: low. All Zig code (app + vendored websocket + std)
  is one compilation unit already, so intra-Zig cross-function optimization happens without
  LTO; there are no C objects in this build for LTO to fuse. **[inf]**

**Verdict: nothing to do; do not set `exe.lto` — it would break the build.**

## 4. Backend: ReleaseFast on aarch64-macos is LLVM, by forced default

The `use_llvm` resolution in
[src/Compilation/Config.zig](https://github.com/ziglang/zig/blob/300116b02/src/Compilation/Config.zig)
reads, in order: … `// Prefer LLVM for release builds. if (root_optimize_mode != .Debug)
break :b true;` — so **every release build uses the LLVM backend** unless explicitly
overridden. For Debug, the self-hosted backend is used only where
`selfHostedBackendIsAsRobustAsLlvm(target)` — which returns `true` only for x86_64
(elf/macho) and SPIR-V; **aarch64 returns `false`**
([src/target.zig#L293-L311](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L293-L311)).
So on this nightly, aarch64-macos uses LLVM in *all* modes. **[src]**

Linking: with LLVM chosen but LLD unsupported for MachO, `use_lld` resolves `false` and
Zig's self-hosted MachO linker links the LLVM-produced objects (same file, `use_lld` block).
**[src]**

`use_llvm: ?bool` semantics (`lib/std/Build/Step/Compile.zig:200,286`): `null` = the above
resolution; `true` = force LLVM (also implied by `-femit-llvm-ir`/TSan); `false` = force the
self-hosted `stage2_aarch64` backend
([src/target.zig `zigBackend`](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L906-L921))
— a compile-speed backend, not an optimizing one; never set it for a production build.
**[src][inf]**

**Verdict: no change — the perf-optimal backend is already the forced default.**

## 5. Other Compile/Module knobs and their ReleaseFast defaults

Resolution logic for all of these is in
[src/Module.zig `create()`](https://github.com/ziglang/zig/blob/300116b02/src/Module.zig)
(per-module) and
[src/Compilation/Config.zig `resolve()`](https://github.com/ziglang/zig/blob/300116b02/src/Compilation/Config.zig)
(global), with the option surface in `lib/std/Build/Module.zig:28-44` and
`lib/std/Build/Step/Compile.zig`. **[src]**

### 5.1 `strip` — default `false` in ReleaseFast; size-only

`root_strip`: explicit → ReleaseSmall→true → else `false` (Config.zig). MachO keeps DWARF in
the `.o` files anyway; the binary carries a symbol table + stabs. Empirically, `strip -S` on
the default build: **1,464,776 → 1,397,560 bytes (−67 KB, −4.6%)**; the installed binary has
2573 `nm` symbols. **[src][ran]** Symbols are not loaded on the hot path — stripping has **no
runtime perf effect** and costs symbolized crash reports for an unattended daemon. **[inf]**
Verdict: leave unstripped (or expose `-Dstrip` for packaging if size ever matters).

### 5.2 `omit_frame_pointer` — default `false` in ReleaseFast; keep it that way

Resolution: explicit → parent → ReleaseSmall→`!isX86()` → **`false`**
([src/Module.zig#L212-L222](https://github.com/ziglang/zig/blob/300116b02/src/Module.zig#L212-L222)).
So ReleaseFast keeps x29 as frame pointer. Omitting it frees one register and a prologue
store-pair — a sub-1% class win on aarch64 **[inf]** — but Apple's platform ABI states "The
frame pointer register (x29) must always address a valid frame record"
([Writing ARM64 code for Apple platforms](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms))
**[docs]**, and frame-pointer walks are what Instruments/`sample` use to profile — exactly the
tooling behind the ms-shaving insert-path work. Verdict: **do not set** `omit_frame_pointer =
true`.

### 5.3 `single_threaded` — default `false`; must stay `false`

`defaultSingleThreaded` returns true only for wasm/Haiku
([src/target.zig#L107-L118](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L107-L118)).
This daemon **spawns at least six threads**: insertion worker, deadline timer, supervisor,
quit watcher (`src/daemon.zig:609-618`), session sender + maintenance + read loop
(`src/session.zig:239-279`), plus websocket.zig's `readLoopInNewThread`. **[ran]** (grep)
`-fsingle-threaded` changes codegen assumptions and TLS lowering (langref, "Single Threaded
Builds") and would be incorrect here. Verdict: **never set it** for this binary.

### 5.4 `unwind_tables` — Darwin is always `.async`, regardless of mode

`defaultUnwindTables`: `if (target.os.tag.isDarwin()) return .async;`
([src/target.zig#L561-L571](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L561-L571)).
Unwind tables are metadata (`__unwind_info`/`__eh_frame`) — a size cost, not an
execution-speed cost; forcing `.none` on macOS would break unwinding through the many Apple
framework callbacks this daemon lives in (CFRunLoop, AudioQueue callbacks). **[src][inf]**
Verdict: no change.

### 5.5 `error_tracing` — already `false` in every release mode

Config.zig `root_error_tracing` (see §1). Enabling it adds per-error-return bookkeeping —
that would be a runtime *regression*. Verdict: no change (already optimal).

### 5.6 `sanitize_thread` — default `false`; a debugging tool

Default `false` ([src/Module.zig#L224-L228](https://github.com/ziglang/zig/blob/300116b02/src/Module.zig#L224-L228));
enabling forces the LLVM backend and PIE (Config.zig) and instruments every memory access.
Useful once, offline, to vet the coordinator/session locking — never in the installed build.
**[src][inf]**

### 5.7 Dead-strip — already on for release builds on MachO

The MachO linker resolves `gc_sections = options.gc_sections orelse (optimize_mode != .Debug)`
([src/link/MachO.zig#L184](https://github.com/ziglang/zig/blob/300116b02/src/link/MachO.zig#L184))
and runs its atom GC (`dead_strip.gcAtoms`, MachO.zig:509-510). So ReleaseFast already
dead-strips unreachable code/data; `link_gc_sections` on `Compile`
(`lib/std/Build/Step/Compile.zig:119`) needs no setting. **[src]**

### 5.8 `dead_strip_dylibs` — available, startup-only, probably a no-op here

`Compile.dead_strip_dylibs: bool = false` (`lib/std/Build/Step/Compile.zig:168`) →
`-dead_strip_dylibs` (MachO.zig:718-719). It drops `LC_LOAD_DYLIB` entries whose symbols went
unused — affecting **dyld work at launch**, not steady-state latency. `otool -L` shows 10
load commands (8 frameworks + libobjc + libSystem), each deliberately used per the build.zig
comments; at most Carbon/ApplicationServices might be strippable if their single symbols ever
go unused. **[src][ran]** Verdict: not worth it for a long-running daemon (launch cost is
paid once).

### 5.9 `bundle_compiler_rt` — bundled for exes by default; leave it

`want_compiler_rt orelse is_exe_or_dyn_lib`
([src/Compilation.zig#L1748](https://github.com/ziglang/zig/blob/300116b02/src/Compilation.zig#L1748)).
compiler-rt provides required builtins; it's a link-time completeness question, not a runtime
knob. **[src]**

## 6. `link_libc = true` on macOS: required, and free

`Target.requiresLibC` returns `true` for `.macos` (`lib/std/Target.zig:2270-2283`) — Zig
always links libSystem on macOS regardless of `link_libc`, because Apple's only stable
syscall surface *is* libSystem. **[src]** The explicit `link_libc = true` in build.zig is
therefore redundant-but-harmless for the exe (and still needed semantically for
`std.c`-dependent code paths); there is no configuration in which this binary avoids
libSystem, so there is no perf trade to make. `otool -L` confirms `libSystem.B.dylib` is
linked. **[ran]** Verdict: no change.

## 7. PGO and BOLT: honestly unavailable

- **PGO:** this nightly's CLI has no profile flags at all — `zig build-exe --help | grep -i
  "profile\|pgo"` matches nothing **[ran]**, and the compiler driver's argument parser
  ([src/main.zig](https://github.com/ziglang/zig/blob/300116b02/src/main.zig)) contains no
  `pgo`/`profile-generate`/`profile-use` handling (grepped at the pinned commit). **[src]**
  There is no `std.Build` API for it either (`lib/std/Build/Step/Compile.zig`, no such
  field). Zig-code PGO simply does not exist in this toolchain.
- **BOLT:** post-link optimization is format-gated: "BOLT operates on X86-64 and AArch64
  **ELF** binaries" ([llvm-project `bolt/README.md`](https://github.com/llvm/llvm-project/blob/main/bolt/README.md))
  — MachO is not supported. **[docs]** Additionally, any post-link rewriting would invalidate
  the codesign signature the install flow applies (`packaging/install.sh`), requiring
  re-signing and re-granting. **[inf]**

**Verdict: no PGO/BOLT path exists for this target; do not budget time here.**

## 8. Things that look like perf knobs but are not (for this project)

- **`-fincremental` / `zig build -fincremental`** — incremental *compilation*: rebuild-speed
  only. In Config.zig it only influences `use_new_linker`, which is ELF-only
  (`hasNewLinker`: `.elf => true` — [src/target.zig#L282-L287](https://github.com/ziglang/zig/blob/300116b02/src/target.zig#L282-L287)).
  **Not runtime-relevant.** **[src]**
- **`use_llvm = false`** — faster *builds*, slower *binaries* (§4). Never for release.
- **`function_sections`/`data_sections`** — feed section-level GC on ELF; the MachO
  self-hosted linker GCs at atom granularity already (§5.7). **[src][inf]**
- **PIE** — on by default via `defaultPie` for macOS; mandatory ASLR, not tunable for perf.
  **[src][inf]**
- **Float mode** — if a hot numeric loop ever shows up in profiles (e.g. audio level math in
  `levelToNorm`), the lever is `@setFloatMode(.optimized)` *in the code, per scope* (§1) —
  there is no build-level fast-math switch. **[docs]**

## 9. Recommendations

Prioritized, with explicit "no change" verdicts — the point of this note is that the current
`build.zig` is already at the optimum the toolchain allows:

1. **No change: keep `.ReleaseFast` as the plain-build default** (§1). It is the only mode
   with both `Aggressive` codegen and no safety branches.
2. **No change: CPU targeting** (§2). Native builds already compile for the host CPU
   (verified byte-identical with `-Dcpu=native`), and even the cross-target baseline is
   `apple_m1` with hardware AES/SHA2/SHA3 — std.crypto's hot TLS path is already on the
   crypto extensions (1310 `aese`+`aesmc` in the shipped binary). Only revisit if binaries
   are ever built *on* an M3/M4 *for* that same machine class and profiling shows codegen on
   the crypto/audio paths matters — then `-Dcpu=native` is free.
3. **Do not add LTO** (§3): `exe.lto = .full/.thin` is a hard `error: LTO requires using LLD`
   on aarch64-macos in this nightly. Re-check only when
   [ziglang/zig#8680](https://github.com/ziglang/zig/issues/8680) (self-hosted-linker LTO)
   lands.
4. **Do not touch `use_llvm`** (§4): release builds already force the LLVM backend.
5. **Do not set `omit_frame_pointer = true`** (§5.2): Apple ABI wants frame records, and the
   team's Instruments-based ms-shaving depends on them. The theoretical win is sub-1%.
6. **Do not set `single_threaded = true`** (§5.3): the daemon runs ≥6 threads.
7. **Leave `error_tracing`, `unwind_tables`, `sanitize_thread`, `bundle_compiler_rt`,
   `link_gc_sections` alone** (§5): every default is already the runtime-optimal one
   (error tracing off, dead-strip on, Darwin unwind tables required).
8. **PGO/BOLT: none exists for zig/MachO** (§7) — spend the effort on code-level work
   instead; the delay-tier benchmarking approach is the right lever.
9. *Optional, non-perf:* expose a `-Dstrip` option for packaging (−4.6% size, §5.1) — but the
   default should stay unstripped so crash reports from the LaunchAgent stay symbolized.
10. *Optional, code-level:* if a profiled hot numeric loop appears, use
    `@setFloatMode(.optimized)` in that scope (§8) rather than hunting for a build flag.
