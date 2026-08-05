#requires -version 5.1

[CmdletBinding()]
param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:InstallerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AssetsRoot = Join-Path $script:InstallerRoot "assets"
$script:RequiredFreeGiB = 60
$script:ModelBytes = [int64]42470585471
$script:IsInstalling = $false

function Pump-UI {
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    Pump-UI
}

function Set-Stage {
    param([string]$Text, [int]$Percent = -1)
    $lblStage.Text = $Text
    if ($Percent -ge 0) {
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $progress.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
    } else {
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
    Pump-UI
}

function Format-GiB {
    param([int64]$Bytes)
    return "{0:N1} GiB" -f ($Bytes / 1GB)
}

function Get-DriveFreeBytes {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not $root) { throw "Cannot identify the target drive: $Path" }
    return (New-Object IO.DriveInfo($root)).AvailableFreeSpace
}

function Get-NvidiaSmiPath {
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $standard = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path -LiteralPath $standard) { return $standard }
    return $null
}

function Get-TotalRamBytes {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMemoryStatus {
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
}
"@ -ErrorAction SilentlyContinue
        $status = New-Object NativeMemoryStatus+MEMORYSTATUSEX
        $status.dwLength = [Runtime.InteropServices.Marshal]::SizeOf([NativeMemoryStatus+MEMORYSTATUSEX])
        if ([NativeMemoryStatus]::GlobalMemoryStatusEx([ref]$status)) {
            return [int64]$status.ullTotalPhys
        }
        throw "GlobalMemoryStatusEx failed with error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    } catch {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.TotalVisibleMemorySize) {
            return [int64]$os.TotalVisibleMemorySize * 1KB
        }
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computer -and $computer.TotalPhysicalMemory) {
            return [int64]$computer.TotalPhysicalMemory
        }
        throw "Could not read system memory: $($_.Exception.Message)"
    }
}

