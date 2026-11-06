# biorouter-models

Speech models for Biorouter's local dictation, and the audio that Biorouter's dictation accuracy tests read. Each file is published here as its own GitHub release, and every release is immutable. Nothing in this repository is part of a Biorouter install or update: a person chooses to install a model, and Biorouter then downloads it from here.

## How Biorouter uses these files

- Biorouter downloads only the files listed below, each by its exact release URL of the form `https://github.com/BaranziniLab/biorouter-models/releases/download/<tag>/<file>`. It never asks for `releases/latest` and never calls `api.github.com` at run time.
- After every download it computes the file's SHA-256 and compares it with the value compiled into the app. A file whose SHA-256 differs is refused. The digest GitHub reports is not trusted at run time; the compiled value is.
- An administrator may point Biorouter at a mirror first. The same compiled SHA-256 values apply there, so a mirror cannot change which bytes are accepted.
- A release download answers with a redirect to `release-assets.githubusercontent.com`, GitHub's file host. A network that blocks that host blocks the download.
- Releases here are immutable: once a release is published, its files and its tag can never change. A new revision of a file gets a new release with the next `-r<n>` tag, and the old release stays as it was.

## Models

| id | file | bytes | SHA-256 | license | release |
|---|---|---:|---|---|---|
| `whisper-large-v3-turbo-q5_0` | `ggml-large-v3-turbo-q5_0.bin` | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` | MIT | [`stt-whisper-large-v3-turbo-q5_0-r1`](https://github.com/BaranziniLab/biorouter-models/releases/tag/stt-whisper-large-v3-turbo-q5_0-r1) |
| `whisper-small.en-q8_0` | `ggml-small.en-q8_0.bin` | 264,477,561 | `67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067` | MIT | [`stt-whisper-small.en-q8_0-r1`](https://github.com/BaranziniLab/biorouter-models/releases/tag/stt-whisper-small.en-q8_0-r1) |
| `silero-vad-v6.2.0` | `ggml-silero-v6.2.0.bin` | 885,098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` | MIT | [`stt-silero-vad-v6.2.0-r1`](https://github.com/BaranziniLab/biorouter-models/releases/tag/stt-silero-vad-v6.2.0-r1) |

Every model file is a byte identical copy of the upstream file at a pinned revision. None of them was reconverted or changed here. Anyone can check each one against two independent public records: the SHA-256 that Hugging Face stores for the file, and (for the two Whisper files) the SHA-1 that the whisper.cpp project publishes.

### whisper-large-v3-turbo-q5_0

`ggml-large-v3-turbo-q5_0.bin` (547 MiB) is OpenAI's Whisper large-v3-turbo, converted to the ggml format and quantized to q5_0 by the whisper.cpp project. It is multilingual.

- Source: https://huggingface.co/ggerganov/whisper.cpp at revision `5359861c739e955e79d9a303bcbc70fb988958b1`
- SHA-1 published upstream: `e050f7970618a659205450ad97eb95a18d69c9ee`
- Format: legacy ggml (magic `0x67676d6c`), q5_0

### whisper-small.en-q8_0

`ggml-small.en-q8_0.bin` (252 MiB) is OpenAI's Whisper small.en, converted to the ggml format and quantized to q8_0 by the whisper.cpp project. It understands English only.

- Source: https://huggingface.co/ggerganov/whisper.cpp at revision `5359861c739e955e79d9a303bcbc70fb988958b1`
- SHA-1 published upstream: `9d75ff4ccfa0a8217870d7405cf8cef0a5579852` (in that revision's README)
- Format: legacy ggml (magic `0x67676d6c`), q8_0

### silero-vad-v6.2.0

`ggml-silero-v6.2.0.bin` (864 KiB) is the Silero voice activity detector, version 6.2.0, converted to the ggml format by the whisper.cpp project. Both speech models need it: it finds the stretches of audio that hold speech, so silence and background noise never reach the speech model.

- Source: https://huggingface.co/ggml-org/whisper-vad at revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b`
- SHA-1: `470e5d9d094ddba2f0a512cecc3732a252188abd`. Upstream publishes no SHA-1 for this file; this one was computed from the file whose SHA-256 matches the Hugging Face record.
- Format: legacy ggml (magic `0x67676d6c`)

## What each model release contains

| Asset | Contents |
|---|---|
| the model file | Byte identical to the upstream file at the pinned revision |
| `provenance.json` | Where and when the file was fetched, its sizes and hashes, what it was derived from, its license, and the digest GitHub reported for it |
| `SHA256SUMS` | One line in `sha256sum` format |
| `LICENSE-openai-whisper.txt` and `LICENSE-whisper.cpp.txt` | The license texts of a Whisper release |
| `LICENSE-silero-vad.txt` | The license text of the detector's release |
| `NOTICE.md` | Who made the weights, who converted them and who hosts them |

## Evaluation set

[`eval-primock57-subset-r1`](https://github.com/BaranziniLab/biorouter-models/releases/tag/eval-primock57-subset-r1) holds `primock57-subset-r1.tar` (7,567,360 bytes, SHA-256 `2776a659f659181f9a4aa67c98d47bf531ad0c904623f9e77d075a714af599e1`), `ATTRIBUTION.md`, `SHA256SUMS`, `provenance.json` and the license text. Biorouter never downloads it at run time; only its accuracy test reads it.

The archive is a subset of [PriMock57](https://github.com/babylonhealth/primock57), mock primary care consultations recorded and transcribed by Babylon Health and published under CC BY 4.0. It holds:

- 60 utterances (44 from the clinician channel, 16 from the patient channel), 420.6 s in all, that name 26 drugs 85 times;
- 16 spans of 3 to 8 s in which the clinician says nothing: 10 where both channels are silent and 6 where only the patient speaks;
- `manifest.jsonl` with each clip's source, cut, transcript text and drug names, `terms.json` with the 26 drug names, `ATTRIBUTION.md` and the license text.

The clips are 16 kHz mono FLAC, lossless copies of the source samples. `scripts/build-eval-primock57.py` rebuilds the archive from PriMock57 at commit `cd2ac707ad03cb4d2531f4ec6b90c659bf4357c5`. It reads the pinned list in `eval/primock57-subset/selection.json`, checks every transcript file and every clip against the SHA-256 recorded there, and refuses any difference. With the `flac` 1.4.3 package of Ubuntu 24.04 it gives the same archive byte for byte. The selection rules are written out in that file and in the release notes.

## How a release is made

1. A pull request adds or changes `catalog/<id>.json`: the source URL with its revision, the expected size, SHA-256 and SHA-1, the license, and the tag.
2. When it merges, `.github/workflows/publish-model.yml` runs on an Ubuntu runner. For a model it downloads the file from the pinned revision and checks its size, SHA-256, SHA-1 and the legacy ggml magic (`lmgg` on disk). For an evaluation set it runs the builder and checks the archive's size and SHA-256.
3. It writes `provenance.json` and `SHA256SUMS`, creates the release as a draft, uploads the files, reads the digest GitHub computed for the pinned file and records it in `provenance.json`, then publishes the draft.
4. It reads every asset's digest back, compares each with the local file and the pinned file with the catalog, confirms the release reports `immutable: true`, and runs `gh release verify-asset` on every asset.
5. A tag that is already published is checked against its pin and skipped, so a rerun changes nothing.

Only that workflow publishes releases here, and only from commits on `main`. Nobody downloads from Hugging Face at run time: the workflow is the only thing here that ever reads it.

## Checking a file yourself

```bash
curl -fLO https://github.com/BaranziniLab/biorouter-models/releases/download/stt-silero-vad-v6.2.0-r1/ggml-silero-v6.2.0.bin
echo "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987  ggml-silero-v6.2.0.bin" | sha256sum -c
gh release verify-asset stt-silero-vad-v6.2.0-r1 ggml-silero-v6.2.0.bin --repo BaranziniLab/biorouter-models
```

## Licenses and credits

| Work | Made by | License | Text |
|---|---|---|---|
| Whisper weights | OpenAI | MIT, Copyright (c) 2022 OpenAI | [`licenses/LICENSE-openai-whisper.txt`](licenses/LICENSE-openai-whisper.txt) |
| ggml conversions of Whisper and the detector | the whisper.cpp project (the ggml authors) | MIT, Copyright (c) 2023-2026 The ggml authors | [`licenses/LICENSE-whisper.cpp.txt`](licenses/LICENSE-whisper.cpp.txt) |
| Silero VAD | Silero Team | MIT, Copyright (c) 2020-present Silero Team | [`licenses/LICENSE-silero-vad.txt`](licenses/LICENSE-silero-vad.txt) |
| PriMock57 | Alex Papadopoulos Korfiatis, Francesco Moramarco, Radmila Sarac and Aleksandar Savkov, Babylon Health | CC BY 4.0 | [`licenses/LICENSE-primock57.md`](licenses/LICENSE-primock57.md) |

The license texts were copied from the upstream repositories: [openai/whisper](https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE), [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/b1535f5fb163f4443804888f7be980621226cb15/LICENSE), [snakers4/silero-vad](https://github.com/snakers4/silero-vad/blob/066409f3d9db45a30d21dfcbf9147826ffdd7052/LICENSE) and [babylonhealth/primock57](https://github.com/babylonhealth/primock57/blob/cd2ac707ad03cb4d2531f4ec6b90c659bf4357c5/LICENSE.md).

PriMock57 is described in Papadopoulos Korfiatis A., Moramarco F., Sarac R. and Savkov A., "PriMock57: A Dataset Of Primary Care Mock Consultations", Proceedings of the 60th Annual Meeting of the Association for Computational Linguistics, 2022 (https://arxiv.org/abs/2204.00333). Its authors and Babylon Health do not endorse Biorouter or this repository.

The [Baranzini Lab](https://baranzinilab.ucsf.edu/) at UCSF hosts these files for [Biorouter](https://github.com/BaranziniLab/biorouter). It did not train, convert or change any model.
