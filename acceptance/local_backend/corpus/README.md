# Human-speech qualification corpus

This is the versioned `type-wave-common-voice-17-en-sv-v1` release corpus. It contains
ten English and ten Swedish human-spoken Utterances from exactly two speakers per language,
selected before qualification results were observed. Each language has four short, three
medium, and three 10–15-second Utterances.

The source is Mozilla Common Voice Corpus 17.0 (`2024-03-15`), distributed under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). The selected data came from
the `en/train` and `sv-SE/train` splits of the
[`fsicoli/common_voice_17_0`](https://huggingface.co/datasets/fsicoli/common_voice_17_0)
redistribution at commit `8262c16bf297c87a9cd88c51997c4758ed7a8ba2`. Common Voice's speaker
`client_id` values were used only to enforce two distinct speakers per language. Their
one-way SHA-256 bindings are retained in `sources.json`, so every local speaker label and the
exact two-speaker-per-language shape remain independently auditable; the corpus
uses local opaque IDs and makes no attempt to identify a contributor.

The source MP3 clips were decoded without trimming or concatenation using macOS `afconvert`:

```sh
afconvert -f WAVE -d LEI16@24000 -c 1 SOURCE.mp3 DESTINATION.wav
```

The exact Common Voice references, fixture tags, converted-audio SHA-256 digests, explicit
language modes, and auto-detect modes are in `manifest.json`. `sources.json` binds every local
fixture ID to the exact dataset revision, locale, split, archive shard, source clip, source
duration, and source MP3 digest. The checked-in WAV files are the authoritative bytes used for
release qualification.

When referencing the source corpus, use:

> Ardila et al. (2020), “Common Voice: A Massively-Multilingual Speech Corpus,” LREC 2020,
> pp. 4211–4215.