function Get-HardwareReport {
    param([string]$InstallPath)

    $result = New-Object System.Collections.Generic.List[object]
    $blocking = $false
    $add = {
        param($Name, $Value, $Status, $Detail)
        $result.Add([PSCustomObject]@{ Name=$Name; Value=$Value; Status=$Status; Detail=$Detail })
        if ($Status -eq "FAIL") { $script:checkBlocking = $true }
    }
    $script:checkBlocking = $false

    $is64 = [Environment]::Is64BitOperatingSystem
    & $add "Windows" ($(if ($is64) { "64-bit" } else { "32-bit" })) ($(if ($is64) { "PASS" } else { "FAIL" })) "Windows 10/11 x64 is required."
    try {
        $ramBytes = Get-TotalRamBytes
        $ramOk = $ramBytes -ge [int64](14.5GB)
        & $add "System RAM" (Format-GiB $ramBytes) ($(if ($ramOk) { "PASS" } else { "FAIL" })) "16 GB is the supported minimum."
    } catch {
        & $add "System RAM" "Unknown" "WARN" ("Could not read total RAM: {0}" -f $_.Exception.Message)
    }

    $smi = Get-NvidiaSmiPath
    if (-not $smi) {
        & $add "NVIDIA GPU" "Not found" "FAIL" "Install an NVIDIA display driver first."
    } else {
        $gpuLine = (& $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if (-not $gpuLine) {
            & $add "NVIDIA GPU" "Query failed" "FAIL" "nvidia-smi could not read the GPU."
        } else {
            $parts = $gpuLine -split ",\s*"
            $gpuName = $parts[0]
            $vramMiB = [double]$parts[1]
            $driver = $parts[2]
            $vramOk = $vramMiB -ge 7600
            & $add "NVIDIA GPU" $gpuName ($(if ($vramOk) { "PASS" } else { "FAIL" })) ("VRAM {0:N0} MiB; 8 GB is required." -f $vramMiB)

            $driverMajor = 0
            [void][int]::TryParse(($driver -split '\.')[0], [ref]$driverMajor)
            $driverStatus = if ($driverMajor -ge 560) { "PASS" } else { "WARN" }
            & $add "NVIDIA driver" $driver $driverStatus "560 or newer is recommended for CUDA 12.6."
        }
    }

    try {
        $free = Get-DriveFreeBytes $InstallPath
        $freeOk = $free -ge ([int64]$script:RequiredFreeGiB * 1GB)
        & $add "Disk space" (Format-GiB $free) ($(if ($freeOk) { "PASS" } else { "FAIL" })) ("At least {0} GiB free is required; 70 GiB is recommended." -f $script:RequiredFreeGiB)
    } catch {
        & $add "Disk space" "Unknown" "FAIL" $_.Exception.Message
    }
    try {
        $port = Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch {
        $port = $null
    }
    if ($port) {
        & $add "Port 8188" ("In use by PID {0}" -f $port.OwningProcess) "WARN" "The launcher will not replace another program using this port."
    } else {
        & $add "Port 8188" "Available" "PASS" "ComfyUI will listen only on 127.0.0.1."
    }

    $fullPath = [IO.Path]::GetFullPath($InstallPath)
    $pathStatus = "PASS"
    $pathDetail = "A self-contained environment will be created here."
    if ($fullPath.StartsWith("\\")) {
        $pathStatus = "FAIL"
        $pathDetail = "Network paths are not supported."
    } elseif ($fullPath.Length -gt 100) {
        $pathStatus = "WARN"
        $pathDetail = "A shorter path reduces Python package path-length problems."
    }
    & $add "Install path" $fullPath $pathStatus $pathDetail

    return [PSCustomObject]@{ Items=$result; Blocking=$script:checkBlocking }
}

function Show-HardwareReport {
    $path = $txtPath.Text.Trim()
    if (-not $path) { return $null }
    $grid.Rows.Clear()
    try {
        $report = Get-HardwareReport $path
        foreach ($item in $report.Items) {
            $index = $grid.Rows.Add($item.Name, $item.Value, $item.Status, $item.Detail)
            $color = switch ($item.Status) {
                "PASS" { [Drawing.Color]::FromArgb(27, 122, 78) }
                "WARN" { [Drawing.Color]::FromArgb(174, 102, 0) }
                default { [Drawing.Color]::FromArgb(185, 28, 28) }
            }
            $grid.Rows[$index].Cells[2].Style.ForeColor = $color
        }
        if ($report.Blocking) {
            $lblCheck.Text = "Hardware check failed. See the red rows below."
            $lblCheck.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
        } else {
            $lblCheck.Text = "Ready to install. Warnings do not block installation."
            $lblCheck.ForeColor = [Drawing.Color]::FromArgb(27, 122, 78)
        }
        return $report
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Check failed", "OK", "Error") | Out-Null
        return $null
    }
}

function Invoke-ProcessChecked {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory = $script:InstallerRoot,
        [switch]$AllowFailure
    )
    Add-Log ("Run: {0} {1}" -f $FilePath, $Arguments)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start: $FilePath" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(250)) { Pump-UI }
    $outText = $stdout.Result
    $errText = $stderr.Result
    if ($outText) {
        foreach ($line in ($outText -split "`r?`n")) { if ($line.Trim()) { Add-Log $line.Trim() "CMD" } }
    }
    if ($errText) {
        foreach ($line in ($errText -split "`r?`n")) { if ($line.Trim()) { Add-Log $line.Trim() "CMD" } }
    }
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath"
    }
    return $process.ExitCode
}

function New-HttpClient {
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("MiniMaxH3-Windows-Installer/1.0")
    return $client
}

function Invoke-SimpleDownload {
    param([string]$Name, [string[]]$Urls, [string]$Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $lastError = $null
    foreach ($url in $Urls) {
        $client = New-HttpClient
        try {
            Add-Log "Downloading $Name from $url"
            $response = $client.GetAsync($url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            $response.EnsureSuccessStatusCode()
            $input = $response.Content.ReadAsStreamAsync().Result
            $output = New-Object IO.FileStream($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] (1MB)
                $total = [int64]0
                $length = $response.Content.Headers.ContentLength
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $output.Write($buffer, 0, $read)
                    $total += $read
                    if ($length -and $length -gt 0) {
                        Set-Stage ("Downloading {0}: {1:N1}/{2:N1} MiB" -f $Name, ($total/1MB), ($length/1MB)) ([int](100*$total/$length))
                    }
                }
            } finally {
                if ($output) { $output.Dispose() }
                if ($input) { $input.Dispose() }
                $response.Dispose()
            }
            Add-Log "$Name downloaded."
            return
        } catch {
            $lastError = $_.Exception
            Add-Log ("Source failed: {0}" -f $_.Exception.Message) "WARN"
        } finally {
            $client.Dispose()
        }
    }
    throw "All download sources failed for $Name. Last error: $($lastError.Message)"
}

