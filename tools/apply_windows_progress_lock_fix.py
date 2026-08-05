from pathlib import Path

py_path = Path("assets/download_models.py")
py_text = py_path.read_text(encoding="utf-8-sig")

old_write_status = '''def write_status(path: Path, payload: dict[str, Any]) -> None:\n    path.parent.mkdir(parents=True, exist_ok=True)\n    temporary = path.with_suffix(path.suffix + ".tmp")\n    temporary.write_text(json.dumps(payload), encoding="utf-8")\n    os.replace(temporary, path)\n'''

new_write_status = '''def write_status(path: Path, payload: dict[str, Any]) -> None:\n    \"\"\"Best-effort progress update that must never abort a model download.\n\n    Windows can briefly reject os.replace() while the installer UI is reading the\n    destination. Use a process-specific temporary file, retry transient sharing\n    violations, and treat the status file as non-critical after the retry budget.\n    \"\"\"\n    path.parent.mkdir(parents=True, exist_ok=True)\n    encoded = json.dumps(payload)\n    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")\n\n    for attempt in range(8):\n        try:\n            temporary.write_text(encoded, encoding="utf-8")\n            os.replace(temporary, path)\n            return\n        except PermissionError as exc:\n            try:\n                temporary.unlink(missing_ok=True)\n            except OSError:\n                pass\n            if attempt == 7:\n                print(\n                    f"WARNING: progress file is busy; continuing without this update: {exc}",\n                    file=sys.stderr,\n                    flush=True,\n                )\n                return\n            time.sleep(0.05 * (attempt + 1))\n        except OSError as exc:\n            try:\n                temporary.unlink(missing_ok=True)\n            except OSError:\n                pass\n            print(\n                f"WARNING: could not update progress file; continuing: {exc}",\n                file=sys.stderr,\n                flush=True,\n            )\n            return\n'''

if old_write_status not in py_text:
    raise SystemExit("download_models.py write_status block not found")
py_text = py_text.replace(old_write_status, new_write_status, 1)
py_path.write_text(py_text, encoding="utf-8")

ps_path = Path("assets/hardware_profiles_install.ps1")
ps_text = ps_path.read_text(encoding="utf-8-sig")

marker = "function Install-H3Models {\n"
helper = r'''function Read-SharedJsonFile {
    param([string]$Path)

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $share
    )
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        $json = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    if (-not $json.Trim()) { return $null }
    return ($json | ConvertFrom-Json)
}

'''

if "function Read-SharedJsonFile" in ps_text:
    raise SystemExit("Read-SharedJsonFile already exists")
if marker not in ps_text:
    raise SystemExit("Install-H3Models marker not found")
ps_text = ps_text.replace(marker, helper + marker, 1)

old_read = '$state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json'
new_read = '$state = Read-SharedJsonFile -Path $statusPath'
if old_read not in ps_text:
    raise SystemExit("status read expression not found")
ps_text = ps_text.replace(old_read, new_read, 1)

old_cleanup = '    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue\n'
new_cleanup = '''    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue\n    Get-ChildItem -LiteralPath (Split-Path -Parent $statusPath) -Filter "model-progress.json*.tmp" -ErrorAction SilentlyContinue |\n        Remove-Item -Force -ErrorAction SilentlyContinue\n'''
if old_cleanup not in ps_text:
    raise SystemExit("status cleanup line not found")
ps_text = ps_text.replace(old_cleanup, new_cleanup, 1)

ps_path.write_text(ps_text, encoding="utf-8")
