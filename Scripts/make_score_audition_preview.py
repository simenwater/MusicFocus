#!/usr/bin/env python3
"""Pack locally recognized events + a rendered WAV for the DEBUG audition UI.

This does not recognize PDFs, upload scores, or distribute model weights. Input
events use the research demo schema (time/seconds, staff/measure/pitch/point).
Coordinates are relative to the raster crop; use the original render's DPI and
crop offset. Only unrotated pages whose crop/media boxes coincide are supported.
"""
import argparse
import array
import base64
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("pdf", "events", "audio", "click", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--page", type=int, default=1)
    parser.add_argument("--page-height", type=float, required=True)
    parser.add_argument("--dpi", type=float, required=True)
    parser.add_argument("--crop-x", type=float, default=0)
    parser.add_argument("--crop-y", type=float, default=0)
    parser.add_argument("--tempo", type=float, default=80)
    parser.add_argument("--beats-per-bar", type=int, default=3)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--notice", required=True)
    args = parser.parse_args()
    if not (0 < args.duration <= 1800 and 20 <= args.tempo <= 300 and args.dpi > 0):
        parser.error("Invalid duration, tempo or DPI")
    events = json.loads(args.events.read_text())
    cues = [dict(time=e["time"], duration=e["seconds"], page=args.page, staff=e["staff"], measure=e["measure"],
                 x=(e["point"][0] + args.crop_x) * 72 / args.dpi,
                 y=args.page_height - (e["point"][1] + args.crop_y) * 72 / args.dpi)
            for e in events if e["pitch"] != "R" and e.get("point") is not None]
    cues.sort(key=lambda e: (e["time"], e["staff"]))
    with wave.open(str(args.audio)) as wav:
        if wav.getsampwidth() != 2 or wav.getframerate() != 44100:
            parser.error("Audio must be 44.1 kHz 16-bit PCM")
        channels = wav.getnchannels()
        raw = array.array("h", wav.readframes(wav.getnframes()))
    frames = round(args.duration * 44100)
    piano = [sum(raw[i*channels:(i+1)*channels]) / channels if (i+1)*channels <= len(raw) else 0 for i in range(frames)]
    with wave.open(str(args.click)) as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 44100):
            parser.error("Click must be mono 44.1 kHz 16-bit PCM")
        click = array.array("h", wav.readframes(wav.getnframes()))
    mixed = list(piano)
    musical_end = max(e["time"] + e["seconds"] for e in events)
    for beat in range(math.ceil(musical_end * args.tempo / 60 - 1e-8)):
        start = round(beat * 60 / args.tempo * 44100)
        gain = 0.7 if beat % args.beats_per_bar == 0 else 0.45
        for i, value in enumerate(click):
            if start+i < frames:
                mixed[start+i] += value * gain
    gain = min(2.5, 29000 / max(1, max(abs(x) for x in piano), max(abs(x) for x in mixed)))
    with tempfile.TemporaryDirectory(prefix="score-audition-") as folder:
        encoded = []
        for name, samples in (("piano", piano), ("clicks", mixed)):
            wav_path = Path(folder) / (name + ".wav")
            mp3_path = Path(folder) / (name + ".mp3")
            with wave.open(str(wav_path), "wb") as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(44100)
                wav.writeframes(array.array("h", (round(x * gain) for x in samples)).tobytes())
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav_path), "-c:a", "libmp3lame", "-b:a", "80k", str(mp3_path)], check=True)
            encoded.append(base64.b64encode(mp3_path.read_bytes()).decode())
    package = dict(version=1, sourceSHA256=hashlib.sha256(args.pdf.read_bytes()).hexdigest(),
                   title=args.title, notice=args.notice, tempo=args.tempo, duration=args.duration,
                   cues=cues, audio=encoded[0], audioWithClicks=encoded[1])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(package, ensure_ascii=False, separators=(",", ":")))
    print(json.dumps(dict(output=str(args.output), cues=len(cues), sourceSHA256=package["sourceSHA256"])))


if __name__ == "__main__":
    main()