function Invoke-ModelDownload {
    param(
        [string]$Name,
        [string[]]$Urls,
        [string]$Destination,
        [int64]$ExpectedBytes,
        [string]$ExpectedSha256
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        $existingLength = (Get-Item -LiteralPath $Destination).Length
        if ($existingLength -eq $ExpectedBytes) {
            Set-Stage "Verifying existing $Name" -1
            $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($hash -eq $ExpectedSha256) {
                Add-Log "$Name already exists and passed SHA-256 verification."
                return
            }
            Add-Log "$Name has an invalid checksum and will be downloaded again." "WARN"
            Remove-Item -LiteralPath $Destination -Force
        } elseif ($existingLength -gt $ExpectedBytes) {
            Add-Log "$Name is larger than expected and will be downloaded again." "WARN"
            Remove-Item -LiteralPath $Destination -Force
        } else {
            Add-Log ("Resuming {0} at {1:N1} GiB." -f $Name, ($existingLength/1GB))
        }
    }

    $sourceIndex = 0
    $lastError = $null
    while ((-not (Test-Path -LiteralPath $Destination)) -or ((Get-Item -LiteralPath $Destination).Length -lt $ExpectedBytes)) {
        if ($sourceIndex -ge $Urls.Count) {
            throw "All download sources failed for $Name. Last error: $($lastError.Message)"
        }
        $url = $Urls[$sourceIndex]
        $client = New-HttpClient
        try {
            Add-Log "Using source for ${Name}: $url"
            while ($true) {
                $offset = if (Test-Path -LiteralPath $Destination) { (Get-Item -LiteralPath $Destination).Length } else { [int64]0 }
                if ($offset -ge $ExpectedBytes) { break }
                $end = [Math]::Min($ExpectedBytes - 1, $offset + 32MB - 1)
                $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $url)
                $request.Headers.Range = New-Object Net.Http.Headers.RangeHeaderValue($offset, $end)
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
                if ($offset -gt 0 -and $response.StatusCode -ne [Net.HttpStatusCode]::PartialContent) {
                    throw "The server did not honor the resume range request."
                }
                $response.EnsureSuccessStatusCode()
                $stream = $response.Content.ReadAsStreamAsync().Result
                $mode = if ($offset -eq 0) { [IO.FileMode]::Create } else { [IO.FileMode]::Append }
                $file = New-Object IO.FileStream($Destination, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try {
                    $buffer = New-Object byte[] (1MB)
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $file.Write($buffer, 0, $read)
                    }
                } finally {
                    if ($file) { $file.Dispose() }
                    if ($stream) { $stream.Dispose() }
                    $response.Dispose()
                    $request.Dispose()
                }
                $done = (Get-Item -LiteralPath $Destination).Length
                Set-Stage ("Downloading {0}: {1:N2}/{2:N2} GiB" -f $Name, ($done/1GB), ($ExpectedBytes/1GB)) ([int](100*$done/$ExpectedBytes))
                if ($done -gt $ExpectedBytes) { throw "The downloaded file is larger than expected." }
            }
        } catch {
            $lastError = $_.Exception
            Add-Log ("Source failed; keeping the partial file for resume: {0}" -f $_.Exception.Message) "WARN"
            $sourceIndex++
        } finally {
            $client.Dispose()
        }
    }

    Set-Stage "Verifying SHA-256: $Name" -1
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256) {
        throw "SHA-256 mismatch for $Name. Expected $ExpectedSha256, got $actual."
    }
    Add-Log "$Name passed SHA-256 verification."
}

function Invoke-PipWithFallback {
    param([string]$Python, [string]$PackageArguments, [switch]$NeedsTorchIndex)
    $official = if ($NeedsTorchIndex) {
        "$PackageArguments --index-url https://download.pytorch.org/whl/cu126"
    } else {
        "$PackageArguments --index-url https://pypi.org/simple --extra-index-url https://download.pytorch.org/whl/cu126"
    }
    $mirror = if ($NeedsTorchIndex) {
        "$PackageArguments --index-url https://mirrors.aliyun.com/pytorch-wheels/cu126"
    } else {
        "$PackageArguments --index-url https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url https://mirrors.aliyun.com/pytorch-wheels/cu126"
    }
    $common = "-m pip $official --timeout 30 --retries 2 --no-cache-dir --disable-pip-version-check"
    $exit = Invoke-ProcessChecked $Python $common $script:InstallerRoot -AllowFailure
    if ($exit -ne 0) {
        Add-Log "Official Python package source failed; switching to mirrors." "WARN"
        Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 3 --no-cache-dir --disable-pip-version-check" -f $mirror) $script:InstallerRoot
    }
}

