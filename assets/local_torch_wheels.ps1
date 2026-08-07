function Get-RuntimeIdForGpu {
    param([string]$GpuName)
    if (Test-IsBlackwellGpu $GpuName) { return "cuda130" }
    return "cuda126"
}

function Find-LocalPythonWheel {
    param([string]$FileName)

    $roots = @($script:InstallerRoot, $script:AssetsRoot) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $direct = Join-Path $root $FileName
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    }

    foreach ($root in $roots) {
        $match = Get-ChildItem -LiteralPath $root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $null
}

function Get-TorchRuntimeField {
    param($Object, [string]$Name)
    if (-not $Object) { return "" }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Get-InstalledTorchRuntime {
    param([string]$Python)
    if (-not (Test-Path -LiteralPath $Python)) { return $null }

    # Always return the same schema. A brand-new venv legitimately has no torch,
    # and StrictMode must not turn that normal state into a missing-property error.
    $code = "import json; result={'torch':'','torchvision':'','torchaudio':'','cuda':''};`ntry:`n import torch; result['torch']=torch.__version__; result['cuda']=str(torch.version.cuda or '')`nexcept Exception: pass`ntry:`n import torchvision; result['torchvision']=torchvision.__version__`nexcept Exception: pass`ntry:`n import torchaudio; result['torchaudio']=torchaudio.__version__`nexcept Exception: pass`nprint(json.dumps(result))"
    try {
        $json = (& $Python -c $code 2>$null | Select-Object -Last 1)
        if (-not $json) { return $null }
        $parsed = $json | ConvertFrom-Json
        return [PSCustomObject]@{
            torch = (Get-TorchRuntimeField -Object $parsed -Name "torch")
            torchvision = (Get-TorchRuntimeField -Object $parsed -Name "torchvision")
            torchaudio = (Get-TorchRuntimeField -Object $parsed -Name "torchaudio")
            cuda = (Get-TorchRuntimeField -Object $parsed -Name "cuda")
        }
    } catch {
        return $null
    }
}

function Test-TorchRuntimeMatches {
    param($Installed, $Runtime)
    if (-not $Installed -or -not $Runtime) { return $false }

    $installedTorch = Get-TorchRuntimeField -Object $Installed -Name "torch"
    $installedVision = Get-TorchRuntimeField -Object $Installed -Name "torchvision"
    $installedAudio = Get-TorchRuntimeField -Object $Installed -Name "torchaudio"
    $installedCuda = Get-TorchRuntimeField -Object $Installed -Name "cuda"

    if ([string]::IsNullOrWhiteSpace($installedTorch)) { return $false }
    return (
        $installedTorch -eq [string]$Runtime.torch -and
        $installedVision -eq [string]$Runtime.torchvision -and
        $installedAudio -eq [string]$Runtime.torchaudio -and
        $installedCuda -like "$($Runtime.cuda_version)*"
    )
}

function Remove-OldTorchRuntime {
    param([string]$Python, $Installed, $Runtime)
    if (-not $Installed) { return }

    $installedTorch = Get-TorchRuntimeField -Object $Installed -Name "torch"
    $installedVision = Get-TorchRuntimeField -Object $Installed -Name "torchvision"
    $installedAudio = Get-TorchRuntimeField -Object $Installed -Name "torchaudio"
    $installedCuda = Get-TorchRuntimeField -Object $Installed -Name "cuda"

    if ([string]::IsNullOrWhiteSpace($installedTorch) -and
        [string]::IsNullOrWhiteSpace($installedVision) -and
        [string]::IsNullOrWhiteSpace($installedAudio)) {
        Add-Log "No existing PyTorch runtime found; installing the selected runtime into the fresh environment."
        return
    }

    if (Test-TorchRuntimeMatches -Installed $Installed -Runtime $Runtime) {
        Add-Log "Installed PyTorch runtime already matches $($Runtime.label)."
        return
    }

    $oldSummary = "torch=$installedTorch, torchvision=$installedVision, torchaudio=$installedAudio, CUDA=$installedCuda"
    Add-Log "Existing PyTorch runtime will be upgraded in place: $oldSummary" "WARN"
    Set-Stage "Removing previous PyTorch runtime before upgrade" -1
    $null = Invoke-ProcessChecked $Python "-m pip uninstall -y torch torchvision torchaudio" $script:InstallerRoot -AllowFailure
}

function Install-SelectedTorchRuntime {
    param([string]$Python, $Runtime)

    $installed = Get-InstalledTorchRuntime -Python $Python
    if (Test-TorchRuntimeMatches -Installed $installed -Runtime $Runtime) {
        Add-Log "Selected PyTorch runtime is already installed; skipping replacement."
        return
    }
    Remove-OldTorchRuntime -Python $Python -Installed $installed -Runtime $Runtime

    $packageSpecs = @(
        [PSCustomObject]@{ Name = "torch"; Version = [string]$Runtime.torch },
        [PSCustomObject]@{ Name = "torchvision"; Version = [string]$Runtime.torchvision },
        [PSCustomObject]@{ Name = "torchaudio"; Version = [string]$Runtime.torchaudio }
    )

    $localWheels = @{}
    foreach ($package in $packageSpecs) {
        $fileName = "{0}-{1}-cp310-cp310-win_amd64.whl" -f $package.Name, $package.Version
        $wheel = Find-LocalPythonWheel -FileName $fileName
        if ($wheel) {
            $localWheels[$package.Name] = $wheel
            Add-Log ("Local wheel found for {0}: {1}" -f $package.Name, $wheel)
        }
    }

    if (-not $localWheels.ContainsKey("torch")) {
        Add-Log ("No matching local Torch wheel was found for {0}; using configured package sources." -f $Runtime.torch)
        $torchPackages = "install torch==$($Runtime.torch) torchvision==$($Runtime.torchvision) torchaudio==$($Runtime.torchaudio) --upgrade"
        $null = Invoke-PipWithFallback $Python $torchPackages $Runtime -NeedsTorchIndex
        return
    }

    Set-Stage ("Installing local Torch wheel: {0}" -f (Split-Path -Leaf $localWheels["torch"])) -1
    $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --no-deps --disable-pip-version-check" -f $localWheels["torch"]) $script:InstallerRoot

    foreach ($package in $packageSpecs | Where-Object { $_.Name -ne "torch" }) {
        if ($localWheels.ContainsKey($package.Name)) {
            Set-Stage ("Installing local {0} wheel" -f $package.Name) -1
            $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --no-deps --disable-pip-version-check" -f $localWheels[$package.Name]) $script:InstallerRoot
        } else {
            Add-Log ("No matching local {0} wheel was found; downloading only {0} {1}." -f $package.Name, $package.Version)
            $arguments = "install $($package.Name)==$($package.Version) --upgrade --no-deps"
            $null = Invoke-PipWithFallback $Python $arguments $Runtime -NeedsTorchIndex
        }
    }
}

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython, $Runtime)
    $sourceZip = Join-Path $script:AssetsRoot "ComfyUI-source.zip"
    $sourceHash = "71C2B7624D10AF93FF1158F11B1787D6296ED081B52AC86B9CA82530CE5AA754"
    if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Installer asset is missing: $sourceZip" }
    if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash -ne $sourceHash) { throw "Bundled ComfyUI source failed verification." }

    $comfyRoot = Join-Path $InstallRoot "ComfyUI"
    $existingInstall = Test-Path -LiteralPath (Join-Path $comfyRoot "main.py")
    Set-Stage $(if ($existingInstall) { "Refreshing ComfyUI application files" } else { "Deploying fixed ComfyUI source" }) -1
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $InstallRoot -Force
    if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "ComfyUI source extraction failed." }
    if ($existingInstall) { Add-Log "Existing installation detected. Models, user workflows, logs, and partial downloads are preserved." }

    $venvRoot = Join-Path $InstallRoot "runtime\venv"
    $venvPython = Join-Path $venvRoot "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Set-Stage "Creating isolated Python environment" -1
        $null = Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot
    }

    Set-Stage "Preparing pip" -1
    $null = Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel packaging --upgrade" $Runtime

    Set-Stage ("Installing {0}" -f $Runtime.label) -1
    Install-SelectedTorchRuntime -Python $venvPython -Runtime $Runtime

    $constraints = Join-Path $InstallRoot "runtime\constraints-selected.txt"
    @"
torch==$($Runtime.torch)
torchvision==$($Runtime.torchvision)
torchaudio==$($Runtime.torchaudio)
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    Set-Stage "Updating ComfyUI dependencies" -1
    $requirements = Join-Path $comfyRoot "requirements.txt"
    $dependencyArgs = "install -r `"{0}`" -c `"{1}`" --upgrade --upgrade-strategy only-if-needed" -f $requirements, $constraints
    $null = Invoke-PipWithFallback $venvPython $dependencyArgs $Runtime

    Set-Stage "Checking Python dependency consistency" -1
    $null = Invoke-ProcessChecked $venvPython "-m pip check" $comfyRoot

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='$($Runtime.torch)'; assert torchvision.__version__=='$($Runtime.torchvision)'; assert torchaudio.__version__=='$($Runtime.torchaudio)'; assert torch.cuda.is_available(); assert str(torch.version.cuda).startswith('$($Runtime.cuda_version)'); print(torch.cuda.get_device_name(0)); print('CUDA '+str(torch.version.cuda)+' ready')"
    $null = Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}
