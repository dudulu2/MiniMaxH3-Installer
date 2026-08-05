from pathlib import Path

path = Path("assets/download_models.py")
text = path.read_text(encoding="utf-8-sig")
text = text.replace(
    "    source_attempts = max(4, len(sources) * 3)\n",
    "    source_attempts = max(4, len(sources) * 2)\n",
    1,
)

start = text.index("def download_ranges(\n")
end = text.index("\ndef merge_parts(", start)
replacement = '''def download_ranges(
    sources: tuple[str, str],
    root: Path,
    ranges: list[tuple[int, int]],
    total: int,
    tracker: ProgressTracker,
    workers: int,
) -> list[str]:
    """Download with a bounded queue so a bad route degrades promptly.

    Only ``workers`` parts are in flight. After the first exhausted part failure,
    no later ranges are submitted; already running workers finish, then the
    caller retries the still-missing parts with a safer connection count.
    """
    tracker.set_connections(workers)
    failures: list[str] = []

    for start, end in ranges:
        path = part_path(root, start, end)
        tracker.update_part(path.name, valid_part_size(path, end - start + 1))

    next_index = 0
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="h3-download") as executor:
        futures: dict[Any, tuple[int, int]] = {}

        def submit_until_full() -> None:
            nonlocal next_index
            while not failures and next_index < len(ranges) and len(futures) < workers:
                start, end = ranges[next_index]
                next_index += 1
                path = part_path(root, start, end)
                future = executor.submit(download_part, sources, path, start, end, total, tracker)
                futures[future] = (start, end)

        submit_until_full()
        last_emit = 0.0
        while futures:
            done = [future for future in futures if future.done()]
            if done:
                for future in done:
                    start, end = futures.pop(future)
                    try:
                        future.result()
                    except Exception as exc:
                        failures.append(f"{start}-{end}: {exc}")
                if failures:
                    for future in list(futures):
                        if future.cancel():
                            futures.pop(future, None)
                else:
                    submit_until_full()

            now = time.monotonic()
            if now - last_emit >= 0.75:
                tracker.emit()
                last_emit = now
            if futures:
                time.sleep(0.2)

    tracker.emit(force=True)
    return failures
'''
text = text[:start] + replacement + text[end:]
path.write_text(text, encoding="utf-8")