function Install-PythonRuntime {
    param([string]$InstallRoot)
    $pythonRoot = Join-Path $InstallRoot "runtime\python"
    $python = Join-Path $pythonRoot "python.exe"
    if (Test-Path -LiteralPath $python) {
        $version = (& $python -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null)
        if ($version -eq "3.10") {
            Add-Log "Existing private Python 3.10 runtime found."
            return $python
        }
        throw "The private Python runtime exists but is not Python 3.10: $python"
    }

    $cache = Join-Path $InstallRoot "downloads"
    $installer = Join-Path $cache "python-3.10.11-amd64.exe"
    Set-Stage "Downloading Python 3.10 runtime" -1
    Invoke-SimpleDownload "Python 3.10.11" @(
        "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
        "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe"
    ) $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "The Python installer signature is not valid. File was not executed. Status: $($signature.Status)"
    }
    Add-Log "Python installer signature verified: $($signature.SignerCertificate.Subject)"
    Set-Stage "Installing private Python runtime" -1
    $arguments = "/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 Include_pip=1 TargetDir=`"$pythonRoot`""
    Invoke-ProcessChecked $installer $arguments $InstallRoot
    if (-not (Test-Path -LiteralPath $python)) { throw "Python installation did not create $python" }
    return $python
}

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython)
    $sourceZip = Join-Path $script:AssetsRoot "ComfyUI-source.zip"
    $sourceHash = "71C2B7624D10AF93FF1158F11B1787D6296ED081B52AC86B9CA82530CE5AA754"
    if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Installer asset is missing: $sourceZip" }
    if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash -ne $sourceHash) { throw "Bundled ComfyUI source failed verification." }

    Set-Stage "Deploying fixed ComfyUI source" -1
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $InstallRoot -Force
    $comfyRoot = Join-Path $InstallRoot "ComfyUI"
    if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "ComfyUI source extraction failed." }

    $venvRoot = Join-Path $InstallRoot "runtime\venv"
    $venvPython = Join-Path $venvRoot "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Set-Stage "Creating isolated Python environment" -1
        Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot
    }

    Set-Stage "Preparing pip" -1
    Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel"

    Set-Stage "Installing PyTorch 2.8.0 CUDA 12.6" -1
    Invoke-PipWithFallback $venvPython "install torch==2.8.0+cu126 torchvision==0.23.0+cu126 torchaudio==2.8.0+cu126" -NeedsTorchIndex

    $constraints = Join-Path $InstallRoot "runtime\constraints-cu126.txt"
    @"
torch==2.8.0+cu126
torchvision==0.23.0+cu126
torchaudio==2.8.0+cu126
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    Set-Stage "Installing ComfyUI dependencies" -1
    $requirements = Join-Path $comfyRoot "requirements.txt"
    Invoke-PipWithFallback $venvPython ("install -r `"{0}`" -c `"{1}`"" -f $requirements, $constraints)

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='2.8.0+cu126'; assert torchvision.__version__=='0.23.0+cu126'; assert torchaudio.__version__=='2.8.0+cu126'; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0)); print('DynamicVRAM prerequisite ready')"
    Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}

function Install-H3Models {
    param([string]$ComfyRoot, [string]$Python, [string]$InstallRoot)
    $downloader = Join-Path $script:AssetsRoot "download_models.py"
    if (-not (Test-Path -LiteralPath $downloader)) { throw "Installer asset is missing: $downloader" }
    $statusPath = Join-Path $InstallRoot "downloads\model-progress.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`""
    $psi.WorkingDirectory = $InstallRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start the model downloader." }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(500)) {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $state = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                $overall = if ($state.total_bytes -gt 0) { [int](100 * $state.completed_bytes / $state.total_bytes) } else { 0 }
                $label = if ($state.phase -eq "verify") {
                    "Verifying $($state.name)"
                } else {
                    "Model $($state.index)/$($state.count): $($state.name) - $([Math]::Round($state.file_bytes/1GB, 2))/$([Math]::Round($state.file_size/1GB, 2)) GiB"
                }
                Set-Stage $label $overall
            } catch {
                Pump-UI
            }
        } else {
            Pump-UI
        }
    }
    $outText = $stdout.Result
    $errText = $stderr.Result
    foreach ($line in (($outText + "`n" + $errText) -split "`r?`n")) {
        if ($line.Trim()) { Add-Log $line.Trim() "MODEL" }
    }
    if ($process.ExitCode -ne 0) { throw "Model downloader failed with exit code $($process.ExitCode). See the installer log." }
}

