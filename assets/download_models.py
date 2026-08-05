from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import requests


OFFICIAL = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
MIRROR = "https://hf-mirror.com/Comfy-Org/MiniMax-H3/resolve/main"
STREAM_CHUNK = 1024 * 1024
PART_SIZE = 64 * 1024 * 1024
LOW_SPEED_GRACE_SECONDS = 45.0
LOW_SPEED_BYTES_PER_SECOND = 96 * 1024
REQUEST_TIMEOUT = (20, 45)
MODEL_KEYS = ("diffusion_model", "text_encoder", "video_vae", "audio_vae")
_thread_local = threading.local()


def source_label(url: str) -> str:
    host = urlparse(url).netloc.lower()
    if "hf-mirror" in host:
        return "hf-mirror"
    if "huggingface" in host:
        return "Hugging Face"
    return host or "unknown"


def model_sources(model_path: str, source_order: str) -> tuple[str, str]:
    official = f"{OFFICIAL}/{model_path}"
    mirror = f"{MIRROR}/{model_path}"
    if source_order == "mirror-first":
        return mirror, official
    return official, mirror


def get_session() -> requests.Session:
    session = getattr(_thread_local, "session", None)
    if session is None:
        session = requests.Session()
        session.headers.update(
            {
                "Accept-Encoding": "identity",
                "User-Agent": "MiniMaxH3-Windows-Installer/1.2",
            }
        )
        _thread_local.session = session
    return session


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
    """Best-effort progress update that must never abort a model download."""
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(payload)
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")

    for attempt in range(8):
        try:
            temporary.write_text(encoded, encoding="utf-8")
            os.replace(temporary, path)
            return
        except PermissionError as exc:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            if attempt == 7:
                print(
                    f"WARNING: progress file is busy; continuing without this update: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                return
            time.sleep(0.05 * (attempt + 1))
        except OSError as exc:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            print(
                f"WARNING: could not update progress file; continuing: {exc}",
                file=sys.stderr,
                flush=True,
            )
            return


def completed_before(models: tuple[dict[str, Any], ...], index: int) -> int:
    return sum(model["size"] for model in models[:index])


class ProgressTracker:
    def __init__(
        self,
        status_path: Path,
        models: tuple[dict[str, Any], ...],
        profile_id: str,
        index: int,
        model: dict[str, Any],
        base_bytes: int,
        mode: str,
    ) -> None:
        self.status_path = status_path
        self.models = models
        self.profile_id = profile_id
        self.index = index
        self.model = model
        self.base_bytes = base_bytes
        self.mode = mode
        self.lock = threading.Lock()
        self.parts: dict[str, int] = {}
        self.sources: dict[int, str] = {}
        self.connections = 1
        self.phase = "download"
        self.last_sample_time = time.monotonic()
        self.last_sample_bytes = base_bytes
        self.smoothed_speed = 0.0

    def set_connections(self, connections: int) -> None:
        with self.lock:
            self.connections = max(1, int(connections))

    def set_source(self, source: str) -> None:
        with self.lock:
            self.sources[threading.get_ident()] = source

    def clear_source(self) -> None:
        with self.lock:
            self.sources.pop(threading.get_ident(), None)

    def update_part(self, key: str, size: int) -> None:
        with self.lock:
            self.parts[key] = max(0, int(size))

    def set_phase(self, phase: str) -> None:
        with self.lock:
            self.phase = phase

    def emit(self, force: bool = False) -> None:
        del force
        with self.lock:
            now = time.monotonic()
            file_bytes = min(self.model["size"], self.base_bytes + sum(self.parts.values()))
            elapsed = now - self.last_sample_time
            if elapsed > 0:
                instantaneous = max(0.0, (file_bytes - self.last_sample_bytes) / elapsed)
                if self.smoothed_speed <= 0:
                    self.smoothed_speed = instantaneous
                else:
                    self.smoothed_speed = self.smoothed_speed * 0.72 + instantaneous * 0.28
            self.last_sample_time = now
            self.last_sample_bytes = file_bytes
            speed = self.smoothed_speed if self.phase == "download" else 0.0
            remaining = max(0, self.model["size"] - file_bytes)
            eta = int(remaining / speed) if speed > 1024 else -1
            source_names = sorted(set(self.sources.values()))
            source = "+".join(source_names) if source_names else ""
            payload = {
                "profile": self.profile_id,
                "index": self.index + 1,
                "count": len(self.models),
                "name": self.model["name"],
                "phase": self.phase,
                "file_bytes": file_bytes,
                "file_size": self.model["size"],
                "completed_bytes": completed_before(self.models, self.index)
                + (self.model["size"] if self.phase == "verify" else file_bytes),
                "total_bytes": sum(item["size"] for item in self.models),
                "source": source,
                "connections": self.connections,
                "speed_bps": int(speed),
                "eta_seconds": eta,
                "download_mode": self.mode,
            }
        write_status(self.status_path, payload)


def report_verify(
    status_path: Path,
    models: tuple[dict[str, Any], ...],
    profile_id: str,
    index: int,
    model: dict[str, Any],
    file_bytes: int,
) -> None:
    write_status(
        status_path,
        {
            "profile": profile_id,
            "index": index + 1,
            "count": len(models),
            "name": model["name"],
            "phase": "verify",
            "file_bytes": file_bytes,
            "file_size": model["size"],
            "completed_bytes": completed_before(models, index) + model["size"],
            "total_bytes": sum(item["size"] for item in models),
            "source": "",
            "connections": 1,
            "speed_bps": 0,
            "eta_seconds": -1,
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
    last_report = 0.0
    with path.open("rb") as handle:
        while True:
            data = handle.read(8 * STREAM_CHUNK)
            if not data:
                break
            digest.update(data)
            done += len(data)
            now = time.monotonic()
            if now - last_report >= 0.5:
                report_verify(status_path, models, profile_id, index, model, done)
                last_report = now
    report_verify(status_path, models, profile_id, index, model, done)
    return digest.hexdigest().upper()


def validate_content_range(response: requests.Response, start: int, end: int, total: int) -> None:
    if response.status_code != 206:
        raise RuntimeError(f"range request was not honored (HTTP {response.status_code})")
    content_range = response.headers.get("Content-Range", "")
    expected_prefix = f"bytes {start}-{end}/"
    if not content_range.startswith(expected_prefix):
        raise RuntimeError(f"unexpected Content-Range: {content_range!r}")
    try:
        response_total = int(content_range.rsplit("/", 1)[1])
    except (ValueError, IndexError) as exc:
        raise RuntimeError(f"invalid Content-Range: {content_range!r}") from exc
    if response_total != total:
        raise RuntimeError(f"remote size changed: {response_total} != {total}")


def probe_source(url: str, total: int) -> bool:
    session = requests.Session()
    try:
        response = session.get(
            url,
            headers={
                "Range": "bytes=0-0",
                "Accept-Encoding": "identity",
                "User-Agent": "MiniMaxH3-Windows-Installer/1.2",
            },
            stream=True,
            timeout=(15, 20),
            allow_redirects=True,
        )
        with response:
            validate_content_range(response, 0, 0, total)
            next(response.iter_content(chunk_size=1), b"")
        return True
    except Exception as exc:
        print(f"Range probe failed for {source_label(url)}: {exc}", flush=True)
        return False
    finally:
        session.close()


def part_directory(destination: Path) -> Path:
    return destination.with_name(destination.name + ".parts")


def prepare_part_directory(destination: Path, model: dict[str, Any]) -> Path:
    root = part_directory(destination)
    manifest = root / "manifest.json"
    expected = {
        "size": model["size"],
        "sha256": model["sha256"],
        "part_size": PART_SIZE,
    }
    if root.exists():
        try:
            current = load_json(manifest)
        except Exception:
            current = None
        if current != expected:
            shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True, exist_ok=True)
    temporary = manifest.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(expected), encoding="utf-8")
    os.replace(temporary, manifest)
    return root


def build_ranges(start: int, total: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    cursor = start
    while cursor < total:
        end = min(total - 1, cursor + PART_SIZE - 1)
        ranges.append((cursor, end))
        cursor = end + 1
    return ranges


def part_path(root: Path, start: int, end: int) -> Path:
    return root / f"{start:020d}-{end:020d}.part"


def valid_part_size(path: Path, expected: int) -> int:
    if not path.exists():
        return 0
    size = path.stat().st_size
    if size > expected:
        path.unlink()
        return 0
    return size


def download_part(
    sources: tuple[str, str],
    destination: Path,
    start: int,
    end: int,
    total: int,
    tracker: ProgressTracker,
) -> None:
    expected = end - start + 1
    key = destination.name
    current = valid_part_size(destination, expected)
    tracker.update_part(key, current)
    if current == expected:
        return

    errors: list[str] = []
    source_attempts = max(4, len(sources) * 3)
    for attempt in range(source_attempts):
        url = sources[attempt % len(sources)]
        label = source_label(url)
        tracker.set_source(label)
        session = get_session()
        try:
            while current < expected:
                request_start = start + current
                headers = {"Range": f"bytes={request_start}-{end}"}
                before = current
                started = time.monotonic()
                with session.get(
                    url,
                    headers=headers,
                    stream=True,
                    timeout=REQUEST_TIMEOUT,
                    allow_redirects=True,
                ) as response:
                    validate_content_range(response, request_start, end, total)
                    mode = "ab" if current else "wb"
                    with destination.open(mode) as output:
                        for chunk in response.iter_content(chunk_size=STREAM_CHUNK):
                            if not chunk:
                                continue
                            output.write(chunk)
                            current += len(chunk)
                            tracker.update_part(key, current)
                            elapsed = time.monotonic() - started
                            transferred = current - before
                            if (
                                elapsed >= LOW_SPEED_GRACE_SECONDS
                                and transferred / elapsed < LOW_SPEED_BYTES_PER_SECOND
                            ):
                                raise RuntimeError(
                                    f"sustained speed below {LOW_SPEED_BYTES_PER_SECOND / 1024:.0f} KiB/s"
                                )
                            if current > expected:
                                raise RuntimeError("range response exceeded requested size")
                if current == before:
                    raise RuntimeError("connection closed without receiving data")
            return
        except Exception as exc:
            errors.append(f"{label}: {exc}")
            print(
                f"Part {start}-{end} source failed; keeping {current}/{expected} bytes: {label}: {exc}",
                flush=True,
            )
            time.sleep(min(1.0 + attempt * 0.5, 4.0))
        finally:
            tracker.clear_source()
    raise RuntimeError(f"part {start}-{end} failed after retries: {' | '.join(errors[-4:])}")


def download_ranges(
    sources: tuple[str, str],
    root: Path,
    ranges: list[tuple[int, int]],
    total: int,
    tracker: ProgressTracker,
    workers: int,
) -> list[str]:
    tracker.set_connections(workers)
    failures: list[str] = []
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="h3-download") as executor:
        futures = {}
        for start, end in ranges:
            path = part_path(root, start, end)
            expected = end - start + 1
            tracker.update_part(path.name, valid_part_size(path, expected))
            future = executor.submit(download_part, sources, path, start, end, total, tracker)
            futures[future] = (start, end)

        pending = set(futures)
        last_emit = 0.0
        while pending:
            done = {future for future in pending if future.done()}
            for future in done:
                pending.remove(future)
                try:
                    future.result()
                except Exception as exc:
                    start, end = futures[future]
                    failures.append(f"{start}-{end}: {exc}")
            now = time.monotonic()
            if now - last_emit >= 0.75:
                tracker.emit()
                last_emit = now
            if pending:
                time.sleep(0.2)
    tracker.emit(force=True)
    return failures


def merge_parts(destination: Path, root: Path, ranges: list[tuple[int, int]], tracker: ProgressTracker) -> None:
    tracker.set_phase("merge")
    tracker.set_connections(1)
    tracker.emit(force=True)
    with destination.open("ab") as output:
        for start, end in ranges:
            path = part_path(root, start, end)
            expected = end - start + 1
            actual = valid_part_size(path, expected)
            if actual != expected:
                raise RuntimeError(f"part is incomplete before merge: {path.name} ({actual}/{expected})")
            with path.open("rb") as source:
                shutil.copyfileobj(source, output, length=8 * STREAM_CHUNK)
            output.flush()
            os.fsync(output.fileno())
            path.unlink()
            tracker.base_bytes += expected
            tracker.parts.pop(path.name, None)
            tracker.emit(force=True)
    shutil.rmtree(root, ignore_errors=True)


def choose_worker_plans(mode: str, remaining: int, primary_supports_ranges: bool) -> list[int]:
    if not primary_supports_ranges:
        return [1]
    if mode == "stable":
        return [1]
    if mode == "accelerated":
        return [4, 2, 1]
    if remaining < 256 * 1024 * 1024:
        return [2, 1]
    return [4, 2, 1]


def download_model(
    comfy_root: Path,
    status_path: Path,
    models: tuple[dict[str, Any], ...],
    profile_id: str,
    index: int,
    model: dict[str, Any],
    source_order: str,
    download_mode: str,
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
            shutil.rmtree(part_directory(destination), ignore_errors=True)
            return
        print(f"Checksum mismatch; downloading again: {model['name']}", flush=True)
        destination.unlink()
        shutil.rmtree(part_directory(destination), ignore_errors=True)

    base_size = destination.stat().st_size if destination.exists() else 0
    remaining = expected_size - base_size
    if remaining <= 0:
        return

    sources = model_sources(model["path"], source_order)
    print(
        f"Download mode for {model['name']}: {download_mode}; existing prefix {base_size} bytes",
        flush=True,
    )
    primary_ranges = probe_source(sources[0], expected_size)
    if not primary_ranges and probe_source(sources[1], expected_size):
        sources = (sources[1], sources[0])
        primary_ranges = True
        print(f"Primary source changed to {source_label(sources[0])} after range probe.", flush=True)

    root = prepare_part_directory(destination, model)
    ranges = build_ranges(base_size, expected_size)
    tracker = ProgressTracker(
        status_path,
        models,
        profile_id,
        index,
        model,
        base_size,
        download_mode,
    )

    plans = choose_worker_plans(download_mode, remaining, primary_ranges)
    last_failures: list[str] = []
    for workers in plans:
        print(f"Trying {workers} download connection(s) for {model['name']}.", flush=True)
        failures = download_ranges(sources, root, ranges, expected_size, tracker, workers)
        if not failures:
            break
        last_failures = failures
        print(
            f"{len(failures)} part(s) failed with {workers} connection(s); retrying with a safer plan.",
            flush=True,
        )
    else:
        raise RuntimeError("model parts failed after automatic downgrade:\n" + "\n".join(last_failures[-8:]))

    merge_parts(destination, root, ranges, tracker)
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
    parser.add_argument(
        "--download-mode",
        choices=("auto", "stable", "accelerated"),
        default="auto",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    profile = resolve_profile(args.profiles, args.profile)
    models = resolve_models(args.catalog, profile)
    total = sum(item["size"] for item in models)
    print(f"Selected profile: {profile['id']} ({profile['label']})", flush=True)
    print(f"Selected model download: {total / (1024 ** 3):.2f} GiB", flush=True)
    print(f"Model source order: {args.source_order}", flush=True)
    print(f"Model download mode: {args.download_mode}", flush=True)
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
            args.download_mode,
        )
    print("All MiniMax H3 models are ready.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
