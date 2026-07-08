//! Embeds packaging/Info.plist into the binary's `__TEXT,__info_plist` Mach-O section
//! (wayfinder #15). For a bare (non-`.app`) command-line tool that section IS the
//! effective Info.plist — macOS reads CFBundleIdentifier (`me.ba78.type-wave`) from it
//! to label the daemon's TCC grants and NSMicrophoneUsageDescription for the mic
//! prompt, and `codesign` reads the identifier from it too. A stable bundle identity
//! is half of #15's point (the signed cert is the other half); see docs/packaging.md.
//!
//! `packaging/Info.plist` is registered as an anonymous import in build.zig, so
//! `@embedFile` reads its bytes at comptime. Nothing in Zig reads `info_plist` — the
//! OS reads the section straight out of the Mach-O image — so it is `export`ed (external
//! linkage keeps the section alive under `-dead_strip`) and force-referenced from the
//! entry point (see main.zig) to guarantee it is analysed and emitted.

const plist = @embedFile("Info.plist");

/// The raw Info.plist bytes, placed verbatim in `__TEXT,__info_plist`. Slicing to
/// `plist.len` drops `@embedFile`'s sentinel so no trailing NUL lands in the section.
pub export const info_plist: [plist.len]u8 linksection("__TEXT,__info_plist") = plist[0..plist.len].*;
