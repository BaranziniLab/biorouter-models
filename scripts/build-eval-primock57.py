"""Builds the PriMock57 evaluation subset from upstream at a pinned commit.

    python3 -I scripts/build-eval-primock57.py --selection eval/primock57-subset/selection.json \
        --license licenses/LICENSE-primock57.md --out <dir>

What it does, in order:

1. Fetches every TextGrid the selection needs from the pinned commit and checks its SHA-256.
2. Finds each selected utterance and gap in the TextGrids and checks it against the selection
   rules (length, no transcriber tags, at least one listed drug name; for gaps, an empty interval
   and the right category).
3. Fetches only the byte ranges of the channel recordings that cover each clip (the recordings
   are 16 kHz mono 16 bit WAV with a 44 byte header), writes each clip as a WAV and checks its
   SHA-256 against the value the 2026-11-04 research run recorded for the same clip.
4. Encodes each clip to FLAC with the `flac` command, decodes it again and checks the samples.
5. Writes manifest.jsonl, terms.json and ATTRIBUTION.md, and packs everything into a tar file
   with fixed metadata, so the same inputs and the same `flac` version give the same bytes.

Outputs in <dir>: the tar named after the selection, ATTRIBUTION.md, and build-info.json.
The script needs only the Python standard library and the `flac` command.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

RATE = 16000


def fail(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def fetch(url, byte_range=None):
    headers = {"User-Agent": "biorouter-models-eval-builder"}
    if byte_range:
        headers["Range"] = f"bytes={byte_range[0]}-{byte_range[1]}"
    err = None
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=120) as r:
                if byte_range and r.status != 206:
                    raise RuntimeError(f"{url}: expected 206 for a range request, got {r.status}")
                data = r.read()
            if byte_range and len(data) != byte_range[1] - byte_range[0] + 1:
                raise RuntimeError(f"{url}: short range read")
            return data
        except Exception as e:  # network errors are retried, then reported
            err = e
            time.sleep(2 + 3 * attempt)
    fail(f"could not fetch {url}: {err}")


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def intervals(textgrid):
    return [
        (float(a), float(b), x.strip())
        for a, b, x in re.findall(r'xmin = ([0-9.]+)\s*\n\s*xmax = ([0-9.]+)\s*\n\s*text = "(.*?)"\s*\n', textgrid, re.S)
    ]


def term_count(text, term):
    return len(re.findall(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])", text, re.I))


def wav_bytes(pcm):
    n = len(pcm)
    header = b"RIFF" + struct.pack("<I", 36 + n) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
    header += b"data" + struct.pack("<I", n)
    return header + pcm


def flac_version():
    out = subprocess.run(["flac", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    return out


ATTRIBUTION = """# Attribution for {stem}

This archive is a subset of PriMock57, cut and converted for the accuracy tests of Biorouter's local dictation. It is published as the release `{tag}` of https://github.com/BaranziniLab/biorouter-models. Biorouter never downloads it at run time.

## Credit

PriMock57: A Dataset Of Primary Care Mock Consultations, by Alex Papadopoulos Korfiatis, Francesco Moramarco, Radmila Sarac and Aleksandar Savkov (Babylon Health). Proceedings of the 60th Annual Meeting of the Association for Computational Linguistics, 2022. https://arxiv.org/abs/2204.00333

Source: {repo} at commit `{commit}`.

License: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/. The license text, copied from the source repository, is `LICENSE-primock57.md` in this archive.

## Changes made to the original

This archive is an adapted copy of part of PriMock57, not the original dataset. The Baranzini Lab at UCSF made these changes in November 2026:

- Selected {n_utt} utterances that name one of {n_terms} drugs ({n_doc} from the clinician channel, {n_pat} from the patient channel), and {n_gap} spans in which the clinician says nothing ({n_room} where both channels are silent, {n_other} where only the patient speaks).
- Cut each utterance from its channel recording at the transcript interval's boundaries, widened by 0.25 s on each side. Cut each silent span from 0.3 s inside its empty interval, at most 8 s long.
- Converted the cut audio from 16 kHz mono 16 bit WAV to FLAC. FLAC is lossless, so the samples are those of the source recordings.
- Copied the transcript text of each selected utterance from the TextGrid files into `manifest.jsonl` without edits, and counted the drug names in it. The source transcripts contain a few misspellings and inconsistent capitals; they are left as they are.
- Named each file after its source recording and the start time of the cut in milliseconds.

The authors and Babylon Health did not take part in making this subset and do not endorse Biorouter or the Baranzini Lab. The material is provided as is, without warranties, as the license states.

## Contents

