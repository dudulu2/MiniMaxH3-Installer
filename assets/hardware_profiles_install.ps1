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
    $mirrorFirst = Test-ChinaMirrorPriority
    $pythonUrls = if ($mirrorFirst) {
        @(
            "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe",
            "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe"
        )
    } else {
        @(
            "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
            "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe"
        )
    }
    Add-Log ("Python download route: {0}" -f $(if ($mirrorFirst) { "China mirror first" } else { "Official source first" }))
    $null = Invoke-SimpleDownload "Python 3.10.11" $pythonUrls $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "The Python installer signature is not valid. File was not executed. Status: $($signature.Status)"
    }
    Add-Log "Python installer signature verified: $($signature.SignerCertificate.Subject)"
    Set-Stage "Installing private Python runtime" -1
    $arguments = "/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 Include_pip=1 TargetDir=`"$pythonRoot`""
    $null = Invoke-ProcessChecked $installer $arguments $InstallRoot
    if (-not (Test-Path -LiteralPath $python)) { throw "Python installation did not create $python" }
    return $python
}

function Invoke-PipWithFallback {
    param(
        [string]$Python,
        [string]$PackageArguments,
        $Runtime,
        [switch]$NeedsTorchIndex
    )
    if ($NeedsTorchIndex) {
        $officialArgs = "$PackageArguments --index-url $($Runtime.index_url)"
        $mirrorArgs = if ($Runtime.mirror_index_url) { "$PackageArguments --index-url $($Runtime.mirror_index_url)" } else { $null }
        $officialLabel = "PyTorch official source"
        $mirrorLabel = "Aliyun PyTorch mirror"
    } else {
        $mirrorTorchIndex = if ($Runtime.mirror_index_url) { $Runtime.mirror_index_url } else { $Runtime.index_url }
        $officialArgs = "$PackageArguments --index-url https://pypi.org/simple --extra-index-url $($Runtime.index_url)"
        $mirrorArgs = "$PackageArguments --index-url https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url $mirrorTorchIndex"
        $officialLabel = "official PyPI"
        $mirrorLabel = "Tsinghua PyPI mirror"
    }

    $preferMirror = Test-ChinaMirrorPriority
    if ($preferMirror -and $mirrorArgs) {
        $primaryArgs = $mirrorArgs
        $primaryLabel = $mirrorLabel
        $fallbackArgs = $officialArgs
        $fallbackLabel = $officialLabel
    } else {
        $primaryArgs = $officialArgs
        $primaryLabel = $officialLabel
        $fallbackArgs = $mirrorArgs
        $fallbackLabel = $mirrorLabel
    }

    if ($preferMirror -and -not $mirrorArgs) {
        Add-Log "No verified China mirror is configured for $($Runtime.label); using the official PyTorch source." "WARN"
    }
    Add-Log "Python package source: $primaryLabel"
    $exit = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 2 --no-cache-dir --disable-pip-version-check" -f $primaryArgs) $script:InstallerRoot -AllowFailure
    if ($exit -ne 0) {
        if (-not $fallbackArgs) { throw "$primaryLabel failed and no fallback source is configured for $($Runtime.label)." }
        Add-Log "$primaryLabel failed; switching to $fallbackLabel." "WARN"
        Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 3 --no-cache-dir --disable-pip-version-check" -f $fallbackArgs) $script:InstallerRoot
    }
}

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython, $Runtime)
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
    Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel" $Runtime

    Set-Stage ("Installing {0}" -f $Runtime.label) -1
    $torchPackages = "install torch==$($Runtime.torch) torchvision==$($Runtime.torchvision) torchaudio==$($Runtime.torchaudio) --upgrade"
    Invoke-PipWithFallback $venvPython $torchPackages $Runtime -NeedsTorchIndex

    $constraints = Join-Path $InstallRoot "runtime\constraints-selected.txt"
    @"
torch==$($Runtime.torch)
torchvision==$($Runtime.torchvision)
torchaudio==$($Runtime.torchaudio)
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    Set-Stage "Installing ComfyUI dependencies" -1
    $requirements = Join-Path $comfyRoot "requirements.txt"
    Invoke-PipWithFallback $venvPython ("install -r `"{0}`" -c `"{1}`"" -f $requirements, $constraints) $Runtime

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='$($Runtime.torch)'; assert torchvision.__version__=='$($Runtime.torchvision)'; assert torchaudio.__version__=='$($Runtime.torchaudio)'; assert torch.cuda.is_available(); assert str(torch.version.cuda).startswith('$($Runtime.cuda_version)'); print(torch.cuda.get_device_name(0)); print('CUDA '+str(torch.version.cuda)+' ready')"
    Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}

