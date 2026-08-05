from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import requests


OFFICIAL = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
MIRROR = "https://hf-mirror.com/Comfy-Org/MiniMax-H3/resolve/main"
CHUNK_RANGE = 32 * 1024 * 1024
STREAM_CHUNK = 1024 * 1024

MODELS = (
    {
        "folder": "diffusion_models",
        "name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
        "size": 20_970_379_616,
        "sha256": "E889202C41DAFB67B10D67B97F0D8541508036A6090AF23425A5C2615D03C47A",
    },
    {
        "folder": "text_encoders",
        "name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        "size": 15_687_142_551,
        "sha256": "35A88D51044231FE332301D7A62AA81E3F2CBA62FEBEB446E2C1E3E0EF76F2C6",
    },
    {
        "folder": "vae",
        "name": "minimax_h3_video_vae_fp16.safetensors",
        "size": 5_207_808_496,
        "sha256": "7C1F131492E7EDDACAAC9069A61B81BDD39DE5CC96561E677C5EAB1CDCE5E522",
    },
    {
        "folder": "vae",
        "name": "minimax_h3_audio_vae_fp32.safetensors",
        "size": 605_254_808,
        "sha256": "8E505D95DD1561D47ABD43D4238FD40D9BB1AE9E147ED0A4CBA778D76AE4DB48",
    },
)


def write_status(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    os.replace(temporary, path)


def completed_before(index: int) -> int:
    return sum(model["size"] for model in MODELS[:index])


def report(status_path: Path, index: int, model: dict, file_bytes: int, phase: str) -> None:
    write_status(
        status_path,
        {
            "index": index + 1,
            "count": len(MODELS),
            "name": model["name"],
            "phase": phase,
            "file_bytes": file_bytes,
            "file_size": model["size"],
            "completed_bytes": completed_before(index)
            + (model["size"] if phase == "verify" else min(file_bytes, model["size"])),
            "total_bytes": sum(item["size"] for item in MODELS),
        },
    )


def hash_file(path: Path, status_path: Path, index: int, model: dict) -> str:
    digest = hashlib.sha256()
    done = 0
    with path.open("rb") as handle:
        while True:
            data = handle.read(8 * STREAM_CHUNK)
            if not data:
                break
            digest.update(data)
            done += len(data)
            report(status_path, index, model, done, "verify")
    return digest.hexdigest().upper()


def fetch_range(session: requests.Session, url: str, destination: Path, start: int, end: int) -> int:
    headers = {
        "Range": f"bytes={start}-{end}",
        "Accept-Encoding": "identity",
        "User-Agent": "MiniMaxH3-Windows-Installer/1.0",
    }
    with session.get(url, headers=headers, stream=True, timeout=(25, 180), allow_redirects=True) as response:
        if start > 0 and response.status_code != 206:
            raise RuntimeError(f"resume range was not honored (HTTP {response.status_code})")
        response.raise_for_status()
        mode = "wb" if start == 0 else "ab"
        with destination.open(mode) as output:
            for chunk in response.iter_content(chunk_size=STREAM_CHUNK):
                if chunk:
                    output.write(chunk)
    return destination.stat().st_size


def download_model(comfy_root: Path, status_path: Path, index: int, model: dict) -> None:
    destination = comfy_root / "models" / model["folder"] / model["name"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected_size = model["size"]

    if destination.exists() and destination.stat().st_size > expected_size:
        print(f"Removing oversized file: {destination}", flush=True)
        destination.unlink()

    if destination.exists() and destination.stat().st_size == expected_size:
        print(f"Verifying existing model: {model['name']}", flush=True)
        if hash_file(destination, status_path, index, model) == model["sha256"]:
            print(f"Verified: {model['name']}", flush=True)
            return
        print(f"Checksum mismatch; downloading again: {model['name']}", flush=True)
        destination.unlink()

    relative = f"{model['folder']}/{model['name']}"
    sources = (f"{OFFICIAL}/{relative}", f"{MIRROR}/{relative}")
    errors: list[str] = []
    session = requests.Session()
    try:
        for attempt in range(6):
            source = sources[attempt % len(sources)]
            try:
                print(f"Source {attempt + 1}/6 for {model['name']}: {source}", flush=True)
                while not destination.exists() or destination.stat().st_size < expected_size:
                    start = destination.stat().st_size if destination.exists() else 0
                    end = min(expected_size - 1, start + CHUNK_RANGE - 1)
                    current = fetch_range(session, source, destination, start, end)
                    if current > expected_size:
                        raise RuntimeError("downloaded file is larger than expected")
                    report(status_path, index, model, current, "download")
                break
            except Exception as exc:  # Network failures are retried on the alternate source.
                message = f"{source}: {exc}"
                errors.append(message)
                print(f"Source failed; partial file kept for resume: {message}", flush=True)
                time.sleep(min(2 + attempt * 2, 10))
        else:
            raise RuntimeError("all official/mirror attempts failed:\n" + "\n".join(errors))
    finally:
        session.close()

    actual_size = destination.stat().st_size
    if actual_size != expected_size:
        raise RuntimeError(f"size mismatch for {model['name']}: {actual_size} != {expected_size}")
    print(f"Verifying SHA-256: {model['name']}", flush=True)
    actual_hash = hash_file(destination, status_path, index, model)
    if actual_hash != model["sha256"]:
        raise RuntimeError(
            f"SHA-256 mismatch for {model['name']}: {actual_hash} != {model['sha256']}"
        )
    print(f"Verified: {model['name']}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--comfy-root", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    args = parser.parse_args()
    for index, model in enumerate(MODELS):
        download_model(args.comfy_root, args.status, index, model)
    print("All MiniMax H3 models are ready.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