function Assert-PowerShellScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
        throw "Generated PowerShell script failed syntax validation: $Path. $details"
    }
}
function Install-WorkflowAndLauncher {
    param([string]$InstallRoot, [string]$ComfyRoot, [string]$VenvPython)
    $workflowSource = Join-Path $script:AssetsRoot "MiniMax_H3_8GB.json"
    $workflowDir = Join-Path $ComfyRoot "user\default\workflows"
    New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
    Copy-Item -LiteralPath $workflowSource -Destination (Join-Path $workflowDir "MiniMax_H3_8GB.json") -Force

    $helperRoot = Join-Path $ComfyRoot "custom_nodes\minimax_h3_workflow_autoload"
    $helperWeb = Join-Path $helperRoot "web"
    New-Item -ItemType Directory -Force -Path $helperWeb | Out-Null
    @'
WEB_DIRECTORY = "./web"
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
'@ | Set-Content -LiteralPath (Join-Path $helperRoot "__init__.py") -Encoding ASCII
    @'
import { app } from "../../../scripts/app.js";

app.registerExtension({
    name: "MiniMaxH3.FirstRunWorkflow",
    async setup() {
        const key = "minimax-h3-workflow-loaded-v1";
        if (localStorage.getItem(key)) return;
        try {
            const path = encodeURIComponent("workflows/MiniMax_H3_8GB.json");
            const response = await fetch(`/api/userdata/${path}`);
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const workflow = await response.json();
            await app.loadGraphData(workflow, true, true, "MiniMax_H3_8GB.json");
            localStorage.setItem(key, "1");
        } catch (error) {
            console.error("MiniMax H3 workflow autoload failed", error);
        }
    }
});
'@ | Set-Content -LiteralPath (Join-Path $helperWeb "autoload.js") -Encoding UTF8

    $settingsDir = Join-Path $ComfyRoot "user\default"
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    $settingsPath = Join-Path $settingsDir "comfy.settings.json"
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        '{"Comfy.TutorialCompleted":true,"Comfy.UseNewMenu":"Top","Comfy.Minimap.Visible":false}' | Set-Content -LiteralPath $settingsPath -Encoding ASCII
    }

    $runtimeDir = Join-Path $InstallRoot "runtime"
    $startPs1 = Join-Path $runtimeDir "start-minimax-h3.ps1"
    $stopPs1 = Join-Path $runtimeDir "stop-minimax-h3.ps1"
    $escapedPython = $VenvPython.Replace("'", "''")
    $escapedComfy = $ComfyRoot.Replace("'", "''")
    $escapedRoot = $InstallRoot.Replace("'", "''")

    @"