function Install-H3Models {
    param([string]$ComfyRoot, [string]$Python, [string]$InstallRoot, $Profile)
    $downloader = Join-Path $script:AssetsRoot "download_models.py"
    if (-not (Test-Path -LiteralPath $downloader)) { throw "Installer asset is missing: $downloader" }
    $statusPath = Join-Path $InstallRoot "downloads\model-progress.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue

    $sourceOrder = if (Test-ChinaMirrorPriority) { "mirror-first" } else { "official-first" }
    Add-Log "Model download route: $sourceOrder"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`" --source-order $sourceOrder"
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
            } catch { Pump-UI }
        } else { Pump-UI }
    }
    $outText = $stdout.Result
    $errText = $stderr.Result
    foreach ($line in (($outText + "`n" + $errText) -split "`r?`n")) {
        if ($line.Trim()) { Add-Log $line.Trim() "MODEL" }
    }
    if ($process.ExitCode -ne 0) { throw "Model downloader failed with exit code $($process.ExitCode). See the installer log." }
}

function New-ProfileWorkflow {
    param([string]$ComfyRoot, $Profile)
    $workflowSource = Join-Path $script:AssetsRoot "MiniMax_H3_8GB.json"
    if (-not (Test-Path -LiteralPath $workflowSource)) { throw "Installer asset is missing: $workflowSource" }
    $workflow = Get-Content -LiteralPath $workflowSource -Raw | ConvertFrom-Json
    $resolutionNode = $workflow.nodes | Where-Object { $_.id -eq 115 } | Select-Object -First 1
    $mainNode = $workflow.nodes | Where-Object { $_.id -eq 105 } | Select-Object -First 1
    if (-not $resolutionNode -or -not $mainNode) { throw "Bundled workflow does not contain the expected profile nodes." }

    $diffusionName = Split-Path -Leaf $Profile.diffusion_model
    $textEncoderName = Split-Path -Leaf $Profile.text_encoder
    $videoVaeName = Split-Path -Leaf $Profile.video_vae
    $audioVaeName = Split-Path -Leaf $Profile.audio_vae

    $resolutionNode.widgets_values[1] = [double]$Profile.megapixels
    $mainNode.widgets_values[3] = [double]$Profile.duration_seconds
    $mainNode.widgets_values[5] = $diffusionName
    $mainNode.widgets_values[6] = $textEncoderName
    $mainNode.widgets_values[7] = $videoVaeName
    $mainNode.widgets_values[8] = $audioVaeName

    $modelNote = $workflow.nodes | Where-Object { $_.id -eq 117 } | Select-Object -First 1
    if ($modelNote) {
        $modelNote.widgets_values[0] = "## Selected model profile`n`n**Profile:** $($Profile.label)`n`n- diffusion_models/$diffusionName`n- text_encoders/$textEncoderName`n- vae/$videoVaeName`n- vae/$audioVaeName`n`nDefault output: $($Profile.resolution), $($Profile.duration_seconds) seconds at 24fps."
    }

    foreach ($subgraph in @($workflow.definitions.subgraphs)) {
        foreach ($node in @($subgraph.nodes)) {
            if ($node.type -eq "UNETLoader") {
      $node.widgets_values[0] = $diffusionName
      if ($node.properties -and $node.properties.models) {
          $node.properties.models[0].name = $diffusionName
          $node.properties.models[0].url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$($Profile.diffusion_model)"
          $node.properties.models[0].directory = "diffusion_models"
      }
  }
  elseif ($node.type -eq "CLIPLoader") {
      $node.widgets_values[0] = $textEncoderName
      if ($node.properties -and $node.properties.models) {
          $node.properties.models[0].name = $textEncoderName
          $node.properties.models[0].url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$($Profile.text_encoder)"
          $node.properties.models[0].directory = "text_encoders"
      }
  }
  elseif ($node.type -eq "VAELoader") {
      $isAudioVae = [string]$node.widgets_values[0] -match "audio"
      $selectedName = if ($isAudioVae) { $audioVaeName } else { $videoVaeName }
      $selectedPath = if ($isAudioVae) { $Profile.audio_vae } else { $Profile.video_vae }
      $node.widgets_values[0] = $selectedName
      if ($node.properties -and $node.properties.models) {
          $node.properties.models[0].name = $selectedName
          $node.properties.models[0].url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$selectedPath"
          $node.properties.models[0].directory = "vae"
      }
  }
        }
    }

    $workflowDir = Join-Path $ComfyRoot "user\default\workflows"
    New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
    $workflowName = "MiniMax_H3_$($Profile.id).json"
    $workflowPath = Join-Path $workflowDir $workflowName
    $workflow | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $workflowPath -Encoding UTF8
    return $workflowName
}

