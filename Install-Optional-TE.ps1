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
    Write-Host '正在下载最新 TE-Speed MiniMax H3 可选加速组件...'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

    Write-Host '正在解压...'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $root) { throw 'TE-Speed 压缩包解压后没有找到项目目录。' }
    $installer = Join-Path $root.FullName 'Install-TE.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'TE-Speed 安装脚本缺失。' }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $installer
    exit $LASTEXITCODE
} catch {
    Write-Host ("TE-Speed 可选组件启动失败：" + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "无法启动 TE-Speed 可选组件：`n`n$($_.Exception.Message)`n`n你也可以直接下载 dudulu2/TE-minimaxH3 的 ZIP。",
        'TE-Speed 下载/启动失败', 'OK', 'Error') | Out-Null
    exit 1
}
