# Changelog

## [0.1.5](https://github.com/dbgeek/type-wave/compare/v0.1.4...v0.1.5) (2026-07-24)


### Features

* **recent-insertions:** capture Insertion Records into the daemon-owned ring ([#193](https://github.com/dbgeek/type-wave/issues/193)) ([#200](https://github.com/dbgeek/type-wave/issues/200)) ([7fe31e0](https://github.com/dbgeek/type-wave/commit/7fe31e097c3600e737b4d449dffc6e55274e39e6))
* **recent-insertions:** copy a recorded Insertion to the clipboard ([#197](https://github.com/dbgeek/type-wave/issues/197)) ([#205](https://github.com/dbgeek/type-wave/issues/205)) ([f51f752](https://github.com/dbgeek/type-wave/commit/f51f752fafb40b7e625839efb9569bf35234d1b2))
* **recent-insertions:** masked Recent Insertions submenu via the pure split ([#195](https://github.com/dbgeek/type-wave/issues/195)) ([#203](https://github.com/dbgeek/type-wave/issues/203)) ([4ca3b90](https://github.com/dbgeek/type-wave/commit/4ca3b90dedc0552a1dc1d0e1e28d1e44aad5895f))
* **recent-insertions:** re-insert a recorded Insertion at the frontmost cursor ([#198](https://github.com/dbgeek/type-wave/issues/198)) ([#206](https://github.com/dbgeek/type-wave/issues/206)) ([639c3fa](https://github.com/dbgeek/type-wave/commit/639c3fa0915fba47369e7a7322e968766ed3f824))
* **recent-insertions:** reveal a single entry's text on ⌥-click ([#196](https://github.com/dbgeek/type-wave/issues/196)) ([#204](https://github.com/dbgeek/type-wave/issues/204)) ([d0dfc1e](https://github.com/dbgeek/type-wave/commit/d0dfc1ef03c381acbc68b920620286bc360b9134))
* **recent-insertions:** widen insert worker to accept a Coordinator-less job ([#194](https://github.com/dbgeek/type-wave/issues/194)) ([#202](https://github.com/dbgeek/type-wave/issues/202)) ([c6427fb](https://github.com/dbgeek/type-wave/commit/c6427fb302d23e75b5f7bd728c83cbbdb932fa36))


### Bug Fixes

* **whisper:** use dupeSentinel for the C-ABI prompt copy ([#207](https://github.com/dbgeek/type-wave/issues/207)) ([#208](https://github.com/dbgeek/type-wave/issues/208)) ([61f6bdd](https://github.com/dbgeek/type-wave/commit/61f6bdd232adf6a1a4f9d0cf11d8f8fc169b6ede))

## [0.1.4](https://github.com/dbgeek/type-wave/compare/v0.1.3...v0.1.4) (2026-07-23)


### Features

* **menu:** vocabulary editing dialog, state-reflecting item & local-only signal ([#173](https://github.com/dbgeek/type-wave/issues/173)) ([#179](https://github.com/dbgeek/type-wave/issues/179)) ([4e99963](https://github.com/dbgeek/type-wave/commit/4e99963f63addca16538215ec121b18f222a5eb0))
* **vocab:** v2 Whisper wire + Lease-pinned initial_prompt biasing ([#174](https://github.com/dbgeek/type-wave/issues/174)) ([#181](https://github.com/dbgeek/type-wave/issues/181)) ([ff81927](https://github.com/dbgeek/type-wave/commit/ff8192775d1d06b3cf49fd0e859006369178b963))

## [0.1.3](https://github.com/dbgeek/type-wave/compare/v0.1.2...v0.1.3) (2026-07-23)


### Features

* **config:** vocabulary schema, load-time clamp & comment-preserving round-trip ([#171](https://github.com/dbgeek/type-wave/issues/171)) ([#175](https://github.com/dbgeek/type-wave/issues/175)) ([9557af5](https://github.com/dbgeek/type-wave/commit/9557af5335c2e42b675ebcddb1111b7a9b65ecc2))
* **vocab:** pure buildPrompt glossary + Whisper budget estimation ([#172](https://github.com/dbgeek/type-wave/issues/172)) ([#177](https://github.com/dbgeek/type-wave/issues/177)) ([f25b8fa](https://github.com/dbgeek/type-wave/commit/f25b8fa7e7bc98358a1d5c565602c636722b210f))

## [0.1.2](https://github.com/dbgeek/type-wave/compare/v0.1.1...v0.1.2) (2026-07-20)


### Features

* **backtrack:** rewrite spoken self-corrections via OpenAI (opt-in) ([#148](https://github.com/dbgeek/type-wave/issues/148)) ([d7736f5](https://github.com/dbgeek/type-wave/commit/d7736f5f18767c876f5729df06dfecf278c98918))

## [0.1.1](https://github.com/dbgeek/type-wave/compare/v0.1.0...v0.1.1) (2026-07-19)


### Features

* **daemon:** zero-restart TCC cold start — tap recreate, Insertion probe, serialized grant requests ([#133](https://github.com/dbgeek/type-wave/issues/133)) ([8807f9f](https://github.com/dbgeek/type-wave/commit/8807f9ffc40620e5cc4657ca9a62d2dfb2034fe9))

## 0.1.0 (2026-07-19)


### Continuous Integration

* wire release-please (config, manifest, build.zig.zon bump) ([#120](https://github.com/dbgeek/type-wave/issues/120)) ([1e74d82](https://github.com/dbgeek/type-wave/commit/1e74d82656f1e7a9cd49db65045c1adb1b0a4185))