| Path | What it is |
|---|---|
| `speech/*.flac` | {n_utt} utterances, {speech_s} s in all |
| `gaps/*.flac` | {n_gap} spans with no clinician speech, {gap_s} s in all |
| `manifest.jsonl` | One row per clip: source recording, interval, cut, transcript text, drug names counted, and the SHA-256 of the WAV, the samples and the FLAC file |
| `terms.json` | The {n_terms} drug names and how they were counted ({n_occ} occurrences in all) |
| `LICENSE-primock57.md` | The CC BY 4.0 license text |
| `ATTRIBUTION.md` | This file |
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selection", required=True)
    ap.add_argument("--license", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    sel = json.load(open(a.selection, encoding="utf-8"))
    rules = sel["rules"]
    src = sel["source"]
    commit = src["commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail("the source commit must be a full SHA")
    stem = f"{sel['name']}-r{sel['revision']}"
    tag = f"eval-{stem}"
    if shutil.which("flac") is None:
        fail("the flac command is required")
    fv = flac_version()

    # 1. TextGrids at the pinned commit.
    grids = {}
    for f, want in sorted(sel["textgrid_sha256"].items()):
        raw = fetch(src["textgrid_url"].format(commit=commit, file=f))
        if sha256(raw) != want:
            fail(f"{f}.TextGrid SHA-256 is {sha256(raw)}, expected {want}")
        grids[f] = intervals(raw.decode("utf-8"))
    print(f"fetched {len(grids)} TextGrids at {commit}")

    terms = sel["terms"]
    pad = rules["pad_seconds"]
    inset = rules["gap_inset_seconds"]
    gap_max = rules["gap_max_seconds"]

    # 2. Find and check every clip; compute its sample range.
    clips = []
    for u in sel["utterances"]:
        hit = [(s, e, x) for s, e, x in grids[u["file"]] if s == u["xmin"] and e == u["xmax"]]
        if len(hit) != 1:
            fail(f"{u['clip']}: no single TextGrid interval at {u['xmin']}..{u['xmax']}")
        s, e, text = hit[0]
        if not text or "<" in text:
            fail(f"{u['clip']}: empty or tagged interval")
        if not (rules["min_seconds"] <= e - s <= rules["max_seconds"]):
            fail(f"{u['clip']}: {e - s:.3f} s is outside the length rule")
        found = {t: term_count(text, t) for t in terms if term_count(text, t)}
        if not found:
            fail(f"{u['clip']}: names none of the listed drugs")
        if u["clip"] != f"{u['file']}_{int(s * 1000):07d}":
            fail(f"{u['clip']}: name does not follow the interval start")
        clips.append({
            "set": "speech",
            "clip": u["clip"],
            "file": u["file"],
            "role": u["file"].rsplit("_", 1)[1],
            "category": None,
            "interval": [s, e],
            "cut": [s - pad, e + pad],
            "text": text,
            "terms": found,
            "wav_sha256": u["wav_sha256"],
        })
    for g in sel["gaps"]:
        doc = grids[g["file"]]
        hit = [(s, e) for s, e, x in doc if not x and s == g["interval_xmin"] and e == g["interval_xmax"]]
        if len(hit) != 1:
            fail(f"{g['clip']}: no single empty interval at {g['interval_xmin']}..{g['interval_xmax']}")
        s, e = hit[0]
        if e - s < 3.5:
            fail(f"{g['clip']}: empty interval shorter than 3.5 s")
        a0, b0 = s + inset, min(e - inset, s + inset + gap_max)
        if b0 - a0 < 3.0:
            fail(f"{g['clip']}: gap cut shorter than 3 s")
        other = grids[g["file"].replace("_doctor", "_patient")]
        busy = any(x and os_ < b0 and oe > a0 for os_, oe, x in other)
        cat = "other_party" if busy else "room_tone"
        if cat != g["category"]:
            fail(f"{g['clip']}: category is {cat}, selection says {g['category']}")
        if g["clip"] != f"{g['file']}_{int(a0 * 1000):07d}":
            fail(f"{g['clip']}: name does not follow the cut start")
        clips.append({
            "set": "gap",
            "clip": g["clip"],
            "file": g["file"],
            "role": "doctor",
            "category": cat,
            "interval": [s, e],
            "cut": [a0, b0],
            "text": "",
            "terms": {},
            "wav_sha256": g["wav_sha256"],
        })

    # 3. Audio byte ranges, one header check per recording.
    headers = {}
    tmp = tempfile.mkdtemp(prefix="primock57-")
    rows = []
    for c in clips:
        url = src["audio_url"].format(commit=commit, file=c["file"])
        if url not in headers:
            h = fetch(url, (0, 43))
            if h[:4] != b"RIFF" or h[8:16] != b"WAVEfmt " or h[36:40] != b"data":
                fail(f"{c['file']}.wav: not a canonical 44 byte WAV header")
            fmt, ch, sr = struct.unpack_from("<HHI", h, 20)
            bits = struct.unpack_from("<H", h, 34)[0]
            if (fmt, ch, sr, bits) != (1, 1, RATE, 16):
                fail(f"{c['file']}.wav: expected 16 kHz mono 16 bit PCM, got {(fmt, ch, sr, bits)}")
            headers[url] = struct.unpack_from("<I", h, 40)[0] // 2
        n = headers[url]
        s0 = max(0, int(c["cut"][0] * RATE))
        s1 = min(n, int(c["cut"][1] * RATE))
        pcm = fetch(url, (44 + 2 * s0, 44 + 2 * s1 - 1))
        wav = wav_bytes(pcm)
        if sha256(wav) != c["wav_sha256"]:
            fail(f"{c['clip']}: WAV SHA-256 is {sha256(wav)}, expected {c['wav_sha256']}")
        sub = "speech" if c["set"] == "speech" else "gaps"
        os.makedirs(os.path.join(tmp, sub), exist_ok=True)
        wav_path = os.path.join(tmp, sub, c["clip"] + ".wav")
        flac_path = os.path.join(tmp, sub, c["clip"] + ".flac")
        with open(wav_path, "wb") as fh:
            fh.write(wav)

        # 4. FLAC, then decode and compare the samples.
        subprocess.run(["flac", "--silent", "--best", "--no-padding", "--no-seektable", "-f", "-o", flac_path, wav_path], check=True)
        back = subprocess.run(
            ["flac", "--silent", "-d", "-c", "--force-raw-format", "--endian=little", "--sign=signed", flac_path],
            check=True, capture_output=True,
        ).stdout
        if back != pcm:
            fail(f"{c['clip']}: the FLAC file does not decode to the source samples")
        os.remove(wav_path)
        rows.append({
            "clip": f"{sub}/{c['clip']}.flac",
            "set": c["set"],
            "role": c["role"],
            "category": c["category"],
            "source": f"audio/{c['file']}.wav",
            "transcript": f"transcripts/{c['file']}.TextGrid",
            "interval": c["interval"],
            "cut": c["cut"],
            "sample_range": [s0, s1],
            "seconds": round((s1 - s0) / RATE, 3),
            "text": c["text"],
            "terms": c["terms"],
            "wav_sha256": c["wav_sha256"],
            "pcm_sha256": sha256(pcm),
            "flac_sha256": sha256(open(flac_path, "rb").read()),
        })
    rows.sort(key=lambda r: r["clip"])

    # Totals, checked against what the selection expects.
    speech = [r for r in rows if r["set"] == "speech"]
    gaps = [r for r in rows if r["set"] == "gap"]
    occ = {}
    for r in speech:
        for t, k in r["terms"].items():
            occ[t] = occ.get(t, 0) + k
    counts = {
        "utterances": len(speech),
        "doctor": sum(1 for r in speech if r["role"] == "doctor"),
        "patient": sum(1 for r in speech if r["role"] == "patient"),
        "term_occurrences": sum(occ.values()),
        "distinct_terms": len(occ),
        "gaps": len(gaps),
        "room_tone": sum(1 for r in gaps if r["category"] == "room_tone"),
        "other_party": sum(1 for r in gaps if r["category"] == "other_party"),
    }
    for k, want in sel["expect"].items():
        if counts[k] != want:
            fail(f"{k} is {counts[k]}, the selection expects {want}")
    counts["speech_seconds"] = round(sum(r["seconds"] for r in speech), 3)
    counts["gap_seconds"] = round(sum(r["seconds"] for r in gaps), 3)

    # 5. Text files and the archive.
    manifest = "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows)
    terms_doc = {
        "terms": terms,
        "brands": sel["brands"],
        "matching": "Each term is counted as a whole word (no letter or digit on either side), ignoring case, in the transcript text.",
        "occurrences": {t: occ.get(t, 0) for t in terms},
    }
    attribution = ATTRIBUTION.format(
        stem=stem, tag=tag, repo=src["repository"], commit=commit,
        n_utt=counts["utterances"], n_doc=counts["doctor"], n_pat=counts["patient"],
        n_terms=len(terms), n_gap=counts["gaps"], n_room=counts["room_tone"], n_other=counts["other_party"],
        speech_s=f"{counts['speech_seconds']:.1f}", gap_s=f"{counts['gap_seconds']:.1f}", n_occ=counts["term_occurrences"],
    )
    files = {
        "ATTRIBUTION.md": attribution.encode("utf-8"),
        "LICENSE-primock57.md": open(a.license, "rb").read(),
        "manifest.jsonl": manifest.encode("utf-8"),
        "terms.json": (json.dumps(terms_doc, indent=2) + "\n").encode("utf-8"),
    }
    for r in rows:
        files[r["clip"]] = open(os.path.join(tmp, r["clip"]), "rb").read()

    os.makedirs(a.out, exist_ok=True)
    tar_name = f"{stem}.tar"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for name in sorted(files):
            data = files[name]
            ti = tarfile.TarInfo(f"{stem}/{name}")
            ti.size = len(data)
            ti.mtime = 0
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            tf.addfile(ti, io.BytesIO(data))
    with open(os.path.join(a.out, tar_name), "wb") as fh:
        fh.write(buf.getvalue())
    with open(os.path.join(a.out, "ATTRIBUTION.md"), "wb") as fh:
        fh.write(files["ATTRIBUTION.md"])
    info = {
        "tar": tar_name,
        "bytes": len(buf.getvalue()),
        "sha256": sha256(buf.getvalue()),
        "flac_version": fv,
        "flac_bytes": sum(len(files[r["clip"]]) for r in rows),
        "counts": counts,
    }
    with open(os.path.join(a.out, "build-info.json"), "w", encoding="utf-8") as fh:
        json.dump(info, fh, indent=2)
        fh.write("\n")
    shutil.rmtree(tmp)
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