`$ErrorActionPreference = 'Stop'
`$python = '$escapedPython'
`$comfy = '$escapedComfy'
`$root = '$escapedRoot'
`$pidFile = Join-Path `$root 'runtime\comfyui.pid'
`$logDir = Join-Path `$root 'logs'
New-Item -ItemType Directory -Force -Path `$logDir | Out-Null
function Test-Port {
    try { `$c = New-Object Net.Sockets.TcpClient; `$c.Connect('127.0.0.1',8188); `$c.Dispose(); return `$true } catch { return `$false }
}
if (Test-Path -LiteralPath `$pidFile) {
    `$oldPid = [int](Get-Content -LiteralPath `$pidFile -Raw)
    if (Get-Process -Id `$oldPid -ErrorAction SilentlyContinue) { Start-Process 'http://127.0.0.1:8188'; exit 0 }
}
if (Test-Port) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show('Port 8188 is already used by another program. Stop it, then launch MiniMax H3 again.','MiniMax H3','OK','Warning') | Out-Null
    exit 1
}
`$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
`$stdout = Join-Path `$logDir "comfyui-`$stamp.log"
`$stderr = Join-Path `$logDir "comfyui-`$stamp.err.log"
`$process = Start-Process -FilePath `$python -ArgumentList 'main.py','--listen','127.0.0.1','--port','8188' -WorkingDirectory `$comfy -RedirectStandardOutput `$stdout -RedirectStandardError `$stderr -WindowStyle Hidden -PassThru
`$process.Id | Set-Content -LiteralPath `$pidFile -Encoding ASCII
for (`$i=0; `$i -lt 180; `$i++) {
    Start-Sleep -Seconds 1
    if (Test-Port) { Start-Process 'http://127.0.0.1:8188'; exit 0 }
    if (`$process.HasExited) { break }
}
Add-Type -AssemblyName System.Windows.Forms
`$tail = if (Test-Path `$stderr) { (Get-Content `$stderr -Tail 12) -join [Environment]::NewLine } else { 'No error log was created.' }
[Windows.Forms.MessageBox]::Show("ComfyUI did not start. Log: `$stderr`n`n`$tail",'MiniMax H3 startup failed','OK','Error') | Out-Null
exit 1
"@ | Set-Content -LiteralPath $startPs1 -Encoding UTF8

    @"
`$pidFile = '$escapedRoot\runtime\comfyui.pid'
if (Test-Path -LiteralPath `$pidFile) {
    `$targetPid = [int](Get-Content -LiteralPath `$pidFile -Raw)
    `$proc = Get-Process -Id `$targetPid -ErrorAction SilentlyContinue
    if (`$proc -and `$proc.Path -and `$proc.Path.StartsWith('$escapedRoot', [StringComparison]::OrdinalIgnoreCase)) {
        & taskkill.exe /PID `$targetPid /T /F | Out-Null
    } elseif (`$proc) {
        Write-Host "Refusing to stop PID `$targetPid - it does not belong to this installation."
    }
    Remove-Item -LiteralPath `$pidFile -Force -ErrorAction SilentlyContinue
}
"@ | Set-Content -LiteralPath $stopPs1 -Encoding UTF8

    Assert-PowerShellScriptSyntax $startPs1
    Assert-PowerShellScriptSyntax $stopPs1

    $startBat = Join-Path $InstallRoot "Start MiniMax H3.bat"
    $stopBat = Join-Path $InstallRoot "Stop MiniMax H3.bat"
    '@echo off' + "`r`n" + 'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0runtime\start-minimax-h3.ps1"' + "`r`n" | Set-Content -LiteralPath $startBat -Encoding ASCII
    '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0runtime\stop-minimax-h3.ps1"' + "`r`n" | Set-Content -LiteralPath $stopBat -Encoding ASCII

    if ($chkDesktop.Checked) {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktop "MiniMax H3.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $startBat
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.Description = "Start ComfyUI with MiniMax H3"
        $shortcut.Save()
    }

    $manifest = [ordered]@{
        product = "MiniMax H3 for ComfyUI"
        installer_version = "1.0"
        installed_at = (Get-Date).ToString("o")
        comfyui_commit = "0764232429b8cfb10b79b6f186c8cb23e0b22897"
        python = "3.10"
        torch = "2.8.0+cu126"
        torchvision = "0.23.0+cu126"
        torchaudio = "2.8.0+cu126"
        workflow = "MiniMax_H3_8GB.json"
        default_resolution = "608x352"
        default_duration_seconds = 5
        launch_file = "Start MiniMax H3.bat"
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot ".minimax-h3-install.json") -Encoding UTF8
}

function Invoke-Install {
    $installRoot = [IO.Path]::GetFullPath($txtPath.Text.Trim())
    $report = Show-HardwareReport
    if (-not $report -or $report.Blocking) {
        [Windows.Forms.MessageBox]::Show("Resolve the failed checks before installing.", "Cannot install", "OK", "Error") | Out-Null
        return
    }

    if (Test-Path -LiteralPath $installRoot) {
        $hasFiles = (Get-ChildItem -LiteralPath $installRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
        $isOurInstall = Test-Path -LiteralPath (Join-Path $installRoot ".minimax-h3-install.json")
        if ($hasFiles -and -not $isOurInstall) {
            $choice = [Windows.Forms.MessageBox]::Show("The selected folder is not empty and is not marked as a MiniMax H3 installation. Continue without deleting existing files?", "Folder is not empty", "YesNo", "Warning")
            if ($choice -ne [Windows.Forms.DialogResult]::Yes) { return }
        }
    }

    $script:IsInstalling = $true
    $btnInstall.Enabled = $false
    $btnBrowse.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLaunch.Enabled = $false
    $form.ControlBox = $false
    $txtLog.Clear()
    try {
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        Add-Log "Installation root: $installRoot"
        Add-Log "No SeedVR2, xformers, SageAttention, FlashAttention, Triton, or custom compute nodes will be installed."
        Add-Log "Models: 39.56 GiB; downloads support resume and SHA-256 verification."

        $basePython = Install-PythonRuntime $installRoot
        $environment = Install-ComfyEnvironment $installRoot $basePython
        Install-H3Models $environment.ComfyRoot $environment.Python $installRoot
        Set-Stage "Deploying workflow and one-click launcher" -1
        Install-WorkflowAndLauncher $installRoot $environment.ComfyRoot $environment.Python

        Set-Stage "Installation complete" 100
        Add-Log "Installation completed successfully."
        Add-Log "Launch file: $(Join-Path $installRoot 'Start MiniMax H3.bat')"
        $btnLaunch.Tag = Join-Path $installRoot "Start MiniMax H3.bat"
        $btnLaunch.Enabled = $true
        [Windows.Forms.MessageBox]::Show("MiniMax H3 is ready. Click 'Launch MiniMax H3' to open the preconfigured workflow.", "Installation complete", "OK", "Information") | Out-Null
    } catch {
        Set-Stage "Installation stopped" 0
        Add-Log $_.Exception.Message "ERROR"
        [Windows.Forms.MessageBox]::Show("Installation stopped:`n`n$($_.Exception.Message)`n`nPartial model downloads were kept and will resume next time.", "Installation failed", "OK", "Error") | Out-Null
    } finally {
        $script:IsInstalling = $false
        $btnInstall.Enabled = $true
        $btnBrowse.Enabled = $true
        $btnCheck.Enabled = $true
        $form.ControlBox = $true
    }
}

. (Join-Path $script:AssetsRoot "hardware_profiles_core.ps1")
. (Join-Path $script:AssetsRoot "hardware_profiles_install.ps1")
$form = New-Object Windows.Forms.Form
$form.Text = "MiniMax H3 Hardware-Aware Installer"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(980, 760)
$form.MinimumSize = New-Object Drawing.Size(900, 680)
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
$form.BackColor = [Drawing.Color]::FromArgb(246, 247, 249)

$title = New-Object Windows.Forms.Label
$title.Text = "MiniMax H3 for ComfyUI"
$title.Font = New-Object Drawing.Font("Segoe UI Semibold", 20)
$title.ForeColor = [Drawing.Color]::FromArgb(26, 32, 44)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24, 18)
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = "RTX 3060-5090 | automatic model and CUDA runtime selection | isolated environment"
$subtitle.ForeColor = [Drawing.Color]::FromArgb(85, 92, 104)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object Drawing.Point(27, 58)
$form.Controls.Add($subtitle)

$lblPath = New-Object Windows.Forms.Label
$lblPath.Text = "Installation folder"
$lblPath.AutoSize = $true
$lblPath.Location = New-Object Drawing.Point(25, 94)
$form.Controls.Add($lblPath)

$txtPath = New-Object Windows.Forms.TextBox
$defaultDrive = if (Test-Path "D:\") { "D:\MiniMaxH3" } else { Join-Path $env:LOCALAPPDATA "MiniMaxH3" }
$txtPath.Text = $defaultDrive
$txtPath.Location = New-Object Drawing.Point(25, 116)
$txtPath.Size = New-Object Drawing.Size(780, 27)
$txtPath.Anchor = "Top,Left,Right"
$form.Controls.Add($txtPath)

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object Drawing.Point(820, 114)
$btnBrowse.Size = New-Object Drawing.Size(120, 30)
$btnBrowse.Anchor = "Top,Right"
$form.Controls.Add($btnBrowse)

$btnCheck = New-Object Windows.Forms.Button
$btnCheck.Text = "Check computer"
$btnCheck.Location = New-Object Drawing.Point(25, 157)
$btnCheck.Size = New-Object Drawing.Size(145, 34)
$form.Controls.Add($btnCheck)

$lblCheck = New-Object Windows.Forms.Label
$lblCheck.Text = "Choose a folder, then check this computer."
$lblCheck.AutoSize = $true
$lblCheck.Location = New-Object Drawing.Point(185, 166)
$form.Controls.Add($lblCheck)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(25, 204)
$grid.Size = New-Object Drawing.Size(915, 202)
$grid.Anchor = "Top,Left,Right"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.AutoSizeRowsMode = "AllCells"
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = "FixedSingle"
[void]$grid.Columns.Add("Check", "Check")
[void]$grid.Columns.Add("Value", "Value")
[void]$grid.Columns.Add("Status", "Status")
[void]$grid.Columns.Add("Detail", "Detail")
$grid.Columns[0].Width = 125
$grid.Columns[1].Width = 210
$grid.Columns[2].Width = 65
$grid.Columns[3].AutoSizeMode = "Fill"
$form.Controls.Add($grid)

$chkDesktop = New-Object Windows.Forms.CheckBox
$chkDesktop.Text = "Create a desktop shortcut"
$chkDesktop.Checked = $true
$chkDesktop.AutoSize = $true
$chkDesktop.Location = New-Object Drawing.Point(25, 420)
$form.Controls.Add($chkDesktop)

$btnInstall = New-Object Windows.Forms.Button
$btnInstall.Text = "Install / Repair"
$btnInstall.Font = New-Object Drawing.Font("Segoe UI Semibold", 10)
$btnInstall.BackColor = [Drawing.Color]::FromArgb(35, 104, 188)
$btnInstall.ForeColor = [Drawing.Color]::White
$btnInstall.FlatStyle = "Flat"
$btnInstall.Location = New-Object Drawing.Point(25, 451)
$btnInstall.Size = New-Object Drawing.Size(175, 40)
$form.Controls.Add($btnInstall)

$btnLaunch = New-Object Windows.Forms.Button
$btnLaunch.Text = "Launch MiniMax H3"
$btnLaunch.Location = New-Object Drawing.Point(212, 451)
$btnLaunch.Size = New-Object Drawing.Size(175, 40)
$btnLaunch.Enabled = $false
$form.Controls.Add($btnLaunch)

$lblStage = New-Object Windows.Forms.Label
$lblStage.Text = "Idle"
$lblStage.AutoSize = $true
$lblStage.Location = New-Object Drawing.Point(405, 463)
$form.Controls.Add($lblStage)

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(25, 501)
$progress.Size = New-Object Drawing.Size(915, 18)
$progress.Anchor = "Top,Left,Right"
$form.Controls.Add($progress)

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Location = New-Object Drawing.Point(25, 532)
$txtLog.Size = New-Object Drawing.Size(915, 165)
$txtLog.Anchor = "Top,Bottom,Left,Right"
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [Drawing.Color]::FromArgb(20, 24, 31)
$txtLog.ForeColor = [Drawing.Color]::FromArgb(218, 224, 232)
$txtLog.Font = New-Object Drawing.Font("Consolas", 8.5)
$form.Controls.Add($txtLog)

$folderDialog = New-Object Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "Choose where MiniMax H3 will be installed"
$folderDialog.ShowNewFolderButton = $true

$btnBrowse.Add_Click({
    $folderDialog.SelectedPath = $txtPath.Text
    if ($folderDialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $txtPath.Text = $folderDialog.SelectedPath
        Show-HardwareReport | Out-Null
    }
})
$btnCheck.Add_Click({ Show-HardwareReport | Out-Null })
$btnInstall.Add_Click({ Invoke-Install })
$btnLaunch.Add_Click({ if ($btnLaunch.Tag -and (Test-Path -LiteralPath $btnLaunch.Tag)) { Start-Process -FilePath $btnLaunch.Tag } })
$form.Add_Shown({
    Initialize-HardwareProfileUI
    Show-HardwareReport | Out-Null
    $launcher = Join-Path $txtPath.Text "Start MiniMax H3.bat"
    if (Test-Path -LiteralPath $launcher) {
        $btnLaunch.Tag = $launcher
        $btnLaunch.Enabled = $true
    }
})
$form.Add_FormClosing({ param($sender, $eventArgs); if ($script:IsInstalling) { $eventArgs.Cancel = $true } })

if ($SelfTest) {
    $report = Get-HardwareReport $txtPath.Text
    $workflow = Get-Content -LiteralPath (Join-Path $script:AssetsRoot "MiniMax_H3_8GB.json") -Raw | ConvertFrom-Json
    $resolutionNode = $workflow.nodes | Where-Object { $_.id -eq 115 }
    [PSCustomObject]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        checks_blocking = $report.Blocking
        check_count = $report.Items.Count
        comfy_source_sha256 = (Get-FileHash -LiteralPath (Join-Path $script:AssetsRoot "ComfyUI-source.zip") -Algorithm SHA256).Hash
        workflow_megapixels = $resolutionNode.widgets_values[1]
        model_downloader_present = Test-Path -LiteralPath (Join-Path $script:AssetsRoot "download_models.py")
    } | ConvertTo-Json
    exit 0
}

[void]$form.ShowDialog()







