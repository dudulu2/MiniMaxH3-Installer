#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'Enable-H3-Heretic-Encoder.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "Missing core script: $source"
}

$raw = [IO.File]::ReadAllText($source)

# Keep the core switch logic intact; only override source priority at runtime.
$oldOrder = "@('https://huggingface.co','https://hf-mirror.com')"
$newOrder = "@('https://hf-mirror.com','https://huggingface.co')"
$raw = $raw.Replace($oldOrder, $newOrder)

# Fail over faster when the preferred mirror cannot establish/respond,
# while retaining a long read/write timeout for the 20+ GiB model transfer.
$raw = $raw.Replace('$req.Timeout=600000;$req.ReadWriteTimeout=600000', '$req.Timeout=90000;$req.ReadWriteTimeout=600000')

if (-not $raw.Contains($newOrder)) {
    throw 'Could not apply mirror-first source priority. Core script format may have changed.'
}

Write-Host '[INFO] Download route: hf-mirror.com first -> Hugging Face official fallback'
Write-Host '[INFO] Partial .part download is retained for resume/source fallback when supported.'

$temp = Join-Path $env:TEMP ("H3-Heretic-MirrorFirst-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
try {
    [IO.File]::WriteAllText($temp, $raw, (New-Object Text.UTF8Encoding($true)))
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $temp
    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
