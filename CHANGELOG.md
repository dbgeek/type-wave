# Changelog

## [0.4.2](https://github.com/dbgeek/type-wave/compare/v0.4.1...v0.4.2) (2026-07-29)


### Bug Fixes

* **supervisor:** the press gate caches only what has no live owner ([#338](https://github.com/dbgeek/type-wave/issues/338)) ([#339](https://github.com/dbgeek/type-wave/issues/339)) ([6dffb18](https://github.com/dbgeek/type-wave/commit/6dffb181c9da24cce073ab7f64d27a14f003df66))

## [0.4.1](https://github.com/dbgeek/type-wave/compare/v0.4.0...v0.4.1) (2026-07-29)


### Features

* **menu:** the Vocabulary dialog copy tracks keywords capability ([#333](https://github.com/dbgeek/type-wave/issues/333)) ([#335](https://github.com/dbgeek/type-wave/issues/335)) ([dbf7a48](https://github.com/dbgeek/type-wave/commit/dbf7a4817f4367248f6f5b767bc2c357462ef5cb))
* **menu:** the Vocabulary suffix tracks keywords capability ([#328](https://github.com/dbgeek/type-wave/issues/328)) ([#334](https://github.com/dbgeek/type-wave/issues/334)) ([adc06f6](https://github.com/dbgeek/type-wave/commit/adc06f60f6be926f321ce61f2c63aec1f4c943a1))
* **session:** vocabulary biases OpenAI transcription at connect ([#326](https://github.com/dbgeek/type-wave/issues/326)) ([#330](https://github.com/dbgeek/type-wave/issues/330)) ([debac9b](https://github.com/dbgeek/type-wave/commit/debac9b8c2ce1929083380533c68a98004231e51))
* **session:** vocabulary edits re-bind the warm session (rebias push) ([#327](https://github.com/dbgeek/type-wave/issues/327)) ([#332](https://github.com/dbgeek/type-wave/issues/332)) ([349560b](https://github.com/dbgeek/type-wave/commit/349560bb9d337264731d9a6943b502a60c5ea6cc))

## [0.4.0](https://github.com/dbgeek/type-wave/compare/v0.3.5...v0.4.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* **config:** gpt-live-transcribe is the default transcription model ([#308](https://github.com/dbgeek/type-wave/issues/308))

### Features

* **config:** gpt-live-transcribe is the default transcription model ([#308](https://github.com/dbgeek/type-wave/issues/308)) ([cc35d05](https://github.com/dbgeek/type-wave/commit/cc35d053bae013feb34cf3316f5e2fea9732db15))

## [0.3.5](https://github.com/dbgeek/type-wave/compare/v0.3.4...v0.3.5) (2026-07-26)


### Bug Fixes

* **build:** the websocket client is pinned by a verifiable hash, in exactly one place ([#290](https://github.com/dbgeek/type-wave/issues/290)) ([#291](https://github.com/dbgeek/type-wave/issues/291)) ([53719ce](https://github.com/dbgeek/type-wave/commit/53719cea0d1d90a11f920b94ebd58a498826d5e9))
* **capture:** a hold whose release edge is lost still stops the microphone ([#272](https://github.com/dbgeek/type-wave/issues/272)) ([#277](https://github.com/dbgeek/type-wave/issues/277)) ([11967cb](https://github.com/dbgeek/type-wave/commit/11967cb9b3260dd734318f755145bf3d33e5b1fc))
* **config:** the env-file migration takes the plaintext key off disk ([#283](https://github.com/dbgeek/type-wave/issues/283)) ([1ab85ed](https://github.com/dbgeek/type-wave/commit/1ab85ed541f3bf6b0c8f7403941314c189c90705))
* **insert:** quitting waits for the pasteboard restore the Insert Worker still owes ([#273](https://github.com/dbgeek/type-wave/issues/273)) ([#278](https://github.com/dbgeek/type-wave/issues/278)) ([2506142](https://github.com/dbgeek/type-wave/commit/25061422874fcffa17c2bedbcc6033e5287fd639))
* **local:** the daemon proves the Whisper Helper's Signing Identity before spawning it ([#284](https://github.com/dbgeek/type-wave/issues/284)) ([#287](https://github.com/dbgeek/type-wave/issues/287)) ([9a53392](https://github.com/dbgeek/type-wave/commit/9a533923143029ce2dabf43eb0c508110e3560bf))
* **model:** an interrupted removal completes later ([#276](https://github.com/dbgeek/type-wave/issues/276)) ([#281](https://github.com/dbgeek/type-wave/issues/281)) ([748f99d](https://github.com/dbgeek/type-wave/commit/748f99d484aafbe2a1bc7355cc5f7580948b4b65))
* **model:** an over-long child line is skipped, not read as end of stream ([#275](https://github.com/dbgeek/type-wave/issues/275)) ([#280](https://github.com/dbgeek/type-wave/issues/280)) ([2ae2317](https://github.com/dbgeek/type-wave/commit/2ae231770c8aacca7ee9009c47a65a954974a302))
* **security:** an Utterance spoken under Secure Event Input is not retained ([#286](https://github.com/dbgeek/type-wave/issues/286)) ([#289](https://github.com/dbgeek/type-wave/issues/289)) ([f936a01](https://github.com/dbgeek/type-wave/commit/f936a0184564d7a4006d6f75afdc4311a37f91c1))
* **session:** a server-sent expires_at is proved sane before it becomes the session deadline ([#274](https://github.com/dbgeek/type-wave/issues/274)) ([#279](https://github.com/dbgeek/type-wave/issues/279)) ([f09ab0a](https://github.com/dbgeek/type-wave/commit/f09ab0a189e21bf4bd8977be6e5d8b624e8a37d9))
* **whisper:** the helper's pipe fds are closed by the threads that hold them ([#269](https://github.com/dbgeek/type-wave/issues/269)) ([#270](https://github.com/dbgeek/type-wave/issues/270)) ([56ac4ef](https://github.com/dbgeek/type-wave/commit/56ac4efac8ee1b98302b311b71508766d25e4dfc))

## [0.3.4](https://github.com/dbgeek/type-wave/compare/v0.3.3...v0.3.4) (2026-07-25)


### Features

* **log:** the user can clear the daemon's log from the Status Item ([#252](https://github.com/dbgeek/type-wave/issues/252)) ([#262](https://github.com/dbgeek/type-wave/issues/262)) ([50466c4](https://github.com/dbgeek/type-wave/commit/50466c400b2e4bdf23d85d4ec97e28de15b24d7f))


### Bug Fixes

* **insert:** an Insertion proves its Focused Target before it pastes ([#265](https://github.com/dbgeek/type-wave/issues/265)) ([6c623d0](https://github.com/dbgeek/type-wave/commit/6c623d06e949becd5792febb95d647d21e22bd7d)), closes [#255](https://github.com/dbgeek/type-wave/issues/255)
* **ipc:** a broken pipe fails the write, not the process ([#253](https://github.com/dbgeek/type-wave/issues/253)) ([#263](https://github.com/dbgeek/type-wave/issues/263)) ([3c529e3](https://github.com/dbgeek/type-wave/commit/3c529e3c01f96edccfe006f18ca47b36532d3c3d))
* **key:** the daemon holds one API key copy, and scrubs it ([#254](https://github.com/dbgeek/type-wave/issues/254)) ([#264](https://github.com/dbgeek/type-wave/issues/264)) ([7c326ba](https://github.com/dbgeek/type-wave/commit/7c326ba49878b49ffb52002a7564dbabe18c18af))
* **log:** the daemon's log records that an Utterance resolved, not what was said ([#259](https://github.com/dbgeek/type-wave/issues/259)) ([c8e9d9c](https://github.com/dbgeek/type-wave/commit/c8e9d9cbd9a4536a537658d1d511dbf5b0dc080b)), closes [#250](https://github.com/dbgeek/type-wave/issues/250)
* **model:** re-prove the trusted origin on every redirect hop ([#261](https://github.com/dbgeek/type-wave/issues/261)) ([90265cf](https://github.com/dbgeek/type-wave/commit/90265cf0b64eb8901b74534da4da5a0855048905))
* **rewrite:** a Rewrite that never answers fails, it doesn't retire Backtrack ([#257](https://github.com/dbgeek/type-wave/issues/257)) ([#267](https://github.com/dbgeek/type-wave/issues/267)) ([d98e016](https://github.com/dbgeek/type-wave/commit/d98e016c52f39237a3752a5ae06acfb565fcc29a))
* **undo:** a long deletion re-proves its Focused Target as it goes ([#266](https://github.com/dbgeek/type-wave/issues/266)) ([027bab6](https://github.com/dbgeek/type-wave/commit/027bab6c11907d45e7081e45c45e2bf28782dc04)), closes [#256](https://github.com/dbgeek/type-wave/issues/256)

## [0.3.3](https://github.com/dbgeek/type-wave/compare/v0.3.2...v0.3.3) (2026-07-25)


### Bug Fixes

* **undo:** ⌃⌘⌫ deletes again, and a held Secure Event Input says so ([#246](https://github.com/dbgeek/type-wave/issues/246)) ([64114f7](https://github.com/dbgeek/type-wave/commit/64114f7fa5b710aec440278eb83fa00763baf4ff))

## [0.3.2](https://github.com/dbgeek/type-wave/compare/v0.3.1...v0.3.2) (2026-07-24)


### Features

* **insertion:** every cursor job resolves at drain time (ADR-0009) ([#241](https://github.com/dbgeek/type-wave/issues/241)) ([95c62d2](https://github.com/dbgeek/type-wave/commit/95c62d2ebfe5b416ebbe969d94674eaacec80bc1))

## [0.3.1](https://github.com/dbgeek/type-wave/compare/v0.3.0...v0.3.1) (2026-07-24)


### Features

* **undo:** collapse the Undo path into one worker-side Runner (ADR-0008) ([83e30eb](https://github.com/dbgeek/type-wave/commit/83e30eb05e53c0d7c0f775185b9f70fbd61219e0))

## [0.3.0](https://github.com/dbgeek/type-wave/compare/v0.2.0...v0.3.0) (2026-07-24)


### Features

* **undo:** app-level focus gate — refuse when the frontmost app changed ([#224](https://github.com/dbgeek/type-wave/issues/224)) ([#232](https://github.com/dbgeek/type-wave/issues/232)) ([ea6ebe3](https://github.com/dbgeek/type-wave/commit/ea6ebe354d0981effa7ad08fa1afa20689dad0b4))
* **undo:** capture the ⌃⌘⌫ recovery chord in the Talk Key tap ([#221](https://github.com/dbgeek/type-wave/issues/221)) ([#229](https://github.com/dbgeek/type-wave/issues/229)) ([fbdfa6f](https://github.com/dbgeek/type-wave/commit/fbdfa6f6462038c8f4740487947854331272bc1e))
* **undo:** deleteChars primitive + undo_job adapter slot ([#222](https://github.com/dbgeek/type-wave/issues/222)) ([#230](https://github.com/dbgeek/type-wave/issues/230)) ([aa13139](https://github.com/dbgeek/type-wave/commit/aa131396c2267ce538a49771fe2390739f5b091d))
* **undo:** grapheme-count deletion helper ([#220](https://github.com/dbgeek/type-wave/issues/220)) ([#227](https://github.com/dbgeek/type-wave/issues/227)) ([1169942](https://github.com/dbgeek/type-wave/commit/116994228bf5e70a9fae4906937b813196c87db5))
* **undo:** HUD confirm/refuse cue — green bloom, red shake ([#226](https://github.com/dbgeek/type-wave/issues/226)) ([#234](https://github.com/dbgeek/type-wave/issues/234)) ([81c232a](https://github.com/dbgeek/type-wave/commit/81c232a2a5b4a9c75b51f15f70f38fd9384e2a60))
* **undo:** single-shot model — undone flag, redo, refuse-on-undone ([#225](https://github.com/dbgeek/type-wave/issues/225)) ([#233](https://github.com/dbgeek/type-wave/issues/233)) ([11a3168](https://github.com/dbgeek/type-wave/commit/11a3168dca2deb557032c1f8ed8b65612874cd55))
* **undo:** wire ⌃⌘⌫ to delete the newest Insertion ([#223](https://github.com/dbgeek/type-wave/issues/223)) ([#231](https://github.com/dbgeek/type-wave/issues/231)) ([7ac8ab9](https://github.com/dbgeek/type-wave/commit/7ac8ab904d4f398a179d32b7cbae688f41372235))

## [0.2.0](https://github.com/dbgeek/type-wave/compare/v0.1.4...v0.2.0) (2026-07-24)


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
