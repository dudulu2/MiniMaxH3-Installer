from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import requests


OFFICIAL = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
MIRROR = "https://hf-mirror.com/Comfy-Org/MiniMax-H3/resolve/main"
CHUNK_RANGE = 32 * 1024 * 1024
STREAM_CHUNK = 1024 * 1024
MODEL_KEYS = ("diffusion_model", "text_encoder", "video_vae", "audio_vae")


def model_sources(model_path: str, source_order: str) -> tuple[str, str]:
    official = f"{OFFICIAL}/{model_path}"
    mirror = f"{MIRROR}/{model_path}"
    if source_order == "mirror-first":
        return mirror, official
    return official, mirror


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def resolve_profile(profiles_path: Path, profile_id: str) -> dict[str, Any]:
    payload = load_json(profiles_path)
    profiles = payload.get("profiles", [])
    for profile in profiles:
        if profile.get("id") == profile_id:
            return profile
    valid = ", ".join(item.get("id", "?") for item in profiles)
    raise ValueError(f"unknown profile {profile_id!r}; valid profiles: {valid}")


def resolve_models(catalog_path: Path, profile: dict[str, Any]) -> tuple[dict[str, Any], ...]:
    catalog = load_json(catalog_path)
    by_path = {item["path"]: item for item in catalog}
    models: list[dict[str, Any]] = []
    for key in MODEL_KEYS:
        relative = profile[key]
        item = by_path.get(relative)
        if not item:
            raise ValueError(f"profile references a model absent from catalog: {relative}")
        folder, name = relative.split("/", 1)
        size = item.get("size")
        sha256 = item.get("sha256")
        if not isinstance(size, int) or size <= 0:
            raise ValueError(f"catalog has invalid size for {relative}")
        if not isinstance(sha256, str) or len(sha256) != 64:
            raise ValueError(f"catalog has invalid SHA-256 for {relative}")
        models.append(
            {
                "folder": folder,
                "name": name,
                "path": relative,
                "size": size,
                "sha256": sha256.upper(),
            }
        )
    return tuple(models)


def write_status(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    os.replace(temporary, path)


def completed_before(models: tuple[dict[str, Any], ...], index: int) -> int:
    return sum(model["size"] for model in models[:index])


def report(
    status_path: Path,
    models: tuple[dict[str, Any], ...],
    profile_id: str,
    index: int,
    model: dict[str, Any],
    file_bytes: int,
    phase: str,
) -> None:
    total_bytes = sum(item["size"] for item in models)
    write_status(
        status_path,
        {
            "profile": profile_id,
            "index": index + 1,
            "count": len(models),
            "name": model["name"],
            "phase": phase,
            "file_bytes": file_bytes,
            "file_size": model["size"],
            "completed_bytes": completed_before(models, index)
            + (model["size"] if phase == "verify" else min(file_bytes, model["size"])),
            "total_bytes": total_bytes,
        },
    )


def hash_file(
    path: Path,
    status_path: Path,
    models: tuple[dict[str, Any], ...],
    profile_id: str,
    index: int,
    model: dict[str, Any],
) -> str:
    digest = hashlib.sha256()
    done = 0
    with path.open("rb") as handle:
        while True:
            data = handle.read(8 * STREAM_CHUNK)
            if not data:
                break
            digest.update(data)
            done += len(data)
            report(status_path, models, profile_id, index, model, done, "verify")
    return digest.hexdigest().upper()


def fetch_range(session: requests.Session, url: str, destination: Path, start: int, end: int) -> int:
    headers = {
        "Range": f"bytes={start}-{end}",
        "Accept-Encoding": "identity",
        "User-Agent": "MiniMaxH3-Windows-Installer/1.1",
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


def download_model(
    comfy_root: Path,
    status_path: Path,
    models: tuple[dict[str, Any], ...],
    profile_id: str,
    index: int,
    model: dict[str, Any],
    source_order: str,
) -> None:
    destination = comfy_root / "models" / model["folder"] / model["name"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected_size = model["size"]

    if destination.exists() and destination.stat().st_size > expected_size:
        print(f"Removing oversized file: {destination}", flush=True)
        destination.unlink()

    if destination.exists() and destination.stat().st_size == expected_size:
        print(f"Verifying existing model: {model['name']}", flush=True)
        if hash_file(destination, status_path, models, profile_id, index, model) == model["sha256"]:
            print(f"Verified: {model['name']}", flush=True)
            return
        print(f"Checksum mismatch; downloading again: {model['name']}", flush=True)
        destination.unlink()

    sources = model_sources(model["path"], source_order)
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
                    report(status_path, models, profile_id, index, model, current, "download")
                break
            except Exception as exc:
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
    actual_hash = hash_file(destination, status_path, models, profile_id, index, model)
    if actual_hash != model["sha256"]:
        raise RuntimeError(
            f"SHA-256 mismatch for {model['name']}: {actual_hash} != {model['sha256']}"
        )
    print(f"Verified: {model['name']}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--comfy-root", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument(
        "--source-order",
        choices=("official-first", "mirror-first"),
        default="official-first",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    profile = resolve_profile(args.profiles, args.profile)
    models = resolve_models(args.catalog, profile)
    total = sum(item["size"] for item in models)
    print(f"Selected profile: {profile['id']} ({profile['label']})", flush=True)
    print(f"Selected model download: {total / (1024 ** 3):.2f} GiB", flush=True)
    print(f"Model source order: {args.source_order}", flush=True)
    for item in models:
        print(f"  {item['path']} | {item['size']} | {item['sha256']}", flush=True)
    if args.dry_run:
        return 0

    for index, model in enumerate(models):
        download_model(
            args.comfy_root,
            args.status,
            models,
            profile["id"],
            index,
            model,
            args.source_order,
        )
    print("All MiniMax H3 models are ready.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
