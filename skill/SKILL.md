---
name: video-reader
description: Turn a video URL (Bilibili, YouTube, and anything else yt-dlp supports) into readable text — title, chapter timeline, subtitles, an offline ASR transcript, or the on-screen text read by a vision model — plus optional keyframe screenshots. Use this whenever the user shares a video link and asks what it says, what it covers, or to extract information from a video platform.
---

# Read a video from its URL

This skill ships its own toolchain. It never requires downloading the full video — only the audio
track, or a low-resolution picture when frames are needed.

Resolve every relative path below against **this skill's own base directory** (the folder containing
this file). Do not assume an absolute path.

## Two pipelines — pick by where the information lives

| The information is in… | Use | Cost |
| --- | --- | --- |
| **What is said** (lecture, interview, podcast) | `Get-VideoContent.ps1` — offline ASR | free, private, ~30 s per 10 min |
| **What is shown** (slides, code, subtitles on screen) | `Get-VideoContent-Vision.ps1` — vision-model OCR | needs an API key, sends frames out |
| Both | Run both and merge | — |

```powershell
# Spoken content (offline, no API key)
& .\Get-VideoContent.ps1 -Url "<URL>"

# On-screen content (needs VISION_API_KEY or DEEPSEEK_API_KEY)
& .\Get-VideoContent-Vision.ps1 -Url "<URL>" -Interval 10 -Mode code
```

> On Windows, call scripts with `&`. The `.ps1` files are saved as **UTF-8 with BOM** — Windows
> PowerShell 5.1 reads `.ps1` as GBK otherwise, and the Chinese strings then break the parser.

### `Get-VideoContent.ps1` (spoken content)

| Option | Meaning |
| --- | --- |
| `-Asr sensevoice` | **Default.** SenseVoice fp32 + `language=zh` + ITN. Best measured quality. |
| `-Asr sensevoice-int8` | Quantised — faster, slightly worse. |
| `-Asr paraformer` | Small Chinese-only model. Fastest, noisiest. |
| `-Lang zh\|en\|ja\|ko\|yue\|auto` | **Must match the content.** Defaults to `zh`; auto-switches if the metadata declares a language. |
| `-FramesEvery <sec>` | Also dump keyframes to `frames\` for reading with an image tool. |
| `-NoAsr` | Stop after metadata + subtitles. |
| `-KeepMedia` | Keep the downloaded audio track. **Default: deleted after the run.** |

Requires `-WithLocalAsr` at setup time. Without it this script only produces metadata + subtitles.

### `Get-VideoContent-Vision.ps1` (on-screen content)

| Option | Meaning |
| --- | --- |
| `-Interval <sec>` | Seconds per frame. `10` for dense code slides, `20`–`30` for talking heads. |
| `-CropBottom <frac>` | Keep only the bottom slice (e.g. `0.20`) for hard-subtitle videos. Cuts image tokens ~5× without losing subtitle resolution. |
| `-Mode text\|code` | `code` tells the model to preserve indentation and symbols. |
| `-MaxFrames` | Hard cap; each frame is one API request. |
| `-KeepMedia` | Keep the downloaded low-res video. **Default: deleted.** |
| `-KeepFrames` | Keep the extracted frames. **Default: deleted once OCR is done.** |

Needs a key in `VISION_API_KEY` (or `DEEPSEEK_API_KEY`). Optional overrides:
`VISION_BASE`, `VISION_MODEL`, `VISION_CONCURRENCY`.

## Disk footprint — assume nothing is left behind

Downloaded media is only the cost of getting at the text, so **both scripts delete it by default**.
A 10-minute video leaves roughly **50 KB** (transcript + metadata) instead of 20–30 MB. Pass
`-KeepMedia` / `-KeepFrames` when the source needs re-examination.

Nothing is written outside `-OutDir`: no yt-dlp cache, no system temp residue, no PyInstaller unpack
directory — that last one is exactly why the project uses an embedded-Python zipapp rather than
`yt-dlp.exe`. When telling the user what a run costs in disk, say KB, not MB.

## Decision order — always cheapest first

1. **Metadata + chapters** — always works, free.
2. **Platform subtitles** — `--skip-download --write-subs`, zero media transfer, most accurate
   wording. Usually empty: most platforms gate captions behind login.
3. **Audio → offline ASR** — 16 kHz mono WAV ≈ 32 KB/s (10 min ≈ 19 MB).
4. **Frames → vision OCR** — for anything that lives on screen.
5. **Keyframes you read yourself** — no API key needed; only practical for a handful of frames.

## Layout

```
bin\yt-dlp.pyz + python\python.exe          download / metadata / subtitles
bin\ffmpeg.exe                              audio conversion, frame extraction
sherpa-onnx-*\bin\sherpa-onnx-offline.exe   offline ASR engine   (optional)
models\sherpa-onnx-sense-voice-*            default ASR engine   (optional)
vision-ocr.mjs                              sends frames to the vision model
fetch-file.mjs                              mirror-aware downloader used by setup.ps1
tools-dir.txt                               optional: point at an existing toolchain
```

## Engine notes (measured, not guessed)

A/B on the same 96-second Chinese segment:

| Engine | Result |
| --- | --- |
| **SenseVoice fp32 + `language=zh`** | **Best** — full sentences, correct punctuation, closest on proper nouns |
| SenseVoice int8 + `language=zh` | Good, drops more words |
| SenseVoice int8 + `auto` | Worse; pinning the language matters |
| Paraformer small int8 | Most verbose, no punctuation, heavy insertion noise |

Keep the **fp32** `model.onnx`; quantising to int8 measurably costs accuracy.

**Singing is out of scope for ASR.** ASR models are trained on speech, not music. A live recording
with a band transcribes poorly on *every* engine and every language setting. For songs, read the
on-screen lyrics with the vision pipeline — or better, use a licensed lyrics source.

## Gotchas worth not rediscovering

- **GitHub direct downloads can be very slow** (observed 0.08 MB/s). `fetch-file.mjs` already tries
  `gh-proxy.com` and `ghfast.top` first (observed 1.8–17 MB/s). Set `GH_MIRROR` to force one.
- **Version differences are real.** Preset descriptions and tool counts change between DSH
  releases. Verify anything load-bearing against the installed version, not a video or a blog post.
- `sherpa-onnx-offline` has **no `--print-result` flag** (only `--print-args`). It prints its result
  as **one line of JSON** and writes config dumps to **stderr**.
- With `$ErrorActionPreference = 'Stop'`, native stderr becomes a fatal error. Native calls must
  temporarily relax it.
- **`Join-Path` returns a string, not a `FileInfo`** — `$path.FullName` is silently `$null`.
- **`$args` is a reserved automatic variable** — never use it as a function parameter name.
- **A variable followed by `:` needs braces.** `"...ih*$keep:0..."` parses `$keep:0` as a variable
  named `keep:0`, silently emptying it and corrupting the whole string. Write `${keep}`.

## Boundaries

- **Terms of service and copyright**: downloading media may violate a platform's terms. Summarising
  for the user's own understanding is one thing; **redistributing the content is not**.
- **Do not produce full transcripts of copyrighted lyrics or scripts.** Read on-screen text to
  locate and describe, not to reproduce a work in full.
- **Transcription is evidence, not ground truth** — proper nouns and code identifiers especially.
  OCR confuses `l/1/I`, `O/0`, `rn/m`. Flag uncertainty instead of quoting as if verbatim.