function Install-WorkflowAndLauncher {
    param([string]$InstallRoot, [string]$ComfyRoot, [string]$VenvPython, $Profile, $Runtime, [int]$GpuIndex)
    $workflowName = New-ProfileWorkflow $ComfyRoot $Profile

    $helperRoot = Join-Path $ComfyRoot "custom_nodes\minimax_h3_workflow_autoload"
    $helperWeb = Join-Path $helperRoot "web"
    New-Item -ItemType Directory -Force -Path $helperWeb | Out-Null
    @'
WEB_DIRECTORY = "./web"
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
'@ | Set-Content -LiteralPath (Join-Path $helperRoot "__init__.py") -Encoding ASCII

    $autoloadTemplate = @'
import { app } from "../../../scripts/app.js";

app.registerExtension({
    name: "MiniMaxH3.FirstRunWorkflow",
    async setup() {
        const key = "__STORAGE_KEY__";
        if (localStorage.getItem(key)) return;
        try {
            const path = encodeURIComponent("workflows/__WORKFLOW_NAME__");
            const response = await fetch(`/api/userdata/${path}`);
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const workflow = await response.json();
            await app.loadGraphData(workflow, true, true, "__WORKFLOW_NAME__");
            localStorage.setItem(key, "1");
        } catch (error) {
            console.error("MiniMax H3 workflow autoload failed", error);
        }
    }
});
'@
    $autoload = $autoloadTemplate.Replace("__WORKFLOW_NAME__", $workflowName).Replace("__STORAGE_KEY__", "minimax-h3-workflow-$($Profile.id)-v1")
    $autoload | Set-Content -LiteralPath (Join-Path $helperWeb "autoload.js") -Encoding UTF8

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
`$env:CUDA_VISIBLE_DEVICES = '$GpuIndex'
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
        installer_version = "1.1"
        installed_at = (Get-Date).ToString("o")
        comfyui_commit = "0764232429b8cfb10b79b6f186c8cb23e0b22897"
        python = "3.10"
        profile = $Profile.id
        profile_label = $Profile.label
        gpu_index = $GpuIndex
        runtime = $Runtime.label
        torch = $Runtime.torch
        torchvision = $Runtime.torchvision
        torchaudio = $Runtime.torchaudio
        diffusion_model = $Profile.diffusion_model
        text_encoder = $Profile.text_encoder
        video_vae = $Profile.video_vae
        audio_vae = $Profile.audio_vae
        workflow = $workflowName
        default_resolution = $Profile.resolution
        default_duration_seconds = $Profile.duration_seconds
        launch_file = "Start MiniMax H3.bat"
        download_route = $(if (Test-ChinaMirrorPriority) { "china-mirror-first" } else { "official-first" })
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
    $profile = Get-ProfileById $report.ProfileId
    $runtime = Get-RuntimeById $report.RuntimeId

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
    if ($script:ProfileButton) { $script:ProfileButton.Enabled = $false }
    if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $false }
    $btnLaunch.Enabled = $false
    $form.ControlBox = $false
    $txtLog.Clear()
    $previousCudaDevices = $env:CUDA_VISIBLE_DEVICES
    try {
        $env:CUDA_VISIBLE_DEVICES = [string]$report.GpuIndex
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        $modelBytes = Get-ProfileModelBytes $profile
        Add-Log "Installation root: $installRoot"
        Add-Log "Selected GPU: $($report.GpuName) (physical index $($report.GpuIndex))"
        Add-Log "Selected profile: $($profile.label)"
        Add-Log "Selected runtime: $($runtime.label)"
        Add-Log "Download route: $(Get-DownloadRouteLabel)"
        Add-Log ("Models: {0:N2} GiB; downloads support resume and SHA-256 verification." -f ($modelBytes/1GB))
        Add-Log "No SeedVR2, xformers, SageAttention, FlashAttention, Triton, or custom compute nodes will be installed."

        $basePython = Install-PythonRuntime $installRoot
        $environment = Install-ComfyEnvironment $installRoot $basePython $runtime
        Install-H3Models $environment.ComfyRoot $environment.Python $installRoot $profile
        Set-Stage "Deploying selected workflow and one-click launcher" -1
        Install-WorkflowAndLauncher $installRoot $environment.ComfyRoot $environment.Python $profile $runtime $report.GpuIndex

        Set-Stage "Installation complete" 100
        Add-Log "Installation completed successfully."
        Add-Log "Launch file: $(Join-Path $installRoot 'Start MiniMax H3.bat')"
        $btnLaunch.Tag = Join-Path $installRoot "Start MiniMax H3.bat"
        $btnLaunch.Enabled = $true
        [Windows.Forms.MessageBox]::Show("MiniMax H3 is ready with the '$($profile.label)' profile. Click 'Launch MiniMax H3' to open the preconfigured workflow.", "Installation complete", "OK", "Information") | Out-Null
    } catch {
        Set-Stage "Installation stopped" 0
        Add-Log $_.Exception.Message "ERROR"
        [Windows.Forms.MessageBox]::Show("Installation stopped:`n`n$($_.Exception.Message)`n`nPartial model downloads were kept and will resume next time.", "Installation failed", "OK", "Error") | Out-Null
    } finally {
        $env:CUDA_VISIBLE_DEVICES = $previousCudaDevices
        $script:IsInstalling = $false
        $btnInstall.Enabled = $true
        $btnBrowse.Enabled = $true
        $btnCheck.Enabled = $true
        if ($script:ProfileButton) { $script:ProfileButton.Enabled = $true }
        if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $true }
        $form.ControlBox = $true
    }
}
