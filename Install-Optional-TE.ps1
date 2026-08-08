#requires -version 5.1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

try {
    $tempRoot = Join-Path $env:TEMP 'MiniMaxH3-TE-Speed'
    $zip = Join-Path $tempRoot 'TE-minimaxH3-main.zip'
    $extract = Join-Path $tempRoot 'extracted'
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

    $url = 'https://github.com/dudulu2/TE-minimaxH3/archive/refs/heads/main.zip'
    Write-Host 'Downloading the latest optional TE-Speed MiniMax H3 package...'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

    Write-Host 'Extracting TE-Speed package...'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $root) { throw 'The TE-Speed archive did not contain a project directory.' }
    $installer = Join-Path $root.FullName 'Install-TE.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Install-TE.ps1 is missing from the downloaded TE-Speed package.' }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $installer
    exit $LASTEXITCODE
} catch {
    Write-Host ("Could not start the optional TE-Speed installer: " + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "Could not start the optional TE-Speed installer.`n`n$($_.Exception.Message)`n`nYou can also download dudulu2/TE-minimaxH3 directly.",
        'TE-Speed download/start failed', 'OK', 'Error') | Out-Null
    exit 1
}
